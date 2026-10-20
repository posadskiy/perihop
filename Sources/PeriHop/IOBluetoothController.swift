import Foundation
import IOBluetooth

/// In-process IOBluetooth. Calls stay off a spawned `blueutil` so a connect
/// can be waited on, cancelled, and followed immediately by a pair.
struct LiveBluetoothController: BluetoothControlling {
    private let gate = BluetoothGate()

    func disconnect(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        try await gate.run {
            try await IOBluetoothWork.shared.disconnect(address, timeout: timeout)
        }
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        await gate.run {
            await IOBluetoothWork.shared.connect(address, timeout: timeout)
        }
    }

    func isConnected(_ address: DeviceAddress) async -> Bool {
        await IOBluetoothWork.shared.isConnected(address)
    }

    func batteryPercent(_ address: DeviceAddress) async -> Int? {
        await IOBluetoothWork.shared.batteryPercent(address)
    }

    func isPaired(_ address: DeviceAddress) async -> Bool {
        await IOBluetoothWork.shared.isPaired(address)
    }

    func suppress(_ address: DeviceAddress, safetyTimeout: TimeInterval) async {
        await IOBluetoothWork.shared.suppress(address, safetyTimeout: safetyTimeout)
    }

    func stopSuppressing(_ address: DeviceAddress) async {
        await IOBluetoothWork.shared.stopSuppressing(address)
    }

    func forget(_ address: DeviceAddress) async {
        await gate.run {
            await IOBluetoothWork.shared.forget(address)
        }
    }

    func pair(_ address: DeviceAddress) async throws {
        try await gate.run {
            try await IOBluetoothWork.shared.pair(address)
        }
    }

    func waitUntilDiscovered(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        await gate.run {
            await IOBluetoothWork.shared.waitUntilDiscovered(address, timeout: timeout)
        }
    }

    func cancelOperations() async {
        await IOBluetoothWork.shared.cancelOperations()
    }

    func pairedDevices() async throws -> [BTDevice] {
        try await IOBluetoothWork.shared.pairedDevices()
    }

    func inquire(timeout: TimeInterval) async throws -> [BTDevice] {
        try await gate.run {
            try await IOBluetoothWork.shared.inquire(timeout: timeout)
        }
    }
}

private actor BluetoothGate {
    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await body()
    }
}

@MainActor
final class IOBluetoothWork {
    static let shared = IOBluetoothWork()

    private var suppressTasks: [DeviceAddress: Task<Void, Never>] = [:]
    private var inquiry: InquirySession?
    private var pairSession: PairSession?
    private var cancelled = false

    func disconnect(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        guard let device = device(for: address), device.isConnected() else { return }
        let result = device.closeConnection()
        if result != kIOReturnSuccess && device.isConnected() {
            throw BluetoothError.failed("Couldn't disconnect \(address.rawValue).")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let current = self.device(for: address), current.isConnected() else { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if self.device(for: address)?.isConnected() == true {
            throw BluetoothError.failed("Couldn't disconnect \(address.rawValue).")
        }
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        begin()
        guard let device = device(for: address) else { return false }
        if device.isConnected() { return true }
        // Page timeout is in units of 0.625ms. Cap the block so a missing
        // accessory can't freeze the menu for the stack's default.
        let pages = BluetoothHCIPageTimeout(max(1, min(timeout / 0.000625, Double(UInt16.max))))
        _ = device.openConnection(nil, withPageTimeout: pages, authenticationRequired: false)
        return await pollConnected(device, timeout: timeout)
    }

    func isConnected(_ address: DeviceAddress) -> Bool {
        device(for: address)?.isConnected() ?? false
    }

    func isPaired(_ address: DeviceAddress) -> Bool {
        device(for: address)?.isPaired() ?? false
    }

    func batteryPercent(_ address: DeviceAddress) -> Int? {
        guard let device = device(for: address) else { return nil }
        let selector = NSSelectorFromString("batteryPercentSingle")
        guard device.responds(to: selector) else { return nil }
        let value = device.value(forKey: "batteryPercentSingle") as? NSNumber
        let percent = value?.intValue ?? -1
        guard (0...100).contains(percent) else { return nil }
        return percent
    }

    func suppress(_ address: DeviceAddress, safetyTimeout: TimeInterval) {
        suppressTasks[address]?.cancel()
        let deadline = Date().addingTimeInterval(safetyTimeout)
        suppressTasks[address] = Task { @MainActor in
            while !Task.isCancelled && Date() < deadline {
                if let device = self.device(for: address), device.isConnected() {
                    device.closeConnection()
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            self.suppressTasks[address] = nil
        }
    }

    func stopSuppressing(_ address: DeviceAddress) {
        suppressTasks[address]?.cancel()
        suppressTasks[address] = nil
    }

    func forget(_ address: DeviceAddress) async {
        guard let device = device(for: address) else { return }
        if device.isConnected() {
            try? await disconnect(address, timeout: 2)
        }
        let remove = NSSelectorFromString("remove")
        guard device.responds(to: remove) else {
            AppLog.bluetooth.error("This macOS build can't forget \(address.rawValue)")
            return
        }
        _ = device.perform(remove)
        AppLog.bluetooth.info("Forgot \(address.rawValue)")
    }

    func pair(_ address: DeviceAddress) async throws {
        begin()
        guard !cancelled else { throw BluetoothError.failed("Stopped.") }
        guard let device = device(for: address) else {
            throw BluetoothError.failed("\(address.rawValue) isn't available to pair.")
        }
        if device.isPaired() { return }
        let session = PairSession()
        pairSession = session
        defer { pairSession = nil }
        try await session.pair(device)
    }

    func waitUntilDiscovered(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        begin()
        let deadline = Date().addingTimeInterval(timeout)
        while !cancelled && Date() < deadline {
            let slice = min(8, deadline.timeIntervalSinceNow)
            guard slice > 0 else { break }
            if await runInquiry(matching: address, timeout: slice) {
                return true
            }
        }
        return false
    }

    func cancelOperations() {
        cancelled = true
        inquiry?.stop()
        pairSession?.stop()
    }

    func pairedDevices() throws -> [BTDevice] {
        let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return list.compactMap(makeDevice)
    }

    func inquire(timeout: TimeInterval) async throws -> [BTDevice] {
        begin()
        let session = InquirySession()
        inquiry = session
        defer { inquiry = nil }
        return await session.collect(timeout: timeout)
    }

    private func runInquiry(matching address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        let session = InquirySession()
        inquiry = session
        defer { inquiry = nil }
        return await session.waitFor(address: address, timeout: timeout)
    }

    private func pollConnected(_ device: IOBluetoothDevice, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !cancelled && Date() < deadline {
            if device.isConnected() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return device.isConnected()
    }

    private func begin() {
        cancelled = false
    }

    private func device(for address: DeviceAddress) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address.rawValue)
    }

    private func makeDevice(_ device: IOBluetoothDevice) -> BTDevice? {
        guard let address = device.addressString else { return nil }
        let name = device.nameOrAddress ?? address
        return BTDevice(address: DeviceAddress(address), name: name)
    }
}

@MainActor
private final class PairSession: NSObject {
    private var continuation: CheckedContinuation<Void, Error>?
    private var pairer: IOBluetoothDevicePair?
    private var finished = false

    func pair(_ device: IOBluetoothDevice) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let pairer = IOBluetoothDevicePair(device: device)
            pairer?.delegate = self
            self.pairer = pairer
            let result = pairer?.start() ?? kIOReturnError
            if result != kIOReturnSuccess {
                self.finish(.failure(BluetoothError.failed("Couldn't start pairing.")))
            }
        }
    }

    func stop() {
        pairer?.stop()
        finish(.failure(BluetoothError.failed("Stopped.")))
    }

    @objc nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        let error = error
        MainActor.assumeIsolated {
            if error == kIOReturnSuccess {
                self.finish(.success(()))
            } else {
                self.finish(.failure(BluetoothError.failed(String(format: "Pairing failed (0x%02x).", error))))
            }
        }
    }

    @objc nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: UInt32) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    @objc nonisolated func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode(data: (
            0x30, 0x30, 0x30, 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ))
        (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }
}

@MainActor
private final class InquirySession: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var listContinuation: CheckedContinuation<[BTDevice], Never>?
    private var inquiry: IOBluetoothDeviceInquiry!
    private var target: DeviceAddress?
    private var finished = false
    private var found: [BTDevice] = []

    override init() {
        super.init()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else { return }
        inquiry.updateNewDeviceNames = false
        inquiry.inquiryLength = 8
        self.inquiry = inquiry
    }

    func waitFor(address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        target = address
        return await run(timeout: timeout)
    }

    func collect(timeout: TimeInterval) async -> [BTDevice] {
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<[BTDevice], Never>) in
            self.listContinuation = continuation
            _ = self.runFlagged(timeout: timeout)
        }
        return found
    }

    func stop() {
        inquiry.stop()
        resume(false)
    }

    private func run(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            _ = self.runFlagged(timeout: timeout)
        }
    }

    private func runFlagged(timeout: TimeInterval) -> Bool {
        let result = inquiry.start()
        if result != kIOReturnSuccess {
            resume(false)
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            _ = MainActor.assumeIsolated {
                self.inquiry.stop()
            }
        }
        return true
    }

    private func resume(_ foundTarget: Bool) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: foundTarget)
        continuation = nil
        listContinuation?.resume(returning: found)
        listContinuation = nil
    }

    private func consider(address rawAddress: String, name: String) {
        let address = DeviceAddress(rawAddress)
        if !found.contains(where: { $0.address == address }) {
            found.append(BTDevice(address: address, name: name))
        }
        if let target, target == address {
            inquiry?.stop()
            resume(true)
        }
    }
}

extension InquirySession: IOBluetoothDeviceInquiryDelegate {
    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let device else { return }
        let address = device.addressString ?? ""
        let name = device.nameOrAddress ?? address
        MainActor.assumeIsolated {
            self.consider(address: address, name: name)
        }
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        MainActor.assumeIsolated {
            self.resume(false)
        }
    }
}

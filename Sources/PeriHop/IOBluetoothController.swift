import Foundation
import IOBluetooth

/// In-process IOBluetooth. Calls stay off a spawned `blueutil` so a connect
/// can be waited on, cancelled, and followed immediately by a pair.
struct LiveBluetoothController: BluetoothControlling {
    func disconnect(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        try await IOBluetoothWork.shared.disconnect(address, timeout: timeout)
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> LinkResult {
        await IOBluetoothWork.shared.connect(address, timeout: timeout)
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
        await IOBluetoothWork.shared.forget(address)
    }

    func pair(_ address: DeviceAddress) async throws {
        try await IOBluetoothWork.shared.pair(address)
    }

    func waitUntilDiscovered(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        await IOBluetoothWork.shared.waitUntilDiscovered(address, timeout: timeout)
    }

    func cancelOperations() async {
        await IOBluetoothWork.shared.cancelOperations()
    }

    func pairedDevices() async throws -> [BTDevice] {
        await IOBluetoothWork.shared.pairedDevices()
    }

    func inquire(timeout: TimeInterval) async throws -> [BTDevice] {
        await IOBluetoothWork.shared.inquire(timeout: timeout)
    }
}

/// Operations may overlap (a remote release can arrive mid-switch), so each
/// one tracks its own session and its own cancellation instead of sharing a
/// single slot or flag.
@MainActor
final class IOBluetoothWork {
    static let shared = IOBluetoothWork()

    private static let batteryKeys = [
        "batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight",
    ]

    private let suppressor = ReconnectSuppressor()
    private var sessions: [ObjectIdentifier: any BluetoothSession] = [:]
    /// Bumped by `cancelOperations`. An operation that started under an older
    /// value has been cancelled.
    private var epoch = 0
    private var loggedBattery: [DeviceAddress: Int] = [:]

    func disconnect(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        guard device(for: address)?.isConnected() == true else {
            AppLog.bluetooth.info("disconnect \(address.rawValue) already down")
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0
        while let current = device(for: address), current.isConnected() {
            let result = current.closeConnection()
            attempts += 1
            AppLog.bluetooth.info("disconnect \(address.rawValue) close=\(IOReturnLabel.describe(result)) attempt=\(attempts)")
            if result != kIOReturnSuccess && current.isConnected() && attempts == 1 {
                throw BluetoothError.failed("Couldn't disconnect \(address.rawValue).")
            }
            if device(for: address)?.isConnected() != true { return }
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if device(for: address)?.isConnected() == true {
            AppLog.bluetooth.error("disconnect \(address.rawValue) still connected after \(timeout)s")
            throw BluetoothError.failed("Couldn't disconnect \(address.rawValue).")
        }
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> LinkResult {
        let started = epoch
        guard let device = device(for: address) else {
            AppLog.bluetooth.error("connect \(address.rawValue) no device record")
            return .absent
        }
        if await held(device, since: started) {
            AppLog.bluetooth.info("connect \(address.rawValue) already connected paired=\(device.isPaired())")
            return .connected
        }
        guard !isCancelled(since: started) else { return .absent }
        // Page timeout is in units of 0.625ms. A nil target makes this call
        // synchronous and blocks the main actor for the whole page, so peer
        // messages time out. Pass a target and wait for connectionComplete.
        let pages = BluetoothHCIPageTimeout(max(1, min(timeout / 0.000625, Double(UInt16.max))))
        let began = Date()
        let opened = await run(ConnectionSession()) {
            await $0.open(device, pages: pages, timeout: timeout + 0.75)
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(began))
        let connected = device.isConnected()
        AppLog.bluetooth.info("connect \(address.rawValue) open=\(IOReturnLabel.describe(opened)) in \(elapsed)s paired=\(device.isPaired()) connected=\(connected) pageSlots=\(pages)")
        if isCancelled(since: started) { return .absent }
        // A timed-out page can still leave isConnected true for a few seconds.
        // That is the invalid-link-key ACL: bluetoothd reports HID result 151
        // and input never works. Only a stack success that stays up counts.
        guard opened == kIOReturnSuccess else {
            if connected {
                AppLog.bluetooth.error("connect \(address.rawValue) link rejected")
                return .refused
            }
            AppLog.bluetooth.info("connect \(address.rawValue) not connected")
            return .absent
        }
        guard await held(device, since: started) else {
            AppLog.bluetooth.error("connect \(address.rawValue) link dropped after open")
            return .refused
        }
        return .connected
    }

    func isConnected(_ address: DeviceAddress) -> Bool {
        device(for: address)?.isConnected() ?? false
    }

    func isPaired(_ address: DeviceAddress) -> Bool {
        device(for: address)?.isPaired() ?? false
    }

    func batteryPercent(_ address: DeviceAddress) -> Int? {
        guard let device = device(for: address) else { return nil }
        let reported = Self.reportedBattery(device)
        let registry = HIDBatteryRegistry.percent(address: address, name: device.name ?? "")
        let chosen = BatteryLevel.choose(reported: reported, registry: registry)
        let logged = chosen ?? 0
        if loggedBattery[address] != logged {
            loggedBattery[address] = logged
            let raw = reported.map(String.init).joined(separator: ",")
            AppLog.bluetooth.info("battery \(address.rawValue) bluetooth=[\(raw)] registry=\(registry.map(String.init) ?? "none") shown=\(chosen.map(String.init) ?? "hidden")")
        }
        return chosen
    }

    func suppress(_ address: DeviceAddress, safetyTimeout: TimeInterval) {
        suppressor.start(address, safetyTimeout: safetyTimeout) { [weak self] in
            guard let device = self?.device(for: address), device.isConnected() else { return nil }
            return device.closeConnection()
        }
    }

    func stopSuppressing(_ address: DeviceAddress) {
        suppressor.stop(address)
    }

    func forget(_ address: DeviceAddress) async {
        guard let device = device(for: address) else {
            AppLog.bluetooth.error("forget \(address.rawValue) no device record")
            return
        }
        if device.isConnected() {
            try? await disconnect(address, timeout: 2)
        }
        let remove = NSSelectorFromString("remove")
        guard device.responds(to: remove) else {
            AppLog.bluetooth.error("This macOS build can't forget \(address.rawValue)")
            return
        }
        _ = device.perform(remove)
        let stillPaired = self.device(for: address)?.isPaired() ?? false
        AppLog.bluetooth.info("forget \(address.rawValue) stillPaired=\(stillPaired)")
    }

    func pair(_ address: DeviceAddress) async throws {
        guard let device = device(for: address) else {
            AppLog.bluetooth.error("pair \(address.rawValue) no device record")
            throw BluetoothError.failed("\(address.rawValue) isn't available to pair.")
        }
        if device.isPaired() {
            AppLog.bluetooth.info("pair \(address.rawValue) already paired")
            return
        }
        AppLog.bluetooth.info("pair \(address.rawValue) start")
        try await run(PairSession()) { try await $0.pair(device) }
    }

    func waitUntilDiscovered(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        let started = epoch
        let found = await run(InquirySession()) {
            await $0.waitFor(address: address, timeout: timeout)
        }
        return found && !isCancelled(since: started)
    }

    func cancelOperations() {
        epoch += 1
        for session in Array(sessions.values) {
            session.stop()
        }
        AppLog.bluetooth.info("cancel bluetooth operations")
    }

    func pairedDevices() -> [BTDevice] {
        let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return list.compactMap(makeDevice)
    }

    func inquire(timeout: TimeInterval) async -> [BTDevice] {
        await run(InquirySession()) { await $0.collect(timeout: timeout) }
    }

    /// Keeps `session` reachable by `cancelOperations` while `body` waits on it.
    private func run<Session: BluetoothSession, T>(
        _ session: Session,
        _ body: @MainActor (Session) async throws -> T
    ) async rethrows -> T {
        let id = ObjectIdentifier(session)
        sessions[id] = session
        defer { sessions[id] = nil }
        return try await body(session)
    }

    private func isCancelled(since started: Int) -> Bool {
        epoch != started
    }

    /// True when the baseband link is up and still up after a short settle.
    private func held(_ device: IOBluetoothDevice, since started: Int) async -> Bool {
        guard device.isConnected() else { return false }
        try? await Task.sleep(nanoseconds: 400_000_000)
        return !isCancelled(since: started) && device.isConnected()
    }

    private func device(for address: DeviceAddress) -> IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address.rawValue)
    }

    private func makeDevice(_ device: IOBluetoothDevice) -> BTDevice? {
        guard let address = device.addressString else { return nil }
        let name = device.nameOrAddress ?? address
        return BTDevice(address: DeviceAddress(address), name: name)
    }

    /// IOBluetooth's cached levels. `batteryPercentSingle` reads 0 when it has
    /// no level, which `BatteryLevel.choose` ignores.
    private static func reportedBattery(_ device: IOBluetoothDevice) -> [Int] {
        batteryKeys.compactMap { key in
            guard device.responds(to: NSSelectorFromString(key)) else { return nil }
            return (device.value(forKey: key) as? NSNumber)?.intValue
        }
    }
}

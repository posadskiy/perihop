import Foundation
import IOBluetooth

/// In-process IOBluetooth.
struct LiveBluetoothController: BluetoothControlling {
    func isPoweredOn() async -> Bool {
        await IOBluetoothWork.shared.isPoweredOn()
    }

    func isConnected(_ address: DeviceAddress) async -> Bool {
        await IOBluetoothWork.shared.isConnected(address)
    }

    func isPaired(_ address: DeviceAddress) async -> Bool {
        await IOBluetoothWork.shared.isPaired(address)
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> LinkResult {
        await IOBluetoothWork.shared.connect(address, timeout: timeout)
    }

    func release(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        await IOBluetoothWork.shared.release(address, timeout: timeout)
    }

    func pair(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        try await IOBluetoothWork.shared.pair(address, timeout: timeout)
    }

    func cancelOperations() async {
        await IOBluetoothWork.shared.cancelOperations()
    }

    func batteryPercent(_ address: DeviceAddress) async -> Int? {
        await IOBluetoothWork.shared.batteryPercent(address)
    }

    func pairedDevices() async -> [BTDevice] {
        await IOBluetoothWork.shared.pairedDevices()
    }

    func inquire(timeout: TimeInterval) async -> [BTDevice] {
        await IOBluetoothWork.shared.inquire(timeout: timeout)
    }

    func events() async -> AsyncStream<LinkEvent> {
        await IOBluetoothWork.shared.events()
    }
}

/// Operations may overlap (a release from the other Mac can arrive while this
/// Mac is pairing something else), so each one tracks its own session and
/// its own cancellation.
@MainActor
final class IOBluetoothWork {
    static let shared = IOBluetoothWork()

    private static let batteryKeys = [
        "batteryPercentSingle", "batteryPercentCombined", "batteryPercentLeft", "batteryPercentRight",
    ]
    /// `remove` finishes inside bluetoothd after the call returns. Pairing
    /// before it has settled races the unbond and fails.
    private static let unbondSettle: UInt64 = 500_000_000

    private var sessions: [ObjectIdentifier: any BluetoothSession] = [:]
    /// Bumped by `cancelOperations`. An operation that started under an older
    /// value has been cancelled.
    private var epoch = 0
    private var loggedBattery: [DeviceAddress: Int] = [:]
    private var observer: LinkObserver?
    private var listeners: [UUID: AsyncStream<LinkEvent>.Continuation] = [:]

    func isPoweredOn() -> Bool {
        IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    }

    func isConnected(_ address: DeviceAddress) -> Bool {
        device(for: address)?.isConnected() ?? false
    }

    func isPaired(_ address: DeviceAddress) -> Bool {
        device(for: address)?.isPaired() ?? false
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> LinkResult {
        let started = epoch
        guard let device = device(for: address) else {
            AppLog.bluetooth.error("connect \(address.rawValue) no device record")
            return .absent
        }
        if await held(device, since: started) {
            AppLog.bluetooth.info("connect \(address.rawValue) already connected")
            return .connected
        }
        guard !isCancelled(since: started) else { return .absent }
        // Page timeout is in units of 0.625ms. A nil target makes this call
        // synchronous and blocks the main actor for the whole page, so the
        // target form is used and the result arrives in connectionComplete.
        let pages = BluetoothHCIPageTimeout(max(1, min(timeout / 0.000625, Double(UInt16.max))))
        let began = Date()
        let opened = await run(ConnectionSession()) {
            await $0.open(device, pages: pages, timeout: timeout + 0.75)
        }
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(began))
        let connected = device.isConnected()
        AppLog.bluetooth.info("connect \(address.rawValue) open=\(IOReturnLabel.describe(opened)) in \(elapsed)s paired=\(device.isPaired()) connected=\(connected)")
        if isCancelled(since: started) { return .absent }
        guard opened == kIOReturnSuccess else {
            // A failed open that still reads connected is the rejected-key
            // link: it is up at the baseband and carries no input.
            return connected ? .refused : .absent
        }
        guard await held(device, since: started) else {
            AppLog.bluetooth.error("connect \(address.rawValue) link dropped after open")
            return .refused
        }
        return .connected
    }

    func release(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        guard let device = device(for: address) else { return true }
        let wasConnected = device.isConnected()
        let wasPaired = device.isPaired()
        let remove = NSSelectorFromString("remove")
        if device.responds(to: remove) {
            // No disconnect first. Unpairing over a live link is what tells
            // the accessory to drop this host and listen for a new one. An
            // accessory that was only disconnected keeps calling this Mac.
            _ = device.perform(remove)
        } else {
            AppLog.bluetooth.error("release \(address.rawValue): this macOS can't unpair, closing the link instead")
            _ = device.closeConnection()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var nudged = false
        while self.device(for: address)?.isConnected() == true, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            // bluetoothd usually drops the link itself within a second.
            if !nudged, deadline.timeIntervalSinceNow < timeout - 2 {
                nudged = true
                _ = self.device(for: address)?.closeConnection()
            }
        }
        let current = self.device(for: address)
        let down = current?.isConnected() != true
        AppLog.bluetooth.info("release \(address.rawValue) wasConnected=\(wasConnected) wasPaired=\(wasPaired) down=\(down) paired=\(current?.isPaired() ?? false)")
        if wasPaired {
            try? await Task.sleep(nanoseconds: Self.unbondSettle)
            // On macOS 27 a remove over a live link sometimes does not take,
            // and the device then reconnects to this Mac by itself.
            for attempt in 1...3 where self.device(for: address)?.isPaired() == true {
                AppLog.bluetooth.error("release \(address.rawValue) still paired, removing again (\(attempt))")
                if let again = self.device(for: address), again.responds(to: remove) {
                    if again.isConnected() { _ = again.closeConnection() }
                    _ = again.perform(remove)
                }
                try? await Task.sleep(nanoseconds: Self.unbondSettle)
            }
        }
        return down && self.device(for: address)?.isPaired() != true
    }

    func pair(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        guard isPoweredOn() else { throw BluetoothError.unavailable }
        guard let device = device(for: address) else {
            throw BluetoothError.failed("\(address.rawValue) isn't available to pair.")
        }
        if device.isPaired() {
            AppLog.bluetooth.info("pair \(address.rawValue) already paired")
            return
        }
        let began = Date()
        AppLog.bluetooth.info("pair \(address.rawValue) start timeout=\(Int(timeout))s")
        try await run(PairSession()) { try await $0.pair(device, timeout: timeout) }
        AppLog.bluetooth.info("pair \(address.rawValue) done in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")
    }

    func cancelOperations() {
        epoch += 1
        for session in Array(sessions.values) {
            session.stop()
        }
        AppLog.bluetooth.info("cancel bluetooth operations")
    }

    func batteryPercent(_ address: DeviceAddress) -> Int? {
        guard let device = device(for: address) else { return nil }
        let reported = Self.reportedBattery(device)
        let registry = HIDBatteryRegistry.percent(address: address, name: device.name ?? "")
        let chosen = BatteryLevel.choose(reported: reported, registry: registry)
        let logged = chosen ?? 0
        if loggedBattery[address] != logged {
            loggedBattery[address] = logged
            AppLog.bluetooth.info("battery \(address.rawValue) shown=\(chosen.map(String.init) ?? "hidden")")
        }
        return chosen
    }

    func pairedDevices() -> [BTDevice] {
        let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return list.compactMap(makeDevice)
    }

    func inquire(timeout: TimeInterval) async -> [BTDevice] {
        await run(InquirySession()) { await $0.collect(timeout: timeout) }
    }

    func events() -> AsyncStream<LinkEvent> {
        startObserving()
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        listeners[id] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor in IOBluetoothWork.shared.listeners[id] = nil }
        }
        return stream
    }

    fileprivate func publish(_ event: LinkEvent) {
        for listener in listeners.values {
            listener.yield(event)
        }
    }

    private func startObserving() {
        guard observer == nil else { return }
        let observer = LinkObserver()
        self.observer = observer
        observer.start()
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

    /// True when the link is up and still up after a short settle.
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
        // Major class 5 is "peripheral": keyboards, mice, trackpads. A
        // device that reports no class is kept.
        let major = device.deviceClassMajor
        let isInput: Bool
        if major == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral) {
            isInput = true
        } else if major == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorMiscellaneous)
            || major == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorUnclassified) {
            // A paired device that is not connected often reports no class.
            isInput = BTDevice.nameSuggestsInput(name)
        } else {
            isInput = false
        }
        return BTDevice(address: DeviceAddress(address), name: name, isInput: isInput)
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

/// Receives IOBluetooth's connect and disconnect notifications. A disconnect
/// observer exists per connected device and is replaced on every connect.
@MainActor
private final class LinkObserver: NSObject {
    private var connectToken: IOBluetoothUserNotification?
    private var disconnectTokens: [DeviceAddress: IOBluetoothUserNotification] = [:]

    func start() {
        connectToken = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(connected(_:device:))
        )
        // Devices connected before launch never produce a connect notification.
        for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] where device.isConnected() {
            watch(device)
        }
    }

    /// IOBluetooth calls these on its own queue, so they must not be
    /// main-actor methods: Swift traps when one is entered off the actor.
    @objc nonisolated private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let raw = device.addressString else { return }
        Task { @MainActor in
            let address = DeviceAddress(raw)
            if let device = IOBluetoothDevice(addressString: address.rawValue) {
                self.watch(device)
            }
            IOBluetoothWork.shared.publish(.connected(address))
        }
    }

    @objc nonisolated private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let raw = device.addressString else { return }
        Task { @MainActor in
            let address = DeviceAddress(raw)
            self.disconnectTokens.removeValue(forKey: address)?.unregister()
            IOBluetoothWork.shared.publish(.disconnected(address))
        }
    }

    private func watch(_ device: IOBluetoothDevice) {
        guard let raw = device.addressString else { return }
        let address = DeviceAddress(raw)
        disconnectTokens.removeValue(forKey: address)?.unregister()
        disconnectTokens[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(disconnected(_:device:))
        )
    }
}

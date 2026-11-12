import Foundation
@testable import PeriHop

/// A radio with one-host accessories. An accessory that is `listening`
/// accepts a pairing, and comes up connected when it does, as a Magic
/// keyboard does. One that is not listening is off, asleep, or with another
/// host.
actor MockBluetoothController: BluetoothControlling {
    private(set) var calls: [String] = []
    private(set) var cancelled = false

    var powered = true
    var connected: Set<DeviceAddress> = []
    var paired: Set<DeviceAddress> = []
    var listening: Set<DeviceAddress> = []
    /// Pairings the accessory no longer honors.
    var stale: Set<DeviceAddress> = []
    /// Links that stay up through a release.
    var stuck: Set<DeviceAddress> = []

    private var listeners: [AsyncStream<LinkEvent>.Continuation] = []

    func set(connected: Set<DeviceAddress> = [], paired: Set<DeviceAddress> = [], listening: Set<DeviceAddress> = []) {
        self.connected = connected
        self.paired = paired.union(connected)
        self.listening = listening
    }

    func setStale(_ addresses: Set<DeviceAddress>) { stale = addresses }
    func setStuck(_ addresses: Set<DeviceAddress>) { stuck = addresses }
    func setPowered(_ on: Bool) { powered = on }

    /// The accessory wakes up and starts accepting a host.
    func wake(_ address: DeviceAddress) {
        listening.insert(address)
    }

    /// The accessory goes away: switched off or out of range.
    func drop(_ address: DeviceAddress) {
        guard connected.remove(address) != nil else { return }
        listening.remove(address)
        emit(.disconnected(address))
    }

    func count(_ call: String) -> Int {
        calls.filter { $0 == call }.count
    }

    func isPoweredOn() async -> Bool { powered }

    func isConnected(_ address: DeviceAddress) async -> Bool {
        connected.contains(address)
    }

    func isPaired(_ address: DeviceAddress) async -> Bool {
        paired.contains(address)
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> LinkResult {
        calls.append("connect \(address.rawValue)")
        if connected.contains(address) { return .connected }
        guard listening.contains(address) else { return .absent }
        guard paired.contains(address), !stale.contains(address) else { return .refused }
        connected.insert(address)
        emit(.connected(address))
        return .connected
    }

    func release(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        calls.append("release \(address.rawValue)")
        if stuck.contains(address) { return false }
        paired.remove(address)
        stale.remove(address)
        if connected.remove(address) != nil {
            // Told over the live link, the accessory listens for a new host.
            listening.insert(address)
            emit(.disconnected(address))
        }
        return true
    }

    func pair(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        calls.append("pair \(address.rawValue)")
        guard powered else { throw BluetoothError.unavailable }
        guard listening.contains(address) else {
            throw BluetoothError.failed("Pairing timed out.")
        }
        paired.insert(address)
        connected.insert(address)
        emit(.connected(address))
    }

    func cancelOperations() async {
        cancelled = true
    }

    func batteryPercent(_ address: DeviceAddress) async -> Int? { nil }
    func pairedDevices() async -> [BTDevice] { [] }
    func inquire(timeout: TimeInterval) async -> [BTDevice] { [] }

    func events() async -> AsyncStream<LinkEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LinkEvent.self)
        listeners.append(continuation)
        return stream
    }

    private func emit(_ event: LinkEvent) {
        for listener in listeners {
            listener.yield(event)
        }
    }
}

/// The other Mac. With `radio` set it shares the test's radio, so a release
/// it grants frees the accessory the way a real one would.
actor MockPeer: PeerLinking {
    var linked = true
    var reachable = true
    var held: Set<DeviceAddress> = []
    var devices: [DeviceEntry] = []
    var grantsRelease = true
    /// Reachable, but with no connection open yet, as over Bluetooth.
    var slowToAnswer = false
    var acceptsTake = true

    private(set) var releaseRequests: [[DeviceAddress]] = []
    private(set) var takeRequests: [[DeviceEntry]] = []
    private(set) var outcomes: [DeviceAddress: Bool] = [:]
    private(set) var statuses: [PeerStatus] = []

    private var radio: MockBluetoothController?
    private var onTake: (@Sendable ([DeviceEntry]) async -> Void)?

    func set(linked: Bool = true, reachable: Bool = true, held: Set<DeviceAddress> = []) {
        self.linked = linked
        self.reachable = reachable
        self.held = held
    }

    func setGrantsRelease(_ value: Bool) { grantsRelease = value }
    func setSlowToAnswer(_ value: Bool) { slowToAnswer = value }
    func setAcceptsTake(_ value: Bool) { acceptsTake = value }
    func setReachable(_ value: Bool) { reachable = value }
    func setHeld(_ value: Set<DeviceAddress>) { held = value }
    func share(_ radio: MockBluetoothController) { self.radio = radio }
    func onTake(_ body: @escaping @Sendable ([DeviceEntry]) async -> Void) { onTake = body }

    func isLinked() async -> Bool { linked }

    func isConnected() async -> Bool { linked && reachable && !slowToAnswer }

    func ping(timeout: TimeInterval) async -> Bool { linked && reachable }

    func status(timeout: TimeInterval) async -> PeerStatus? {
        guard linked, reachable else { return nil }
        if slowToAnswer {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        return PeerStatus(held: held.sorted { $0.rawValue < $1.rawValue }, devices: devices)
    }

    func requestRelease(_ addresses: [DeviceAddress], timeout: TimeInterval) async -> Set<DeviceAddress>? {
        releaseRequests.append(addresses)
        guard linked, reachable else { return nil }
        guard grantsRelease else { return [] }
        for address in addresses {
            held.remove(address)
            await radio?.wake(address)
        }
        return Set(addresses)
    }

    func requestTake(_ devices: [DeviceEntry], timeout: TimeInterval) async -> Bool {
        takeRequests.append(devices)
        guard linked, reachable, acceptsTake else { return false }
        if let onTake {
            Task { await onTake(devices) }
        }
        return true
    }

    func notifyOutcome(_ address: DeviceAddress, connected: Bool) async {
        outcomes[address] = connected
    }

    func notifyStatus(_ status: PeerStatus) async {
        statuses.append(status)
    }
}

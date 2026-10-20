import Foundation
@testable import PeriHop

actor MockBluetoothController: BluetoothControlling {
    private(set) var disconnects: [DeviceAddress] = []
    private(set) var connects: [DeviceAddress] = []
    private(set) var suppressions: [DeviceAddress] = []
    private(set) var forgotten: [DeviceAddress] = []
    private(set) var pairs: [DeviceAddress] = []
    private(set) var discoveries: [DeviceAddress] = []
    private(set) var cancelled = false

    var connected: Set<DeviceAddress> = []
    var paired: Set<DeviceAddress> = []
    var connectResults: [DeviceAddress: [Bool]] = [:]
    var discoverResults: [DeviceAddress: [Bool]] = [:]
    var pairError: Error?

    func disconnect(_ address: DeviceAddress, timeout: TimeInterval) async throws {
        disconnects.append(address)
        connected.remove(address)
    }

    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        connects.append(address)
        let scripted = connectResults[address] ?? []
        let result = scripted.isEmpty ? connected.contains(address) : scripted[min(connects.filter { $0 == address }.count - 1, scripted.count - 1)]
        if result { connected.insert(address) }
        return result
    }

    func isConnected(_ address: DeviceAddress) async -> Bool {
        connected.contains(address)
    }

    func isPaired(_ address: DeviceAddress) async -> Bool {
        paired.contains(address)
    }

    func suppress(_ address: DeviceAddress, safetyTimeout: TimeInterval) async {
        suppressions.append(address)
    }

    func stopSuppressing(_ address: DeviceAddress) async {
        suppressions.removeAll { $0 == address }
    }

    func forget(_ address: DeviceAddress) async {
        forgotten.append(address)
        paired.remove(address)
    }

    func pair(_ address: DeviceAddress) async throws {
        pairs.append(address)
        if let pairError { throw pairError }
        paired.insert(address)
    }

    func waitUntilDiscovered(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        discoveries.append(address)
        let scripted = discoverResults[address] ?? []
        let index = discoveries.filter { $0 == address }.count - 1
        guard !scripted.isEmpty else { return false }
        return scripted[min(index, scripted.count - 1)]
    }

    func cancelOperations() async {
        cancelled = true
    }

    func pairedDevices() async throws -> [BTDevice] { [] }

    func inquire(timeout: TimeInterval) async throws -> [BTDevice] { [] }

    func batteryPercent(_ address: DeviceAddress) async -> Int? { nil }
}

actor MockPeer: PeerLinking {
    var reachable = true
    private(set) var releases: [(DeviceAddress, Bool)] = []
    private(set) var owned: [DeviceAddress] = []
    private(set) var failed: [DeviceAddress] = []
    private(set) var rollbacks: [DeviceAddress] = []
    private(set) var sleeping: [DeviceAddress] = []
    var remoteClaims: [ClaimStamp] = []

    func ping(timeout: TimeInterval) async -> Bool { reachable }

    func requestRelease(_ address: DeviceAddress, forget: Bool, timeout: TimeInterval) async throws {
        releases.append((address, forget))
    }

    func notifyOwned(_ address: DeviceAddress) async {
        owned.append(address)
    }

    func notifyFailed(_ address: DeviceAddress) async {
        failed.append(address)
    }

    func requestRollback(_ address: DeviceAddress, timeout: TimeInterval) async {
        rollbacks.append(address)
    }

    func notifySleeping(_ addresses: [DeviceAddress]) async {
        sleeping.append(contentsOf: addresses)
    }

    func exchangeClaims(_ local: [ClaimStamp], timeout: TimeInterval) async -> [ClaimStamp] {
        reachable ? remoteClaims : []
    }
}

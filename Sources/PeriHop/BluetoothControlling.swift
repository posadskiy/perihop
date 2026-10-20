import Foundation

enum DeviceStatus: Equatable, Sendable {
    /// Never checked yet (e.g. popover just opened, first poll hasn't landed).
    case unknown
    /// Checked — confirmed not connected.
    case disconnected
    case working
    case success
    case failure(String)
}

struct BTDevice: Identifiable, Hashable, Sendable {
    var address: DeviceAddress
    var name: String
    var id: DeviceAddress { address }
}

enum BluetoothError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Bluetooth is unavailable."
        case .failed(let message):
            return message
        }
    }
}

struct HandoffTimings: Sendable, Equatable {
    var peerPing: TimeInterval = 1.2
    var connect: TimeInterval = 5
    var discoverFirst: TimeInterval = 12
    var discoverSecond: TimeInterval = 35
    var releaseTimeout: TimeInterval = 8
    var claimTimeout: TimeInterval = 2
    var suppressSafety: TimeInterval = 180
    var sleepDisconnect: TimeInterval = 1
    /// How long to look for an accessory that went idle while a Mac slept.
    var wakeWatch: TimeInterval = 120
    /// Inquiry used to tell "refused the bond" from "not here".
    var rangeProbe: TimeInterval = 4
}

/// The radio operations the handoff depends on. Production uses IOBluetooth.
/// Tests substitute a mock so the state machine never touches the radio.
protocol BluetoothControlling: Sendable {
    func disconnect(_ address: DeviceAddress, timeout: TimeInterval) async throws
    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool
    func isConnected(_ address: DeviceAddress) async -> Bool
    func isPaired(_ address: DeviceAddress) async -> Bool
    /// Closes the link again if macOS reconnects it, until `stopSuppressing`
    /// or the safety timeout. This is what stops the current Mac from
    /// grabbing the accessory back during a handoff.
    func suppress(_ address: DeviceAddress, safetyTimeout: TimeInterval) async
    func stopSuppressing(_ address: DeviceAddress) async
    func forget(_ address: DeviceAddress) async
    func pair(_ address: DeviceAddress) async throws
    func waitUntilDiscovered(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool
    func batteryPercent(_ address: DeviceAddress) async -> Int?
    func cancelOperations() async
    func pairedDevices() async throws -> [BTDevice]
    func inquire(timeout: TimeInterval) async throws -> [BTDevice]
}

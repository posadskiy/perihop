import Foundation

struct BTDevice: Identifiable, Hashable, Sendable {
    var address: DeviceAddress
    var name: String
    /// False for a phone, watch, headset, or anything else whose Bluetooth
    /// class says it is not a keyboard or pointing device.
    var isInput = true
    var id: DeviceAddress { address }

    /// For a device that reports no Bluetooth class. Phones, watches and
    /// audio gear are paired to a Mac too and are never switched.
    static func nameSuggestsInput(_ name: String) -> Bool {
        let name = name.lowercased()
        let other = ["iphone", "ipad", "watch", "airpods", "beats", "headphone", "buds", "speaker", "homepod"]
        return !other.contains { name.contains($0) }
    }
}

enum LinkResult: Sendable, Equatable {
    /// The link is up and stayed up after the stack accepted it.
    case connected
    /// The accessory did not answer the page: off, asleep, out of range, or
    /// connected to another host.
    case absent
    /// The accessory answered and the link was rejected or died. This is
    /// what a stale link key looks like: `isConnected` can read true for a
    /// few seconds while no input arrives.
    case refused
}

enum LinkEvent: Sendable, Equatable {
    case connected(DeviceAddress)
    case disconnected(DeviceAddress)
}

enum BluetoothError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Bluetooth is off."
        case .failed(let message):
            return message
        }
    }
}

/// The radio operations a handoff is built from. Production uses IOBluetooth.
/// Tests substitute a mock so the engine never touches the radio.
///
/// A Magic accessory keeps one host. Moving it is always the same two steps:
/// the Mac that has it calls `release` while the link is up, which tells the
/// accessory its host is gone, and the Mac that wants it calls `pair`.
protocol BluetoothControlling: Sendable {
    func isPoweredOn() async -> Bool
    func isConnected(_ address: DeviceAddress) async -> Bool
    func isPaired(_ address: DeviceAddress) async -> Bool

    /// Opens the link with the pairing this Mac already has.
    func connect(_ address: DeviceAddress, timeout: TimeInterval) async -> LinkResult

    /// Removes this Mac's pairing. Done while the link is up, the accessory is
    /// told and starts accepting a new host right away. Returns false when
    /// the link is still up after `timeout`.
    func release(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool

    /// Pairs by address. The accessory does not have to show up in a scan
    /// first. Waits up to `timeout` for it to answer.
    func pair(_ address: DeviceAddress, timeout: TimeInterval) async throws

    /// Ends every wait in progress.
    func cancelOperations() async

    func batteryPercent(_ address: DeviceAddress) async -> Int?
    func pairedDevices() async -> [BTDevice]
    func inquire(timeout: TimeInterval) async -> [BTDevice]

    /// Links coming up and going down, from any cause.
    func events() async -> AsyncStream<LinkEvent>
}

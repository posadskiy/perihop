import Foundation

enum PeerError: Error, LocalizedError, Sendable, Equatable {
    case noCode
    case unreachable
    case handshakeFailed
    case timeout
    case closed

    var errorDescription: String? {
        switch self {
        case .noCode:
            return "Link the two Macs with a pairing code in Settings."
        case .unreachable:
            return "The other Mac isn't reachable."
        case .handshakeFailed:
            return "The other Mac rejected the pairing code."
        case .timeout:
            return "The other Mac didn't answer in time."
        case .closed:
            return "The link to the other Mac closed."
        }
    }
}

/// One message between the Macs. A reply carries the id of its request.
///
/// | type | sender means | reply |
/// | --- | --- | --- |
/// | `ping` | are you there | `pong` |
/// | `status` | what do you have | `status` with `held` and `devices` |
/// | `release` | let go of `addresses` | `released` with the ones freed |
/// | `take` | I freed `devices`, connect them | `taking`, or `declined` |
/// | `outcome` | `addresses` did or did not connect (`ok`) | `ack` |
/// | `hello` | my address is `host`, I have `held` | `ack` |
struct PeerMessage: Codable, Sendable, Equatable {
    /// Bumped when the two Macs can no longer understand each other.
    static let currentVersion = 2

    var id: UUID
    var type: String
    var addresses: [String]?
    var devices: [DeviceEntry]?
    var held: [String]?
    var ok: Bool?
    var host: String?
    var version: Int?

    init(
        id: UUID = UUID(),
        type: String,
        addresses: [String]? = nil,
        devices: [DeviceEntry]? = nil,
        held: [String]? = nil,
        ok: Bool? = nil,
        host: String? = nil
    ) {
        self.id = id
        self.type = type
        self.addresses = addresses
        self.devices = devices
        self.held = held
        self.ok = ok
        self.host = host
        self.version = Self.currentVersion
    }

    func reply(
        type: String,
        addresses: [String]? = nil,
        devices: [DeviceEntry]? = nil,
        held: [String]? = nil
    ) -> PeerMessage {
        PeerMessage(id: id, type: type, addresses: addresses, devices: devices, held: held)
    }

    var status: PeerStatus? {
        guard let held else { return nil }
        return PeerStatus(held: held.map { DeviceAddress($0) }, devices: devices ?? [])
    }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

/// Log formatting for peer messages. Heartbeats stay out of the log.
enum PeerTraffic {
    static func notable(_ message: PeerMessage) -> Bool {
        switch message.type {
        case "ping", "pong", "hello", "ack", "status":
            return false
        default:
            return true
        }
    }

    static func line(_ message: PeerMessage) -> String {
        var parts = ["\(message.type) id=\(message.id.uuidString.prefix(8))"]
        if let addresses = message.addresses, !addresses.isEmpty {
            parts.append(addresses.joined(separator: ","))
        }
        if let devices = message.devices, !devices.isEmpty {
            parts.append(devices.map(\.address.rawValue).joined(separator: ","))
        }
        if let ok = message.ok { parts.append("ok=\(ok)") }
        return parts.join(" ")
    }
}

private extension Array where Element == String {
    func join(_ separator: String) -> String { joined(separator: separator) }
}

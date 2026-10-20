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

struct PeerMessage: Codable, Sendable, Equatable {
    var id: UUID
    var type: String
    var address: String?
    var addresses: [String]?
    var forget: Bool?
    var stamps: [ClaimStamp]?
    var name: String?
    var host: String?

    func reply(type: String, stamps: [ClaimStamp]? = nil) -> PeerMessage {
        PeerMessage(id: id, type: type, address: address, addresses: addresses, forget: forget, stamps: stamps, name: name, host: host)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Log formatting for peer messages. Heartbeats stay out of the log.
enum PeerTraffic {
    static func notable(_ message: PeerMessage) -> Bool {
        switch message.type {
        case "ping", "pong", "hello":
            return false
        case "ack":
            return message.address != nil || message.addresses != nil || message.stamps != nil
        default:
            return true
        }
    }

    static func line(_ message: PeerMessage) -> String {
        var parts = ["\(message.type) id=\(message.id.uuidString.prefix(8))"]
        if let address = message.address { parts.append(address) }
        if let forget = message.forget { parts.append("forget=\(forget)") }
        if let addresses = message.addresses, !addresses.isEmpty {
            parts.append(addresses.joined(separator: ","))
        }
        if let host = message.host, !host.isEmpty { parts.append("host=\(host)") }
        if let stamps = message.stamps {
            let summary = stamps.map { "\($0.address) mine=\($0.mine)" }.joined(separator: ";")
            parts.append("stamps=\(summary)")
        }
        return parts.joined(separator: " ")
    }
}

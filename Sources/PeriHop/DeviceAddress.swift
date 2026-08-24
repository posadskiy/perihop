import Foundation

/// A Bluetooth device's MAC address, as a distinct type instead of a raw
/// `String` — the compiler can no longer confuse an address with a device
/// name at a call site. Encodes/decodes as a plain string so the on-disk
/// config format (and blueutil's CLI args) are unaffected.
struct DeviceAddress: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.rawValue = value
    }

    var description: String { rawValue }
}

extension DeviceAddress: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

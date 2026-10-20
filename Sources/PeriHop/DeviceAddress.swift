import Foundation

/// A Bluetooth device's MAC address, as a distinct type instead of a raw
/// `String` — the compiler can no longer confuse an address with a device
/// name at a call site. Encodes/decodes as a plain string so the on-disk
/// config format (and blueutil's CLI args) are unaffected.
struct DeviceAddress: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = Self.normalize(rawValue)
    }

    init(stringLiteral value: String) {
        self.rawValue = Self.normalize(value)
    }

    /// `AA:BB:CC:DD:EE:FF` and `aa-bb-cc-dd-ee-ff` name the same radio.
    static func normalize(_ raw: String) -> String {
        let hex = raw.lowercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return raw.lowercased() }
        var parts: [String] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index..<next]))
            index = next
        }
        return parts.joined(separator: "-")
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

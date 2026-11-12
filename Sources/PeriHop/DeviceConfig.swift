import Foundation

enum DeviceKind: String, Sendable {
    case keyboard
    case trackpad
    case mouse
    case other

    init(name: String) {
        let name = name.lowercased()
        if name.contains("trackpad") || name.contains("track pad") {
            self = .trackpad
        } else if name.contains("mouse") {
            self = .mouse
        } else if name.contains("keyboard") {
            self = .keyboard
        } else {
            self = .other
        }
    }

    var symbol: String {
        switch self {
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .mouse: return "magicmouse"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }
}

/// A device this Mac switches. Which Mac has it is read from the live
/// Bluetooth link, so nothing about that is saved.
struct DeviceEntry: Codable, Equatable, Hashable, Sendable {
    var name: String
    var address: DeviceAddress

    var kind: DeviceKind { DeviceKind(name: name) }

    /// Trackpad first, then mouse, then keyboard, so a keyboard that fails
    /// still leaves something to click with.
    static func handoffOrder(_ devices: [DeviceEntry]) -> [DeviceEntry] {
        devices.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private static func rank(_ device: DeviceEntry) -> Int {
        switch device.kind {
        case .trackpad: return 0
        case .mouse, .other: return 1
        case .keyboard: return 2
        }
    }
}

struct DeviceConfig: Codable, Equatable, Sendable {
    var devices: [DeviceEntry]
}

enum DeviceConfigStore {
    private static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("PeriHop", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("config.json")
    }

    static func load() -> DeviceConfig? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(DeviceConfig.self, from: data)
        } catch {
            AppLog.config.error("Failed to decode saved config, starting fresh: \(error)")
            return nil
        }
    }

    static func save(_ config: DeviceConfig) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}

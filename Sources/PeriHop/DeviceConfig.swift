import Foundation

enum BondMode: String, Codable, Equatable, Sendable {
    /// Not yet observed. The next switch tries a connect before forgetting.
    case unknown
    /// Connected on the second Mac without a new pairing.
    case multi
    /// The accessory accepted only one host, so a switch has to pair again.
    case single
}

enum DeviceHolder: String, Codable, Equatable, Sendable {
    case unknown
    case thisMac
    case otherMac
}

struct DeviceEntry: Codable, Equatable, Sendable {
    var name: String
    var address: DeviceAddress
    var bondMode: BondMode
    var holder: DeviceHolder
    var holderSince: Date?

    init(
        name: String,
        address: DeviceAddress,
        bondMode: BondMode = .unknown,
        holder: DeviceHolder = .unknown,
        holderSince: Date? = nil
    ) {
        self.name = name
        self.address = address
        self.bondMode = bondMode
        self.holder = holder
        self.holderSince = holderSince
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(DeviceAddress.self, forKey: .address)
        bondMode = try container.decodeIfPresent(BondMode.self, forKey: .bondMode) ?? .unknown
        holder = try container.decodeIfPresent(DeviceHolder.self, forKey: .holder) ?? .unknown
        holderSince = try container.decodeIfPresent(Date.self, forKey: .holderSince)
    }

    /// Trackpad first, then mouse, then keyboard, so a failed keyboard
    /// still leaves something to click with.
    static func handoffOrder(_ devices: [DeviceEntry]) -> [DeviceEntry] {
        devices.sorted { rank($0) < rank($1) }
    }

    private static func rank(_ device: DeviceEntry) -> Int {
        let name = device.name.lowercased()
        if name.contains("trackpad") || name.contains("track pad") { return 0 }
        if name.contains("mouse") { return 1 }
        if name.contains("keyboard") { return 2 }
        return 1
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

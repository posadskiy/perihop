import Foundation

struct DeviceEntry: Codable, Equatable, Sendable {
    var name: String
    var address: String
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
        return try? JSONDecoder().decode(DeviceConfig.self, from: data)
    }

    static func save(_ config: DeviceConfig) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}

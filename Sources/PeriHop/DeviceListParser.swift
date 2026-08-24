import Foundation

/// Pure parsing logic for blueutil's `--format json` output, pulled out of
/// `BluetoothController` so it's testable without spawning a real process.
enum DeviceListParser {
    struct ProcessResult: Sendable {
        var status: Int32
        var output: String
        var wasAborted: Bool
    }

    static func parse(_ result: ProcessResult) throws -> [BTDevice] {
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status != 0 {
            if result.wasAborted {
                throw BlueUtilError.commandFailed(
                    "Bluetooth access denied. Grant it in System Settings \u{2192} Privacy & Security \u{2192} Bluetooth, then quit and reopen PeriHop."
                )
            }
            throw BlueUtilError.commandFailed(trimmed.isEmpty ? "blueutil failed (exit \(result.status))" : trimmed)
        }
        guard let data = result.output.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let address = entry["address"] as? String else { return nil }
            let name = (entry["name"] as? String) ?? address
            return BTDevice(address: DeviceAddress(address), name: name)
        }
    }
}

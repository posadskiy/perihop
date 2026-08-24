import Foundation

struct BTDevice: Identifiable, Hashable, Sendable {
    var address: String
    var name: String
    var id: String { address }
}

enum BlueUtilError: Error, LocalizedError, Sendable {
    case notInstalled
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "blueutil is missing. If you're running PeriHop from source (swift run), install it with: brew install blueutil"
        case .commandFailed(let message):
            return message
        }
    }
}

enum BluetoothController {
    /// Prefers the copy bundled inside the app (Contents/Resources/blueutil) so
    /// end users don't need Homebrew installed. Falls back to Homebrew's path
    /// for local development via `swift run`, which has no app bundle.
    static var blueutilPath: String? {
        if let bundled = Bundle.main.url(forResource: "blueutil", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        let candidates = ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    @discardableResult
    private static func run(_ args: [String], timeout: TimeInterval = 15) throws -> (status: Int32, output: String, wasAborted: Bool) {
        guard let path = blueutilPath else { throw BlueUtilError.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Watchdog: some accessories can make blueutil hang (e.g. waiting on
        // an interactive PIN it'll never get), so never block forever.
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()

        let wasAborted = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGABRT
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output, wasAborted)
    }

    /// Best-effort unpair — ignores failures (device may not be paired here).
    static func unpair(_ address: String) {
        _ = try? run(["--unpair", address])
    }

    static func pair(_ address: String) throws {
        let result = try run(["--pair", address], timeout: 20)
        if result.status != 0 {
            throw BlueUtilError.commandFailed(
                "Pairing failed for \(address): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    static func connect(_ address: String) throws {
        let result = try run(["--connect", address])
        if result.status != 0 {
            throw BlueUtilError.commandFailed(
                "Connect failed for \(address): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    static func waitConnect(_ address: String, timeout: Int) -> Bool {
        let result = try? run(["--wait-connect", address, String(timeout)], timeout: TimeInterval(timeout) + 5)
        return result?.status == 0
    }

    static func isConnected(_ address: String) -> Bool {
        let result = try? run(["--is-connected", address])
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func inquiry(duration: Int = 8) throws -> [BTDevice] {
        try parseDevices(from: run(["--inquiry", String(duration), "--format", "json"], timeout: TimeInterval(duration) + 5))
    }

    /// Devices already paired to this Mac — no pairing mode needed.
    static func paired() throws -> [BTDevice] {
        try parseDevices(from: run(["--paired", "--format", "json"]))
    }

    private static func parseDevices(from result: (status: Int32, output: String, wasAborted: Bool)) throws -> [BTDevice] {
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
            return BTDevice(address: address, name: name)
        }
    }
}

import Foundation
import Darwin
import os

struct BTDevice: Identifiable, Hashable, Sendable {
    var address: DeviceAddress
    var name: String
    var id: DeviceAddress { address }
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

    /// Runs blueutil without blocking a thread while it waits: `Process`
    /// launches non-blocking, and we resume via `terminationHandler` instead
    /// of a synchronous `waitUntilExit()`. A watchdog escalates SIGTERM to
    /// SIGKILL if the process ignores the polite request to stop.
    @discardableResult
    private static func run(_ args: [String], timeout: TimeInterval = 15) async throws -> DeviceListParser.ProcessResult {
        guard let path = blueutilPath else { throw BlueUtilError.notInstalled }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // `terminationHandler` and the synchronous `process.run()` catch
            // below are two paths that could both try to resume — guard with
            // a lock-protected flag rather than a captured `var` so this is
            // provably Sendable-safe instead of relying on "it happens to
            // only race in practice one way".
            let didResume = OSAllocatedUnfairLock(initialState: false)
            let resumeOnce: @Sendable (Result<DeviceListParser.ProcessResult, Error>) -> Void = { result in
                let shouldResume = didResume.withLock { resumed -> Bool in
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
                if shouldResume {
                    continuation.resume(with: result)
                }
            }

            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let wasAborted = proc.terminationReason == .uncaughtSignal && proc.terminationStatus == SIGABRT
                resumeOnce(.success(.init(status: proc.terminationStatus, output: output, wasAborted: wasAborted)))
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(error))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                AppLog.bluetooth.warning("blueutil \(args.first ?? "?") exceeded \(timeout)s, sending SIGTERM")
                process.terminate()
                // Some processes ignore SIGTERM (e.g. stuck on a blocking
                // syscall) — escalate rather than hang forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning {
                        AppLog.bluetooth.error("blueutil \(args.first ?? "?") ignored SIGTERM, sending SIGKILL")
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }

    /// Best-effort unpair — ignores failures (device may not be paired here).
    static func unpair(_ address: DeviceAddress) async {
        _ = try? await run(["--unpair", address.rawValue])
    }

    static func pair(_ address: DeviceAddress) async throws {
        let result = try await run(["--pair", address.rawValue], timeout: 20)
        if result.status != 0 {
            let message = "Pairing failed for \(address): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            AppLog.bluetooth.error("\(message)")
            throw BlueUtilError.commandFailed(message)
        }
    }

    static func connect(_ address: DeviceAddress) async throws {
        let result = try await run(["--connect", address.rawValue])
        if result.status != 0 {
            let message = "Connect failed for \(address): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            AppLog.bluetooth.error("\(message)")
            throw BlueUtilError.commandFailed(message)
        }
    }

    static func waitConnect(_ address: DeviceAddress, timeout: Int) async -> Bool {
        let result = try? await run(["--wait-connect", address.rawValue, String(timeout)], timeout: TimeInterval(timeout) + 5)
        return result?.status == 0
    }

    static func isConnected(_ address: DeviceAddress) async -> Bool {
        let result = try? await run(["--is-connected", address.rawValue])
        return result?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func inquiry(duration: Int = 8) async throws -> [BTDevice] {
        let result = try await run(["--inquiry", String(duration), "--format", "json"], timeout: TimeInterval(duration) + 5)
        return try DeviceListParser.parse(result)
    }

    /// Devices already paired to this Mac — no pairing mode needed.
    static func paired() async throws -> [BTDevice] {
        let result = try await run(["--paired", "--format", "json"])
        return try DeviceListParser.parse(result)
    }
}

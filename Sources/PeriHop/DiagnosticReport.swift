import AppKit
import Foundation
import UniformTypeIdentifiers

/// A text file the other Mac can save and send back. It contains PeriHop's
/// own log plus the Bluetooth messages for the configured accessories, which
/// is where a refused link key shows up.
enum DiagnosticReport {
    static func make(devices: [DeviceEntry]) async -> String {
        let addresses = devices.map(\.address)
        async let appLog = LogFile.contents()
        let start = windowStart(now: Date(), clearedAt: clearedAt())
        async let unified = runLog(predicate: "subsystem == \"\(AppLog.subsystem)\"", start: start)
        async let bluetooth = runLog(predicate: bluetoothPredicate(addresses: addresses), start: start)
        let sections = await [
            header(devices: devices),
            section("PeriHop log", appLog.isEmpty ? "No PeriHop log yet.\n" : appLog),
            section("Unified log, subsystem \(AppLog.subsystem), since \(stamp(start))", unified),
            section("Bluetooth log for PeriHop and these accessories, since \(stamp(start))", bluetooth),
        ]
        return sections.joined(separator: "\n")
    }

    @MainActor
    static func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Save PeriHop diagnostics"
        panel.prompt = "Save"
        panel.nameFieldStringValue = fileName()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static let clearedAtKey = "diagnosticsSince"

    /// Drops the saved PeriHop log and ignores system-log lines from before now.
    static func clear() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: clearedAtKey)
        LogFile.clear()
    }

    /// Reports cover at most the last 6 hours, and nothing from before Clear diagnostics.
    static func windowStart(now: Date, clearedAt: Date?) -> Date {
        let sixHours = now.addingTimeInterval(-6 * 60 * 60)
        guard let clearedAt else { return sixHours }
        return max(sixHours, clearedAt)
    }

    static func bluetoothPredicate(addresses: [DeviceAddress]) -> String {
        var parts = [
            "(process == \"PeriHop\" AND subsystem == \"com.apple.bluetooth\")",
            "(process == \"bluetoothd\" AND (eventMessage CONTAINS \"perihop\" OR eventMessage CONTAINS \"INVALID_LINK_KEY\" OR eventMessage CONTAINS \"HID Host\"))",
        ]
        for address in addresses {
            let colon = address.rawValue.replacingOccurrences(of: "-", with: ":")
            let forms = [colon, colon.uppercased(), address.rawValue]
            let quoted = forms.map { "eventMessage CONTAINS \"\($0)\"" }.joined(separator: " OR ")
            parts.append("(process == \"bluetoothd\" AND (\(quoted)))")
        }
        return parts.joined(separator: " OR ")
    }

    private static func header(devices: [DeviceEntry]) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var lines = [
            "PeriHop diagnostics",
            "Host: \(host)",
            "Date: \(stamp(Date()))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "App: \(version) (\(build))",
            "Devices:",
        ]
        if devices.isEmpty {
            lines.append("  (none)")
        } else {
            for device in devices {
                lines.append("  \(device.name)  \(device.address.rawValue)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func section(_ title: String, _ body: String) -> String {
        "===== \(title) =====\n\(tail(body))\n"
    }

    /// Keep the file sendable if Bluetooth has been noisy for hours.
    private static func tail(_ text: String, limit: Int = 1_500_000) -> String {
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        return "[earlier output truncated]\n" + text[start...]
    }

    private static func fileName() -> String {
        let host = (Host.current().localizedName ?? "Mac")
            .replacingOccurrences(of: " ", with: "-")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "PeriHop-\(host)-\(formatter.string(from: Date())).txt"
    }

    private static func logStart(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func clearedAt() -> Date? {
        let stored = UserDefaults.standard.double(forKey: clearedAtKey)
        guard stored > 0 else { return nil }
        return Date(timeIntervalSince1970: stored)
    }

    private static func runLog(predicate: String, start: Date) async -> String {
        await Task.detached(priority: .userInitiated) {
            collectLog(predicate: predicate, start: start)
        }.value
    }

    private static func collectLog(predicate: String, start: Date) -> String {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("perihop-log-\(UUID().uuidString).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--start", logStart(start),
            "--predicate", predicate,
            "--style", "compact",
            "--info",
        ]
        do {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            let finished = done.wait(timeout: .now() + 30) == .success
            if !finished {
                process.terminate()
                _ = done.wait(timeout: .now() + 2)
            }
            try? handle.close()
            let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: output)
            if !finished {
                return "log show timed out after 30s\n\(text)"
            }
            if process.terminationStatus != 0 {
                return "log show exited \(process.terminationStatus)\n\(text)"
            }
            return text.isEmpty ? "(no matching entries)\n" : text
        } catch {
            try? FileManager.default.removeItem(at: output)
            return "log show failed: \(error.localizedDescription)\n"
        }
    }
}

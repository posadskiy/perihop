import Foundation
import IOKit
import os

/// Unified logging plus a plain-text copy. Console redacts string arguments
/// unless they are marked public, so the text file is what a problem report
/// should contain.
enum AppLog {
    static let subsystem = "com.posadskiy.perihop"

    static let bluetooth = Channel("Bluetooth")
    static let switchFlow = Channel("SwitchFlow")
    static let config = Channel("Config")
    static let peer = Channel("Peer")

    struct Channel {
        let name: String
        let logger: Logger

        init(_ name: String) {
            self.name = name
            logger = Logger(subsystem: AppLog.subsystem, category: name)
        }

        func info(_ message: String) {
            write(.info, message)
        }

        func error(_ message: String) {
            write(.error, message)
        }

        private func write(_ level: OSLogType, _ message: String) {
            logger.log(level: level, "\(message, privacy: .public)")
            LogFile.append(category: name, level: level, message)
        }
    }
}

enum IOReturnLabel {
    static func describe(_ value: IOReturn) -> String {
        let hex = String(format: "0x%08X", value)
        let name: String
        switch value {
        case kIOReturnSuccess: name = "success"
        case kIOReturnError: name = "error"
        case kIOReturnNoDevice: name = "noDevice"
        case kIOReturnUnsupported: name = "unsupported"
        case kIOReturnBusy: name = "busy"
        case kIOReturnTimeout: name = "timeout"
        case kIOReturnOffline: name = "offline"
        case kIOReturnNotAttached: name = "notAttached"
        case kIOReturnNotFound: name = "notFound"
        case kIOReturnAborted: name = "aborted"
        case kIOReturnNotResponding: name = "notResponding"
        default: name = "other"
        }
        return "\(name) \(hex)"
    }
}

enum LogFile {
    private static let queue = DispatchQueue(label: "com.posadskiy.perihop.logfile")
    private static let maxBytes = 1_500_000
    private static let mirrorToFile: Bool = {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil { return false }
        if info.environment["XCTestSessionIdentifier"] != nil { return false }
        let name = info.processName.lowercased()
        if name.contains("xctest") { return false }
        return Bundle.main.bundleIdentifier == "com.posadskiy.perihop"
    }()

    static var url: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("PeriHop/diagnostics.log", isDirectory: false)
    }

    static func append(category: String, level: OSLogType, _ message: String) {
        guard mirrorToFile else { return }
        let stamp = timestamp()
        let marker = level == .error ? "E" : "I"
        let line = "\(stamp) \(marker) [\(category)] \(message)\n"
        queue.async {
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                rotateIfNeeded()
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
            } catch {
                // The system log still has the line. A full disk should not
                // change the handoff.
            }
        }
    }

    static func contents() -> String {
        queue.sync {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }

    private static var rotatedURL: URL {
        url.deletingPathExtension().appendingPathExtension("log.1")
    }
}

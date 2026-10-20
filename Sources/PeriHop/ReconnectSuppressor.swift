import Foundation
import IOKit

/// Closes an accessory's link again each time macOS reconnects it, until
/// `stop` or the safety timeout. Starting again for the same address
/// replaces the earlier loop.
@MainActor
final class ReconnectSuppressor {
    /// Closes the link if it is up and returns the result, or nil when it was down.
    typealias Close = @MainActor () -> IOReturn?

    private struct Loop {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let interval: TimeInterval
    private var loops: [DeviceAddress: Loop] = [:]

    init(interval: TimeInterval = 0.4) {
        self.interval = interval
    }

    func isSuppressing(_ address: DeviceAddress) -> Bool {
        loops[address] != nil
    }

    func start(_ address: DeviceAddress, safetyTimeout: TimeInterval, close: @escaping Close) {
        loops[address]?.task.cancel()
        AppLog.bluetooth.info("suppress \(address.rawValue) for \(Int(safetyTimeout))s")
        let id = UUID()
        let deadline = Date().addingTimeInterval(safetyTimeout)
        let pause = UInt64(interval * 1_000_000_000)
        let task = Task { @MainActor [weak self] in
            var closed = 0
            while !Task.isCancelled && Date() < deadline {
                if let result = close() {
                    closed += 1
                    AppLog.bluetooth.info("suppress \(address.rawValue) closed reconnect #\(closed) \(IOReturnLabel.describe(result))")
                }
                try? await Task.sleep(nanoseconds: pause)
            }
            if !Task.isCancelled {
                AppLog.bluetooth.info("suppress \(address.rawValue) safety timeout after \(closed) closes")
            }
            // A replaced loop must not clear the loop that replaced it.
            if self?.loops[address]?.id == id {
                self?.loops[address] = nil
            }
        }
        loops[address] = Loop(id: id, task: task)
    }

    func stop(_ address: DeviceAddress) {
        guard let loop = loops.removeValue(forKey: address) else { return }
        loop.task.cancel()
        AppLog.bluetooth.info("suppress \(address.rawValue) stop")
    }
}

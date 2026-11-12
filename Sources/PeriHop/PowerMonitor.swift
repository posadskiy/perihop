import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// Sleep and wake from the power manager. Unlike the workspace
/// notifications, this holds sleep back until the work is done, so devices
/// can be freed and the other Mac told before the radios go down.
@MainActor
final class PowerMonitor {
    /// Runs before sleep. Sleep waits for it, up to `budget` seconds.
    var onWillSleep: (() async -> Void)?
    var onDidWake: (() -> Void)?
    var budget: TimeInterval = 6

    private static let canSleep: UInt32 = 0xE000_0270
    private static let willSleep: UInt32 = 0xE000_0280
    private static let hasPoweredOn: UInt32 = 0xE000_0300

    private var root: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    func start() {
        guard root == 0 else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(context, &port, { context, _, type, argument in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            let token = Int(bitPattern: argument)
            MainActor.assumeIsolated {
                monitor.handle(type, token: token)
            }
        }, &notifier)
        guard root != 0, let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    /// False during a dark wake: the Mac is up for a network or timer
    /// event and its display is still off.
    static func displayIsAwake() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    /// True for a MacBook with its lid shut. Always false on a desktop Mac.
    static func lidIsClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private func handle(_ type: UInt32, token: Int) {
        switch type {
        case Self.canSleep:
            IOAllowPowerChange(root, token)
        case Self.willSleep:
            let gate = Once()
            let allow: @MainActor () -> Void = { [root] in
                gate.run { IOAllowPowerChange(root, token) }
            }
            Task { @MainActor in
                await self.onWillSleep?()
                allow()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(self.budget * 1_000_000_000))
                allow()
            }
        case Self.hasPoweredOn:
            onDidWake?()
        default:
            break
        }
    }
}

@MainActor
private final class Once {
    private var done = false

    func run(_ body: () -> Void) {
        guard !done else { return }
        done = true
        body()
    }
}

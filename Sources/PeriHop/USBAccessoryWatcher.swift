import Foundation
import IOKit
import IOKit.usb

/// Fires when an Apple USB device is attached, which is how a Magic
/// accessory pairs itself when the cable is plugged in.
final class USBAccessoryWatcher: @unchecked Sendable {
    private var notifyPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private let onAttach: @Sendable () -> Void
    private var primed = false

    init(onAttach: @escaping @Sendable () -> Void) {
        self.onAttach = onAttach
    }

    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matching[kUSBVendorID as String] = NSNumber(value: 0x05AC)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching,
            { ref, iterator in
                guard let ref else { return }
                let watcher = Unmanaged<USBAccessoryWatcher>.fromOpaque(ref).takeUnretainedValue()
                watcher.drain(iterator)
            },
            context,
            &iterator
        )
        drain(iterator)
    }

    private func drain(_ iterator: io_iterator_t) {
        var sawNew = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            sawNew = true
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        // The first callback lists devices that were already plugged in.
        guard primed else {
            primed = true
            return
        }
        if sawNew {
            onAttach()
        }
    }

    deinit {
        if iterator != 0 {
            IOObjectRelease(iterator)
        }
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
    }
}

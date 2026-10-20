import Foundation
import IOKit

/// `batteryPercentSingle` stays 0 when IOBluetooth has no cached level, which
/// happens on a normal Bluetooth connection. That 0 is not a charge. The HID
/// registry `BatteryPercent` is the level Control Center shows.
enum BatteryLevel {
    static func choose(reported: [Int], registry: Int?) -> Int? {
        (reported + [registry].compactMap { $0 }).first(where: isLevel)
    }

    static func isLevel(_ value: Int) -> Bool {
        (1...100).contains(value)
    }

    /// Only used when no registry entry carries the address. Several
    /// accessories matching one name but reporting different levels is
    /// ambiguous, and showing another device's charge is worse than none.
    static func chooseByName(_ levels: [Int]) -> Int? {
        let distinct = Set(levels)
        return distinct.count == 1 ? distinct.first : nil
    }

    static func namesMatch(product: String, device: String) -> Bool {
        let product = product.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard product.count >= 4, device.count >= 4 else { return false }
        if product.caseInsensitiveCompare(device) == .orderedSame { return true }
        return device.localizedCaseInsensitiveContains(product)
            || product.localizedCaseInsensitiveContains(device)
    }

    static func matchesAddress(_ value: Any, address: DeviceAddress) -> Bool {
        if let text = value as? String {
            return DeviceAddress(text).rawValue == address.rawValue
        }
        guard let bytes = value as? Data, bytes.count == 6 else { return false }
        let forward = DeviceAddress(bytes.map { String(format: "%02x", $0) }.joined())
        let reverse = DeviceAddress(bytes.reversed().map { String(format: "%02x", $0) }.joined())
        return forward.rawValue == address.rawValue || reverse.rawValue == address.rawValue
    }
}

/// Reads accessory battery levels from the IOKit HID registry.
enum HIDBatteryRegistry {
    private static let classes = [
        "AppleDeviceManagementHIDEventService",
        "IOBluetoothHIDDriver",
        "AppleHSBluetoothHIDDriver",
    ]

    static func percent(address: DeviceAddress, name: String) -> Int? {
        var named: [Int] = []
        for className in classes {
            guard let services = matching(className) else { continue }
            defer { services.forEach { IOObjectRelease($0) } }
            for service in services {
                guard let percent = percent(on: service) else { continue }
                if treeContainsAddress(service, address) { return percent }
                if productMatches(service, name: name) { named.append(percent) }
            }
        }
        return BatteryLevel.chooseByName(named)
    }

    private static func matching(_ className: String) -> [io_registry_entry_t]? {
        guard let matching = IOServiceMatching(className) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var services: [io_registry_entry_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
    }

    private static func percent(on service: io_registry_entry_t) -> Int? {
        for key in ["BatteryPercent", "BatteryPercentSingle"] {
            guard let value = property(service, key) as? NSNumber else { continue }
            let percent = value.intValue
            if BatteryLevel.isLevel(percent) { return percent }
        }
        return nil
    }

    private static func treeContainsAddress(_ service: io_registry_entry_t, _ address: DeviceAddress) -> Bool {
        var current = service
        var parents: [io_registry_entry_t] = []
        defer { parents.forEach { IOObjectRelease($0) } }
        for _ in 0..<6 {
            if properties(current).values.contains(where: { BatteryLevel.matchesAddress($0, address: address) }) {
                return true
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            parents.append(parent)
            current = parent
        }
        return false
    }

    private static func productMatches(_ service: io_registry_entry_t, name: String) -> Bool {
        guard let product = property(service, "Product") as? String else { return false }
        return BatteryLevel.namesMatch(product: product, device: name)
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func properties(_ service: io_registry_entry_t) -> [String: Any] {
        var raw: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = raw?.takeRetainedValue() as? [String: Any] else { return [:] }
        return values
    }
}

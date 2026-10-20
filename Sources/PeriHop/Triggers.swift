import AppKit
import Carbon
import CoreGraphics
import Foundation

struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String

    static let empty = Shortcut(keyCode: 0, modifiers: 0, label: "None")

    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    init(_ event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = Self.carbon(event.modifierFlags)
        label = Self.describe(event)
    }

    private static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    private static func describe(_ event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        let character = event.charactersIgnoringModifiers?.uppercased() ?? ""
        parts.append(character.isEmpty ? "Key \(event.keyCode)" : character)
        return parts.joined()
    }
}

/// Global shortcuts through Carbon, which does not ask for Accessibility.
final class HotkeyCenter: @unchecked Sendable {
    var onAction: (@Sendable (UInt32) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var installed = false

    func install(_ shortcuts: [(UInt32, Shortcut)]) {
        clear()
        ensureHandler()
        for (id, shortcut) in shortcuts where !shortcut.isEmpty {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5048_4F50), id: id)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    private func ensureHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user -> OSStatus in
            guard let event, let user else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(user).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                center.onAction?(id)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func clear() {
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
        refs = []
    }
}

final class DisplayWatcher: @unchecked Sendable {
    var onAdded: (@Sendable (String) -> Void)?

    func start() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ display, flags, user in
            guard let user, flags.contains(.addFlag) else { return }
            let watcher = Unmanaged<DisplayWatcher>.fromOpaque(user).takeUnretainedValue()
            guard let id = DisplayWatcher.uuid(for: display) else { return }
            watcher.onAdded?(id)
        }, pointer)
    }

    static func online() -> [String] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { uuid(for: $0) }
    }

    static func uuid(for display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

final class URLReceiver: NSObject {
    var onURL: (@Sendable (URL) -> Void)?

    func start() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handle(_:with:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handle(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        onURL?(url)
    }
}

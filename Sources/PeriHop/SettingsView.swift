import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    var onDone: () -> Void

    @EnvironmentObject private var model: AppModel
    @AppStorage("showDeviceAddresses") private var showDeviceAddresses = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?
    @State private var code: String = ""
    @State private var host: String = ""
    @State private var fingerprint = ""
    @State private var displays: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    setLaunchAtLogin(newValue)
                }

            Toggle("Show device addresses", isOn: $showDeviceAddresses)

            Divider()

            Text("Link the other Mac").font(.subheadline)
            Text("Enter the same code on both Macs. PeriHop uses it to ask the other Mac to let go of the keyboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Pairing code", text: $code)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Generate") {
                    code = PairingCode.generate()
                    refreshFingerprint()
                }
                Spacer()
                if !fingerprint.isEmpty {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Other Mac's address (optional)", text: $host)
                .textFieldStyle(.roundedBorder)
            Text("Leave this empty on a normal network. If the other Mac doesn't appear, enter its IP address.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.trustMismatch {
                Text("The other Mac's identity changed.")
                    .font(.caption)
                Button("Trust this Mac") { model.trustOffered() }
            }

            Divider()
            Text("Shortcuts").font(.subheadline)
            ShortcutButton(title: "Use here", shortcut: $model.takeShortcut)
            ShortcutButton(title: "Hand off", shortcut: $model.sendShortcut)
            ShortcutButton(title: "Toggle", shortcut: $model.toggleShortcut)
            Text("Recorded while this window is open. Esc clears a shortcut.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Text("Dock a display").font(.subheadline)
            Text("When a checked display connects, PeriHop takes the devices.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(displays, id: \.self) { id in
                Toggle(isOn: Binding(
                    get: { model.dockDisplays.contains(id) },
                    set: { model.setDock(id, enabled: $0) }
                )) {
                    Text(id).font(.caption.monospaced()).lineLimit(1)
                }
            }

            if let message = model.pairingCodeError ?? errorMessage {
                ErrorBox(message: message)
            }

            Divider()
            HStack {
                Button("Save") {
                    model.savePairing(code: code, host: host)
                }
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            code = model.pairingCode
            host = model.peerHost
            displays = DisplayWatcher.online()
            refreshFingerprint()
        }
        .onChange(of: code) { _ in refreshFingerprint() }
        .onDisappear { model.saveShortcuts() }
    }

    private func refreshFingerprint() {
        let normalized = PairingCode.normalize(code)
        fingerprint = normalized.count >= 8 ? PeerCrypto.fingerprint(code: normalized) : ""
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ShortcutButton: View {
    let title: String
    @Binding var shortcut: Shortcut
    @State private var recording = false

    var body: some View {
        HStack {
            Text(title).font(.caption)
            Spacer()
            Button(recording ? "Type shortcut" : shortcut.label) {
                recording.toggle()
            }
        }
        .background(ShortcutMonitor(recording: recording, onCapture: { captured in
            shortcut = captured
            recording = false
        }))
    }
}

private struct ShortcutMonitor: NSViewRepresentable {
    var recording: Bool
    var onCapture: (Shortcut) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.recording = recording
        context.coordinator.onCapture = onCapture
        context.coordinator.sync()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var recording = false
        var monitor: Any?
        var onCapture: ((Shortcut) -> Void)?

        func sync() {
            if recording, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard self.recording else { return event }
                    if event.keyCode == 53 {
                        self.onCapture?(.empty)
                    } else {
                        self.onCapture?(Shortcut(event))
                    }
                    return nil
                }
            } else if !recording, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

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
    @State private var showIPAddress = false
    @State private var confirmUnpair = false
    @AppStorage("showDebugTools") private var showDebugTools = false
    @State private var displays: [DockDisplay] = []
    @State private var exporting = false
    @State private var exportNote: String?

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
            Text(isLinked ? "Linked with the other Mac." : "Leave this code on screen for the other Mac to type, or type that Mac's code here and press Pair.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospaced())
                    .disabled(isLinked || model.isPairing)
                if isLinked {
                    Button("Unpair") { confirmUnpair = true }
                } else {
                    Button {
                        code = model.refreshOffer()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("New code")
                    .disabled(model.isPairing)
                    Button(model.isPairing ? "Pairing…" : "Pair") {
                        Task { await connect() }
                    }
                    .disabled(model.isPairing)
                }
            }

            if showIPAddress {
                TextField("Other Mac's IP address", text: $host)
                    .textFieldStyle(.roundedBorder)
                Text("Used when the other Mac doesn't appear on its own.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Use IP address") { showIPAddress = true }
                    .font(.caption)
            }

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
            if displays.isEmpty {
                Text("No external displays connected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(displays) { display in
                Toggle(isOn: Binding(
                    get: { model.dockDisplays.contains(display.id) },
                    set: { model.setDock(display.id, enabled: $0) }
                )) {
                    Text(display.name).lineLimit(1)
                }
            }

            if let message = model.pairingCodeError ?? errorMessage {
                ErrorBox(message: message)
            }

            Divider()
            Toggle("Debug", isOn: $showDebugTools)
            if showDebugTools {
                HStack {
                    Button(exporting ? "Saving…" : "Save diagnostics") {
                        Task { await saveDiagnostics() }
                    }
                    .disabled(exporting)
                    Button("Clear diagnostics") { clearDiagnostics() }
                        .disabled(exporting)
                }
                Text("Save writes the switch, link, and Bluetooth log. Clear keeps only what happens after this moment.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let exportNote {
                    Text(exportNote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            code = model.pairingCode.isEmpty ? model.prepareOffer() : model.pairingCode
            host = model.peerHost
            showIPAddress = !host.isEmpty
            displays = DisplayWatcher.externalOnline()
        }
        .onChange(of: code) { newValue in
            let capped = cappedCode(newValue)
            if capped != code { code = capped }
        }
        .onChange(of: model.pairingCode) { newValue in
            if !newValue.isEmpty { code = newValue }
        }
        .onDisappear { model.saveShortcuts() }
        .alert("Unpair the other Mac?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac forgets the code and shows a new one. The other Mac has to use that code to link again.")
        }
    }

    private var isLinked: Bool {
        !model.pairingCode.isEmpty
    }

    private func connect() async {
        let ok = await model.pair(code: code, host: showIPAddress ? host : "")
        if ok {
            code = model.pairingCode
            host = model.peerHost
        }
    }

    private func unpair() {
        Task {
            await model.unpair()
            code = model.prepareOffer()
            host = ""
            showIPAddress = false
        }
    }

    private func done() {
        if isLinked {
            model.updatePeerHost(showIPAddress ? host : model.peerHost)
        }
        onDone()
    }

    private func cappedCode(_ raw: String) -> String {
        let normalized = PairingCode.normalize(raw)
        let saved = PairingCode.normalize(model.pairingCode)
        if saved.count > PairingCode.length, normalized == saved {
            return saved
        }
        return String(normalized.prefix(PairingCode.length))
    }

    private func clearDiagnostics() {
        DiagnosticReport.clear()
        exportNote = "Diagnostics cleared. The next save starts from now."
        errorMessage = nil
    }

    private func saveDiagnostics() async {
        exporting = true
        defer { exporting = false }
        let report = await DiagnosticReport.make(devices: model.config?.devices ?? [])
        guard let url = DiagnosticReport.chooseDestination() else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            exportNote = "Saved \(url.lastPathComponent)."
            errorMessage = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
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

import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var onDone: () -> Void
    var onAbout: () -> Void

    @EnvironmentObject private var model: AppModel
    @AppStorage("showDeviceAddresses") private var showDeviceAddresses = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?
    @State private var code = ""
    @State private var host = ""
    @State private var showAddress = false
    @State private var confirmUnpair = false
    @State private var displays: [DockDisplay] = []
    @State private var exporting = false
    @State private var exportNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Settings", onBack: done)

            otherMac
            Divider()
            behavior
            Divider()
            shortcuts
            Divider()
            dock
            Divider()
            diagnostics

            if let message = model.pairingCodeError ?? errorMessage {
                ErrorBox(message: message)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(MenuLayout.padding)
        .onAppear {
            code = model.pairingCode.isEmpty ? model.prepareOffer() : model.pairingCode
            host = model.peerHost
            showAddress = !host.isEmpty
            displays = DisplayWatcher.externalOnline()
        }
        .onChange(of: code) { _, newValue in
            let capped = String(PairingCode.normalize(newValue).prefix(max(PairingCode.length, model.pairingCode.count)))
            if capped != code { code = capped }
        }
        .onChange(of: model.pairingCode) { _, newValue in
            if !newValue.isEmpty { code = newValue }
        }
        .onChange(of: showAddress) { StatusMenu.shared.relayoutSoon() }
        .onDisappear { model.saveShortcuts() }
        .alert("Unlink the other Mac?", isPresented: $confirmUnpair) {
            Button("Unlink", role: .destructive) { unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This Mac forgets the code and shows a new one. The other Mac has to use that code to link again.")
        }
    }

    // MARK: Sections

    private var otherMac: some View {
        MenuSection(title: "Other Mac") {
            Text(linkText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospaced())
                    .disabled(model.isLinked || model.isPairing)
                    .accessibilityLabel("Pairing code")
                if model.isLinked {
                    Button("Unlink") { confirmUnpair = true }
                } else {
                    Button {
                        code = model.refreshOffer()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("New code")
                    .disabled(model.isPairing)
                    Button(model.isPairing ? "Linking…" : "Link") {
                        Task { await link() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isPairing)
                }
            }
            .controlSize(.regular)

            if model.peerState == .untrusted {
                HStack {
                    Text("The other Mac's pairing code changed.").font(.caption)
                    Spacer()
                    Button("Trust") { model.trustOffered() }
                }
            }

            Toggle(isOn: $model.bluetoothLink) {
                label("Reach it over Bluetooth", "Used when a VPN or the Wi-Fi keeps the two Macs apart.")
            }

            if showAddress {
                TextField("Other Mac's IP address", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
            } else {
                Button("Enter its IP address…") { showAddress = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var behavior: some View {
        MenuSection(title: "Automatic") {
            Toggle(isOn: $model.releaseOnSleep) {
                label(
                    "Let go when this Mac sleeps",
                    "The other Mac takes the devices if it is awake. With the lid closed on a display they stay otherwise, so the keyboard can wake this Mac."
                )
            }
            .disabled(!model.isLinked)
            Toggle(isOn: $model.takeOnWake) {
                label("Take free devices on wake", "Never from a Mac that is using them.")
            }
            .disabled(!model.isLinked)
            Toggle(isOn: $model.reconnectDropped) {
                label("Reconnect a device that drops", "For example after it was switched off and on.")
            }
            Toggle(isOn: $launchAtLogin) {
                Text("Open at login").frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: launchAtLogin) { _, newValue in
                setLaunchAtLogin(newValue)
            }
        }
    }

    private var shortcuts: some View {
        MenuSection(title: "Shortcuts") {
            ShortcutButton(title: "Use here", shortcut: $model.takeShortcut)
            ShortcutButton(title: "Send to other Mac", shortcut: $model.sendShortcut)
            ShortcutButton(title: "Toggle", shortcut: $model.toggleShortcut)
            Text("Click a shortcut, then type it. Esc clears it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var dock: some View {
        MenuSection(title: "Take devices when a display connects") {
            if displays.isEmpty {
                Text("No external display is connected right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(displays) { display in
                Toggle(isOn: Binding(
                    get: { model.dockDisplays.contains(display.id) },
                    set: { model.setDock(display.id, enabled: $0) }
                )) {
                    Text(display.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var diagnostics: some View {
        MenuSection(title: "Troubleshooting") {
            Toggle(isOn: $showDeviceAddresses) {
                Text("Show device addresses").frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(exporting ? "Saving…" : "Save Diagnostics…") {
                    Task { await saveDiagnostics() }
                }
                .disabled(exporting)
                Button("Clear") { clearDiagnostics() }
                    .disabled(exporting)
                Spacer()
                Button("About", action: onAbout)
                    .buttonStyle(.link)
            }
            if let exportNote {
                Text(exportNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var linkText: String {
        switch model.peerState {
        case .notLinked:
            return "Open Settings on both Macs. Type the code one Mac shows into the other, then press Link there."
        case .reachable(let bluetooth):
            return bluetooth ? "Linked. The other Mac answers over Bluetooth." : "Linked. The other Mac answers."
        case .unreachable:
            return "Linked. The other Mac is asleep or away."
        case .untrusted:
            return "Linked, but the other Mac now shows a different code."
        case .outdated:
            return "Linked. The other Mac runs an older PeriHop and needs an update."
        }
    }

    // MARK: Actions

    private func link() async {
        if await model.pair(code: code, host: showAddress ? host : "") {
            code = model.pairingCode
            host = model.peerHost
        }
    }

    private func unpair() {
        Task {
            await model.unpair()
            code = model.prepareOffer()
            host = ""
            showAddress = false
        }
    }

    private func done() {
        if model.isLinked {
            model.updatePeerHost(showAddress ? host : "")
        }
        onDone()
    }

    private func clearDiagnostics() {
        DiagnosticReport.clear()
        exportNote = "Cleared. The next save starts from now."
        errorMessage = nil
    }

    private func saveDiagnostics() async {
        exporting = true
        defer { exporting = false }
        let report = await DiagnosticReport.make(devices: model.devices)
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
            Text(title)
            Spacer()
            Button(recording ? "Type shortcut…" : shortcut.label) {
                recording.toggle()
            }
            .accessibilityLabel("\(title) shortcut, \(shortcut.label)")
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

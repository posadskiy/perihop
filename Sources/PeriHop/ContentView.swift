import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSetup = false
    @State private var showSettings = false
    @State private var showInfo = false
    @State private var saveErrorMessage: String?

    var body: some View {
        Group {
            if showInfo {
                InfoView(onDone: { showInfo = false })
            } else if showSettings {
                SettingsView(onDone: { showSettings = false })
            } else if showSetup || model.config == nil {
                SetupView(
                    existing: model.config,
                    onSave: { newConfig in
                        do {
                            try DeviceConfigStore.save(newConfig)
                            saveErrorMessage = nil
                            model.config = newConfig
                            model.handoff.useDevices(newConfig.devices)
                            showSetup = false
                        } catch {
                            AppLog.config.error("Failed to save config: \(error.localizedDescription)")
                            saveErrorMessage = "Couldn't save: \(error.localizedDescription)"
                        }
                    },
                    onCancel: model.config == nil ? nil : { showSetup = false },
                    saveErrorMessage: saveErrorMessage
                )
            } else if let config = model.config {
                mainView(config: config)
            }
        }
        .onAppear { model.menuVisible = true }
        .onDisappear { model.menuVisible = false }
    }

    @ViewBuilder
    private func mainView(config: DeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "keyboard")
                Text("PeriHop").font(.headline)
                Spacer()
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Text(peerLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.trustMismatch {
                Text("The other Mac's identity changed. Trust it in Settings before switching.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(config.devices, id: \.address) { device in
                deviceRow(device)
            }

            if let summary = model.handoff.summary, model.handoff.activity == .finished {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let prompt = promptText {
                Text(prompt)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.handoff.activity == .working {
                HStack {
                    ProgressView().controlSize(.small)
                    Spacer()
                    Button("Stop") { model.handoff.stop() }
                }
            } else {
                Button("Use here") {
                    model.bringHere(config.devices)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                Button("Hand off") {
                    model.sendAway(config.devices)
                }
                .frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                Button("Edit Devices…") { showSetup = true }
                    .disabled(model.handoff.activity == .working)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 340)
        .task(id: config) {
            while !Task.isCancelled {
                model.handoff.refreshStatuses(devices: config.devices)
                await model.refreshPeer()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private var peerLine: String {
        if model.pairingCode.isEmpty {
            return "Link your other Mac in Settings to switch in one click."
        }
        if model.peerReachable {
            return "Other Mac is reachable."
        }
        return "Other Mac is asleep or offline. Use here still tries."
    }

    private var promptText: String? {
        switch model.handoff.prompt {
        case .none:
            return nil
        case .peerAsleep:
            return "The other Mac isn't answering. Connecting to the keyboard directly."
        case .pressKey(let name):
            return "Press a key on \(name), or click the trackpad."
        case .powerCycle(let name):
            return "Turn \(name) off, then on. If it still doesn't appear, plug in its cable."
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: DeviceEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(device.name).font(.subheadline)
                Spacer()
                if let percent = model.batteries[device.address] {
                    Text("\(percent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch model.handoff.status(for: device.address) {
                case .unknown:
                    EmptyView()
                case .disconnected:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                case .working:
                    ProgressView().controlSize(.small)
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            if case .failure(let message) = model.handoff.status(for: device.address) {
                ErrorBox(message: message)
            }
            if model.handoff.activity != .working {
                HStack {
                    Button("Use here") { model.bringHere([device]) }
                    Button("Hand off") { model.sendAway([device]) }
                }
                .font(.caption)
            }
        }
    }
}

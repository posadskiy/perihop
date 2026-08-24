import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var switchFlow = SwitchFlowViewModel()
    @State private var config: DeviceConfig? = DeviceConfigStore.load()
    @State private var showSetup = false
    @State private var blueutilMissing = BluetoothController.blueutilPath == nil

    var body: some View {
        Group {
            if blueutilMissing {
                missingBlueutilView
            } else if showSetup || config == nil {
                SetupView(
                    existing: config,
                    onSave: { newConfig in
                        try? DeviceConfigStore.save(newConfig)
                        config = newConfig
                        showSetup = false
                    },
                    onCancel: config == nil ? nil : { showSetup = false }
                )
            } else if let config {
                mainView(config: config)
            }
        }
    }

    private var missingBlueutilView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bluetooth helper missing").font(.subheadline).bold()
            Text("PeriHop's built-in Bluetooth helper couldn't be found. Try reinstalling the app — if that doesn't fix it, and you're running from source (swift run), install it with:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("brew install blueutil")
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
            Button("Check Again") {
                blueutilMissing = BluetoothController.blueutilPath == nil
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private func mainView(config: DeviceConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "keyboard")
                Text("PeriHop").font(.headline)
                Spacer()
            }

            ForEach(config.devices, id: \.address) { device in
                deviceRow(name: device.name, status: switchFlow.status(for: device.address), address: device.address)
            }

            switch switchFlow.stage {
            case .idle, .finished:
                Button("Switch Devices") {
                    switchFlow.start(config: config)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            case .unpairing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Unpairing…").font(.caption)
                }

            case .awaitingPairingMode:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Slide each device's switch to OFF, then back to ON, then continue.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Cancel") { switchFlow.reset() }
                        Spacer()
                        Button("Continue") { switchFlow.userConfirmedPairingMode() }
                            .buttonStyle(.borderedProminent)
                    }
                }

            case .connecting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(.caption)
                }
            }

            Divider()
            HStack {
                Button("Edit Devices…") { showSetup = true }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 320)
        .task(id: config) {
            // Re-checks real Bluetooth connection state every 10 seconds
            // while the popover is open, so the checkmark reflects reality
            // even if a device disconnects mid-session. refreshStatuses
            // no-ops while a switch is in progress, so this can't race it.
            // Cancels automatically when the popover closes.
            while !Task.isCancelled {
                switchFlow.refreshStatuses(config: config)
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func deviceRow(name: String, status: DeviceStatus, address: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.subheadline)
                Spacer()
                switch status {
                case .pending:
                    EmptyView()
                case .working:
                    ProgressView().controlSize(.small)
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure:
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Button("Retry") { switchFlow.retry(address) }
                            .font(.caption2)
                    }
                }
            }
            if case .failure(let message) = status {
                ErrorBox(message: message)
            }
        }
    }
}

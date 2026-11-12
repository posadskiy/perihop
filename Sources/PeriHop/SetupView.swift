import SwiftUI

struct SetupView: View {
    /// Nil on first run, when there is nothing to go back to.
    var onDone: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @State private var found: [BTDevice] = []
    @State private var selected: Set<DeviceAddress> = []
    @State private var isScanning = false
    @State private var note: String?
    @State private var errorMessage: String?
    @AppStorage("showDeviceAddresses") private var showDeviceAddresses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Devices to Switch", onBack: onDone)

            Text("Choose the keyboard, trackpad, or mouse this Mac shares with your other Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if found.isEmpty {
                Text("No Bluetooth devices yet. Connect one to this Mac, or scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(found) { device in
                        row(device)
                    }
                }
            }

            if let errorMessage {
                ErrorBox(message: errorMessage)
            } else if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    scan()
                } label: {
                    if isScanning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        Label("Scan Nearby", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .disabled(isScanning)
                .help("Finds devices that are on and not connected to any Mac")
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(MenuLayout.padding)
        .onAppear(perform: load)
    }

    private func row(_ device: BTDevice) -> some View {
        let isSelected = selected.contains(device.address)
        return Button {
            if isSelected {
                selected.remove(device.address)
            } else {
                selected.insert(device.address)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Image(systemName: DeviceKind(name: device.name).symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.callout).lineLimit(1)
                    if showDeviceAddresses {
                        Text(device.address.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Saved devices, what is paired here, and what the other Mac switches,
    /// so a device only has to be chosen on one Mac to show up on both.
    private func load() {
        selected = Set(model.devices.map(\.address))
        merge(model.devices.map { BTDevice(address: $0.address, name: $0.name) })
        merge(model.handoff.peerDevices.map { BTDevice(address: $0.address, name: $0.name) })
        Task {
            merge(await LiveBluetoothController().pairedDevices().filter(\.isInput))
        }
    }

    private func scan() {
        errorMessage = nil
        note = nil
        isScanning = true
        Task {
            let devices = await LiveBluetoothController().inquire(timeout: 8)
            isScanning = false
            merge(devices.filter(\.isInput))
            if devices.isEmpty {
                note = "Nothing new nearby. A device connected to another Mac does not show up. Turn it off and on, then scan again."
            }
        }
    }

    private func merge(_ devices: [BTDevice]) {
        var byAddress = Dictionary(found.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        for device in devices {
            // A scan reports the address as the name until the name is read.
            if let known = byAddress[device.address], device.name == device.address.rawValue {
                byAddress[device.address] = known
            } else {
                byAddress[device.address] = device
            }
        }
        found = byAddress.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func save() {
        let devices = found
            .filter { selected.contains($0.address) }
            .map { DeviceEntry(name: $0.name, address: $0.address) }
        do {
            try model.saveDevices(devices)
            errorMessage = nil
            onDone?()
        } catch {
            AppLog.config.error("Failed to save config: \(error.localizedDescription)")
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

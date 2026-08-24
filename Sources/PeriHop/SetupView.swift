import SwiftUI

struct SetupView: View {
    var existing: DeviceConfig?
    var onSave: (DeviceConfig) -> Void
    var onCancel: (() -> Void)?

    @State private var isLoadingPaired = false
    @State private var isScanning = false
    @State private var discovered: [BTDevice] = []
    @State private var selectedAddresses: Set<String> = []
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @AppStorage("showDeviceAddresses") private var showDeviceAddresses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Devices").font(.headline)
            Text("Select the keyboard, trackpad, mouse — any Bluetooth devices you want to switch between Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorMessage {
                ErrorBox(message: errorMessage)
            } else if let infoMessage {
                Text(infoMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isLoadingPaired {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading connected devices…").font(.caption)
                }
            }

            if !discovered.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(discovered) { device in
                        deviceRow(device)
                    }
                }
            } else if !isLoadingPaired {
                Text("No devices found yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Device not listed? Slide its switch to OFF, then back to ON, then scan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(isScanning ? "Scanning…" : "Scan for New Devices") {
                    scan()
                }
                .disabled(isScanning)
            }

            Divider()
            HStack {
                if let onCancel {
                    Button("Cancel", action: onCancel)
                }
                Spacer()
                Button("Save") { save() }
                    .disabled(!canSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            if let existing {
                discovered = existing.devices.map { BTDevice(address: $0.address, name: $0.name) }
                selectedAddresses = Set(existing.devices.map(\.address))
            }
            loadPaired()
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: BTDevice) -> some View {
        let isSelected = selectedAddresses.contains(device.address)
        Button {
            toggle(device.address)
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.subheadline)
                    if showDeviceAddresses {
                        Text(device.address).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var canSave: Bool {
        !selectedAddresses.isEmpty
    }

    private func toggle(_ address: String) {
        if selectedAddresses.contains(address) {
            selectedAddresses.remove(address)
        } else {
            selectedAddresses.insert(address)
        }
    }

    private func loadPaired() {
        errorMessage = nil
        infoMessage = nil
        isLoadingPaired = true
        Task {
            let result: Result<[BTDevice], Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try BluetoothController.paired())
                } catch {
                    return .failure(error)
                }
            }.value

            isLoadingPaired = false
            switch result {
            case .success(let devices):
                mergeDiscovered(devices)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scan() {
        errorMessage = nil
        infoMessage = nil
        isScanning = true
        Task {
            let result: Result<[BTDevice], Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try BluetoothController.inquiry(duration: 8))
                } catch {
                    return .failure(error)
                }
            }.value

            isScanning = false
            switch result {
            case .success(let devices):
                mergeDiscovered(devices)
                if devices.isEmpty {
                    infoMessage = "No new devices found. Make sure the device is in pairing mode and try again."
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func mergeDiscovered(_ devices: [BTDevice]) {
        var byAddress = Dictionary(uniqueKeysWithValues: discovered.map { ($0.address, $0) })
        for device in devices {
            byAddress[device.address] = device
        }
        discovered = byAddress.values.sorted { $0.name < $1.name }
    }

    private func save() {
        let devices = discovered
            .filter { selectedAddresses.contains($0.address) }
            .map { DeviceEntry(name: $0.name, address: $0.address) }
        onSave(DeviceConfig(devices: devices))
    }
}

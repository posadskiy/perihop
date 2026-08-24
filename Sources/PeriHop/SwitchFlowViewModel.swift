import Foundation

enum DeviceStatus: Equatable {
    case pending
    case working
    case success
    case failure(String)
}

@MainActor
final class SwitchFlowViewModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case unpairing
        case awaitingPairingMode
        case connecting
        case finished
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var statuses: [String: DeviceStatus] = [:]

    private var config: DeviceConfig?

    func status(for address: String) -> DeviceStatus {
        statuses[address] ?? .pending
    }

    /// Checks actual current Bluetooth connection state for each device —
    /// used to show a checkmark for devices already connected, without the
    /// user needing to run a switch first. Skipped while a switch is in
    /// progress so it can't race that flow's own status updates.
    func refreshStatuses(config: DeviceConfig) {
        self.config = config
        guard stage == .idle || stage == .finished else { return }
        let addresses = config.devices.map(\.address)

        Task {
            let results: [(String, Bool)] = await Task.detached(priority: .userInitiated) {
                addresses.map { ($0, BluetoothController.isConnected($0)) }
            }.value
            guard stage == .idle || stage == .finished else { return }
            for (address, connected) in results {
                statuses[address] = connected ? .success : .pending
            }
        }
    }

    func start(config: DeviceConfig) {
        self.config = config
        statuses = Dictionary(uniqueKeysWithValues: config.devices.map { ($0.address, DeviceStatus.pending) })
        stage = .unpairing

        let addresses = config.devices.map(\.address)

        Task {
            await Task.detached(priority: .userInitiated) {
                for address in addresses {
                    BluetoothController.unpair(address)
                }
            }.value
            stage = .awaitingPairingMode
        }
    }

    func userConfirmedPairingMode() {
        guard let config else { return }
        stage = .connecting
        for entry in config.devices {
            Task { await connect(entry: entry) }
        }
    }

    func retry(_ address: String) {
        guard let entry = config?.devices.first(where: { $0.address == address }) else { return }
        Task { await connect(entry: entry) }
    }

    func reset() {
        stage = .idle
        statuses = [:]
    }

    private func connect(entry: DeviceEntry) async {
        statuses[entry.address] = .working
        let address = entry.address

        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try BluetoothController.pair(address)
                try BluetoothController.connect(address)
                guard BluetoothController.waitConnect(address, timeout: 30) else {
                    throw BlueUtilError.commandFailed("Timed out waiting for \(address) to connect")
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            statuses[entry.address] = .success
        case .failure(let error):
            statuses[entry.address] = .failure(error.localizedDescription)
        }
        checkFinished()
    }

    private func checkFinished() {
        let stillWorking = statuses.values.contains { $0 == .working || $0 == .pending }
        if !stillWorking {
            stage = .finished
        }
    }
}

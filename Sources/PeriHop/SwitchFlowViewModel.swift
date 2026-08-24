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
        /// Unpaired, waiting for devices to reconnect. Retries pairing
        /// automatically in the background — no manual "Continue" needed.
        case reconnecting
        case finished
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var statuses: [String: DeviceStatus] = [:]

    private var config: DeviceConfig?
    private var reconnectTasks: [String: Task<Void, Never>] = [:]

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
            beginReconnecting()
        }
    }

    /// Stops retrying. The devices were already unpaired on this Mac in the
    /// unpair step — that's not reversible from here, so this just stops
    /// automatic reconnect attempts rather than pretending to undo it.
    func stop() {
        cancelReconnectTasks()
        stage = .idle
    }

    func retry(_ address: String) {
        guard let entry = config?.devices.first(where: { $0.address == address }) else { return }
        reconnectTasks[address]?.cancel()
        stage = .reconnecting
        reconnectTasks[address] = Task { await self.reconnectLoop(entry: entry) }
    }

    private func beginReconnecting() {
        guard let config else { return }
        stage = .reconnecting
        for entry in config.devices {
            reconnectTasks[entry.address]?.cancel()
            reconnectTasks[entry.address] = Task { await self.reconnectLoop(entry: entry) }
        }
    }

    /// Retries pair + connect every few seconds so the user just has to slide
    /// the switches off/on — no click needed to tell the app they're ready.
    private func reconnectLoop(entry: DeviceEntry) async {
        let address = entry.address
        statuses[address] = .working
        let deadline = Date().addingTimeInterval(90)
        var lastMessage = "Timed out waiting to reconnect."

        while !Task.isCancelled {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try BluetoothController.pair(address)
                    try BluetoothController.connect(address)
                    guard BluetoothController.waitConnect(address, timeout: 5) else {
                        throw BlueUtilError.commandFailed("Not responding yet.")
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            if Task.isCancelled { return }

            switch result {
            case .success:
                statuses[address] = .success
                checkFinished()
                return
            case .failure(let error):
                lastMessage = error.localizedDescription
            }

            if Date() >= deadline {
                statuses[address] = .failure(lastMessage)
                checkFinished()
                return
            }

            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func cancelReconnectTasks() {
        for task in reconnectTasks.values {
            task.cancel()
        }
        reconnectTasks.removeAll()
    }

    private func checkFinished() {
        let stillWorking = statuses.values.contains { $0 == .working || $0 == .pending }
        if !stillWorking {
            stage = .finished
        }
    }
}

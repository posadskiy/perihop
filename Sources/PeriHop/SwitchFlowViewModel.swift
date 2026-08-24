import Foundation

enum DeviceStatus: Equatable {
    /// Never checked yet (e.g. popover just opened, first poll hasn't landed).
    case unknown
    /// Checked — confirmed not connected.
    case disconnected
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
    @Published private(set) var statuses: [DeviceAddress: DeviceStatus] = [:]

    private let bluetooth: BluetoothControlling
    /// Overridable so tests don't have to wait 90 real seconds to see a
    /// timeout — production always uses the defaults.
    private let reconnectTimeout: TimeInterval
    private let retryInterval: UInt64

    private var config: DeviceConfig?
    private var reconnectTasks: [DeviceAddress: Task<Void, Never>] = [:]
    /// Bumped every time a reconnect attempt (re)starts for an address. A
    /// running loop checks its captured generation is still current before
    /// writing status — if `retry()`/`stop()` started something newer while
    /// it was mid-flight, its result is silently discarded instead of
    /// clobbering the newer attempt. Task cancellation alone can't guarantee
    /// this: cancellation is cooperative, so an old task can still complete
    /// an in-flight `await` and write a stale result after being "cancelled".
    private var reconnectGeneration: [DeviceAddress: Int] = [:]
    private var refreshTask: Task<Void, Never>?

    init(
        bluetooth: BluetoothControlling = LiveBluetoothController(),
        reconnectTimeout: TimeInterval = 90,
        retryInterval: UInt64 = 3_000_000_000
    ) {
        self.bluetooth = bluetooth
        self.reconnectTimeout = reconnectTimeout
        self.retryInterval = retryInterval
    }

    func status(for address: DeviceAddress) -> DeviceStatus {
        statuses[address] ?? .unknown
    }

    /// Checks actual current Bluetooth connection state for each device —
    /// used to show a checkmark for devices already connected, without the
    /// user needing to run a switch first. Skipped while a switch is in
    /// progress so it can't race that flow's own status updates. Cancels any
    /// still-running previous refresh so overlapping polls can't stack up
    /// and resolve out of order.
    func refreshStatuses(config: DeviceConfig) {
        self.config = config
        guard stage == .idle || stage == .finished else { return }

        refreshTask?.cancel()
        let addresses = config.devices.map(\.address)

        refreshTask = Task {
            var results: [(DeviceAddress, Bool)] = []
            for address in addresses {
                if Task.isCancelled { return }
                results.append((address, await bluetooth.isConnected(address)))
            }
            guard !Task.isCancelled, stage == .idle || stage == .finished else { return }
            for (address, connected) in results {
                statuses[address] = connected ? .success : .disconnected
            }
        }
    }

    func start(config: DeviceConfig) {
        self.config = config
        statuses = Dictionary(uniqueKeysWithValues: config.devices.map { ($0.address, DeviceStatus.unknown) })
        stage = .unpairing
        AppLog.switchFlow.info("Switch started for \(config.devices.count) device(s)")

        let addresses = config.devices.map(\.address)

        Task {
            for address in addresses {
                await bluetooth.unpair(address)
            }
            beginReconnecting()
        }
    }

    /// Stops retrying. The devices were already unpaired on this Mac in the
    /// unpair step — that's not reversible from here, so this just stops
    /// automatic reconnect attempts rather than pretending to undo it.
    func stop() {
        AppLog.switchFlow.info("Switch stopped by user")
        for task in reconnectTasks.values {
            task.cancel()
        }
        reconnectTasks.removeAll()
        for address in reconnectGeneration.keys {
            reconnectGeneration[address, default: 0] += 1
        }
        stage = .idle
    }

    func retry(_ address: DeviceAddress) {
        guard let entry = config?.devices.first(where: { $0.address == address }) else { return }
        stage = .reconnecting
        startReconnectLoop(for: entry)
    }

    private func beginReconnecting() {
        guard let config else { return }
        stage = .reconnecting
        for entry in config.devices {
            startReconnectLoop(for: entry)
        }
    }

    private func startReconnectLoop(for entry: DeviceEntry) {
        let address = entry.address
        let generation = (reconnectGeneration[address] ?? 0) + 1
        reconnectGeneration[address] = generation
        reconnectTasks[address]?.cancel()
        reconnectTasks[address] = Task { await self.reconnectLoop(entry: entry, generation: generation) }
    }

    /// Retries pair + connect every few seconds so the user just has to slide
    /// the switches off/on — no click needed to tell the app they're ready.
    private func reconnectLoop(entry: DeviceEntry, generation: Int) async {
        let address = entry.address
        func isCurrent() -> Bool { reconnectGeneration[address] == generation }

        statuses[address] = .working
        let deadline = Date().addingTimeInterval(reconnectTimeout)
        var lastMessage = "Timed out waiting to reconnect."

        while !Task.isCancelled && isCurrent() {
            do {
                try await bluetooth.pair(address)
                try await bluetooth.connect(address)
                guard await bluetooth.waitConnect(address, timeout: 5) else {
                    throw BlueUtilError.commandFailed("Not responding yet.")
                }
                if isCurrent() {
                    AppLog.switchFlow.info("\(entry.name) reconnected")
                    statuses[address] = .success
                    checkFinished()
                }
                return
            } catch {
                lastMessage = error.localizedDescription
            }

            guard !Task.isCancelled, isCurrent() else { return }

            if Date() >= deadline {
                AppLog.switchFlow.error("\(entry.name) failed to reconnect: \(lastMessage)")
                statuses[address] = .failure(lastMessage)
                checkFinished()
                return
            }

            try? await Task.sleep(nanoseconds: retryInterval)
        }
    }

    private func checkFinished() {
        let stillWorking = statuses.values.contains { $0 == .working || $0 == .unknown }
        if !stillWorking {
            stage = .finished
        }
    }
}

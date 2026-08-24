import Testing
import Foundation
@testable import PeriHop

@MainActor
struct SwitchFlowViewModelTests {
    @Test func startUnpairsAllConfiguredDevices() async throws {
        let mock = MockBluetoothController()
        let viewModel = SwitchFlowViewModel(bluetooth: mock, reconnectTimeout: 1, retryInterval: 10_000_000)
        let config = DeviceConfig(devices: [
            DeviceEntry(name: "Keyboard", address: "aa-bb-cc-dd-ee-ff"),
            DeviceEntry(name: "Trackpad", address: "11-22-33-44-55-66"),
        ])

        viewModel.start(config: config)

        try await waitUntil { await mock.unpairedAddresses.count == 2 }
        let unpaired = await mock.unpairedAddresses
        #expect(Set(unpaired) == Set(config.devices.map(\.address)))
    }

    @Test func succeedsAfterTransientPairFailures() async throws {
        let address: DeviceAddress = "aa-bb-cc-dd-ee-ff"
        let mock = MockBluetoothController()
        await mock.setPairOutcomes([
            .failure(BlueUtilError.commandFailed("not ready")),
            .failure(BlueUtilError.commandFailed("not ready")),
            .success(()),
        ], for: address)

        let viewModel = SwitchFlowViewModel(bluetooth: mock, reconnectTimeout: 5, retryInterval: 10_000_000)
        let config = DeviceConfig(devices: [DeviceEntry(name: "Keyboard", address: address)])

        viewModel.start(config: config)

        try await waitUntil(timeout: 3) { viewModel.status(for: address) == .success }
        #expect(viewModel.stage == .finished)
    }

    @Test func failsAfterDeadlineExceeded() async throws {
        let address: DeviceAddress = "aa-bb-cc-dd-ee-ff"
        let mock = MockBluetoothController()
        await mock.setPairOutcomes([.failure(BlueUtilError.commandFailed("never ready"))], for: address)

        // Short deadline + short retry interval so this doesn't take 90s.
        let viewModel = SwitchFlowViewModel(bluetooth: mock, reconnectTimeout: 0.2, retryInterval: 10_000_000)
        let config = DeviceConfig(devices: [DeviceEntry(name: "Keyboard", address: address)])

        viewModel.start(config: config)

        try await waitUntil(timeout: 3) {
            if case .failure = viewModel.status(for: address) { return true }
            return false
        }
    }

    /// Regression test for the generation-token fix: a first attempt that's
    /// still in flight when `retry()` starts a fresh attempt must not clobber
    /// the newer attempt's result once it eventually resolves.
    @Test func retrySupersedesStaleAttempt() async throws {
        let address: DeviceAddress = "aa-bb-cc-dd-ee-ff"
        let mock = MockBluetoothController()
        await mock.setPairOutcomes([.failure(BlueUtilError.commandFailed("first attempt"))], for: address)

        let viewModel = SwitchFlowViewModel(bluetooth: mock, reconnectTimeout: 5, retryInterval: 50_000_000)
        let config = DeviceConfig(devices: [DeviceEntry(name: "Keyboard", address: address)])
        viewModel.start(config: config)

        try await waitUntil(timeout: 2) { viewModel.status(for: address) == .working }

        // Make the next pair attempt succeed, then retry immediately — this
        // starts a new generation while the old loop's failed first attempt
        // may still be settling.
        await mock.setPairOutcomes([.success(())], for: address)
        viewModel.retry(address)

        try await waitUntil(timeout: 2) { viewModel.status(for: address) == .success }
        #expect(viewModel.status(for: address) == .success)
    }

    @Test func stopHaltsRetrying() async throws {
        let address: DeviceAddress = "aa-bb-cc-dd-ee-ff"
        let mock = MockBluetoothController()
        await mock.setPairOutcomes([.failure(BlueUtilError.commandFailed("never ready"))], for: address)

        let viewModel = SwitchFlowViewModel(bluetooth: mock, reconnectTimeout: 5, retryInterval: 10_000_000)
        let config = DeviceConfig(devices: [DeviceEntry(name: "Keyboard", address: address)])
        viewModel.start(config: config)

        try await waitUntil(timeout: 2) { viewModel.status(for: address) == .working }

        viewModel.stop()

        #expect(viewModel.stage == .idle)
    }
}

/// Polls a condition until it's true or the timeout elapses — these tests
/// are driven by real (if short) async retry loops, not fixed delays.
@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    if await !condition() {
        Issue.record("Condition not met within \(timeout)s")
    }
}

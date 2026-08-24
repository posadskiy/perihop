import Foundation
@testable import PeriHop

/// Test double for `BluetoothControlling` — an actor so mutation from
/// concurrent `SwitchFlowViewModel` reconnect loops is provably safe, same
/// as it would be with real out-of-process calls.
actor MockBluetoothController: BluetoothControlling {
    private(set) var unpairedAddresses: [DeviceAddress] = []
    private(set) var pairAttempts: [DeviceAddress: Int] = [:]

    private var pairOutcomes: [DeviceAddress: [Result<Void, Error>]] = [:]
    private var connectShouldFail = false
    private var waitConnectResult = true

    func setPairOutcomes(_ outcomes: [Result<Void, Error>], for address: DeviceAddress) {
        pairOutcomes[address] = outcomes
    }

    func setConnectShouldFail(_ value: Bool) {
        connectShouldFail = value
    }

    func setWaitConnectResult(_ value: Bool) {
        waitConnectResult = value
    }

    func unpair(_ address: DeviceAddress) async {
        unpairedAddresses.append(address)
    }

    func pair(_ address: DeviceAddress) async throws {
        let attempt = pairAttempts[address] ?? 0
        pairAttempts[address] = attempt + 1
        guard let outcomes = pairOutcomes[address], !outcomes.isEmpty else { return }
        let index = min(attempt, outcomes.count - 1)
        if case .failure(let error) = outcomes[index] {
            throw error
        }
    }

    func connect(_ address: DeviceAddress) async throws {
        if connectShouldFail {
            throw BlueUtilError.commandFailed("mock connect failure")
        }
    }

    func waitConnect(_ address: DeviceAddress, timeout: Int) async -> Bool {
        waitConnectResult
    }

    func isConnected(_ address: DeviceAddress) async -> Bool {
        false
    }
}

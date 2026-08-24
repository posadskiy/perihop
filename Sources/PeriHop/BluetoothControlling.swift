import Foundation

/// The Bluetooth operations `SwitchFlowViewModel` depends on, as a protocol
/// instead of a hard dependency on the concrete `BluetoothController` — lets
/// tests substitute a mock instead of spawning a real `blueutil` process.
protocol BluetoothControlling: Sendable {
    func unpair(_ address: DeviceAddress) async
    func pair(_ address: DeviceAddress) async throws
    func connect(_ address: DeviceAddress) async throws
    func waitConnect(_ address: DeviceAddress, timeout: Int) async -> Bool
    func isConnected(_ address: DeviceAddress) async -> Bool
}

/// Thin adapter over the real `BluetoothController` — production code paths
/// (`SwitchFlowViewModel`'s default) go through this unchanged.
struct LiveBluetoothController: BluetoothControlling {
    func unpair(_ address: DeviceAddress) async {
        await BluetoothController.unpair(address)
    }

    func pair(_ address: DeviceAddress) async throws {
        try await BluetoothController.pair(address)
    }

    func connect(_ address: DeviceAddress) async throws {
        try await BluetoothController.connect(address)
    }

    func waitConnect(_ address: DeviceAddress, timeout: Int) async -> Bool {
        await BluetoothController.waitConnect(address, timeout: timeout)
    }

    func isConnected(_ address: DeviceAddress) async -> Bool {
        await BluetoothController.isConnected(address)
    }
}

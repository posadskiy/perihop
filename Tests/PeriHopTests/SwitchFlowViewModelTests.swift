import Testing
import Foundation
@testable import PeriHop

@MainActor
struct HandoffCoordinatorTests {
    private let keyboard = DeviceEntry(name: "Magic Keyboard", address: "aa-bb-cc-dd-ee-ff")
    private let trackpad = DeviceEntry(name: "Magic Trackpad", address: "11-22-33-44-55-66")

    @Test func useHereConnectsExistingBondWithoutForgetting() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.setConnectResults([true], for: keyboard.address)
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { coordinator.activity == .finished }

        let releases = await peer.releases
        #expect(releases.count == 1)
        #expect(releases.first?.0 == keyboard.address)
        #expect(releases.first?.1 == false)
        #expect(await bluetooth.forgotten.isEmpty)
        #expect(await bluetooth.pairs.isEmpty)
        #expect(await peer.owned == [keyboard.address])
        #expect(coordinator.status(for: keyboard.address) == .success)
    }

    @Test func useHereRepairsWhenConnectIsRefused() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.setConnectResults([false, false, true], for: keyboard.address)
        await bluetooth.setDiscoverResults([true], for: keyboard.address)
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)
        var saved: [DeviceEntry] = []
        coordinator.onDevicesChanged = { saved = $0 }

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { coordinator.activity == .finished }

        #expect(await peer.failed == [keyboard.address])
        #expect(await bluetooth.pairs == [keyboard.address])
        #expect(saved.first?.bondMode == .single)
        #expect(coordinator.status(for: keyboard.address) == .success)
    }

    @Test func sleepingPeerIsTakenDirectly() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.setConnectResults([true], for: keyboard.address)
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { coordinator.activity == .finished }

        #expect(await peer.releases.isEmpty)
        #expect(await bluetooth.connects == [keyboard.address])
        #expect(coordinator.status(for: keyboard.address) == .success)
        #expect(coordinator.peerReachable == false)
    }

    @Test func failureRollsBackAfterAPowerCycleWindow() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.setConnectResults([false], for: keyboard.address)
        await bluetooth.setDiscoverResults([false, false], for: keyboard.address)
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { coordinator.activity == .finished }

        #expect(await bluetooth.discoveries.count == 1)
        #expect(await peer.failed.isEmpty)
        #expect(await bluetooth.pairs.isEmpty)
        #expect(await peer.rollbacks == [keyboard.address])
        #expect(coordinator.status(for: keyboard.address) != .success)
    }

    @Test func handOffForgetsSingleBondAndKeepsMultiBond() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        var multi = trackpad
        multi.bondMode = .multi
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)

        coordinator.handOff(devices: [keyboard, multi])
        try await waitUntil { coordinator.activity == .finished }

        let forgotten = await bluetooth.forgotten
        #expect(forgotten == [keyboard.address])
        let suppressions = await bluetooth.suppressions
        #expect(suppressions.contains(trackpad.address))
        #expect(await bluetooth.disconnects.first == trackpad.address)
    }

    @Test func remoteReleaseCanForget() async {
        let bluetooth = MockBluetoothController()
        let coordinator = coordinator(bluetooth: bluetooth, peer: MockPeer())

        await coordinator.handleRemoteRelease(keyboard.address, forget: true)

        #expect(await bluetooth.disconnects == [keyboard.address])
        #expect(await bluetooth.forgotten == [keyboard.address])
        #expect(await bluetooth.suppressions == [keyboard.address])
    }

    @Test func wakeYieldsToTheNewerClaim() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.setConnected([keyboard.address])
        var owned = keyboard
        owned.holder = .thisMac
        owned.holderSince = Date(timeIntervalSince1970: 10)
        await peer.setRemoteClaims([
            ClaimStamp(address: keyboard.address.rawValue, holderSince: Date(timeIntervalSince1970: 20), mine: true),
        ])
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)
        coordinator.useDevices([owned])

        await coordinator.handleDidWake()

        #expect(await bluetooth.disconnects == [keyboard.address])
        #expect(await bluetooth.connects.isEmpty)
    }

    @Test func willSleepDisconnectsConnectedDevices() async {
        let bluetooth = MockBluetoothController()
        await bluetooth.setConnected([keyboard.address])
        let coordinator = coordinator(bluetooth: bluetooth, peer: MockPeer())
        coordinator.useDevices([keyboard])

        await coordinator.handleWillSleep()

        #expect(await bluetooth.disconnects == [keyboard.address])
    }

    @Test func useHereIsANoOpWhenTheDeviceIsAlreadyHere() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.setConnected([keyboard.address])
        var owned = keyboard
        owned.holder = .thisMac
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)

        coordinator.useHere(devices: [owned])
        try await waitUntil { coordinator.activity == .finished }

        #expect(await bluetooth.connects.isEmpty)
        #expect(coordinator.summary == "Already on this Mac.")
    }

    @Test func willSleepHandsOffWhenTheOtherMacAnswers() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.setConnected([keyboard.address])
        let coordinator = coordinator(bluetooth: bluetooth, peer: peer)
        var saved: [DeviceEntry] = []
        coordinator.onDevicesChanged = { saved = $0 }
        coordinator.useDevices([keyboard])

        await coordinator.handleWillSleep()

        #expect(await bluetooth.disconnects == [keyboard.address])
        #expect(await peer.sleeping == [keyboard.address])
        #expect(saved.first?.holder == .otherMac)
    }

    private func coordinator(bluetooth: MockBluetoothController, peer: MockPeer) -> HandoffCoordinator {
        HandoffCoordinator(
            bluetooth: bluetooth,
            peer: peer,
            timings: HandoffTimings(
                peerPing: 0.01,
                connect: 0.01,
                discoverFirst: 0.01,
                discoverSecond: 0.01,
                releaseTimeout: 0.01,
                claimTimeout: 0.01,
                suppressSafety: 0.01,
                sleepDisconnect: 0.01,
                wakeWatch: 0,
                rangeProbe: 0.01
            )
        )
    }
}

extension MockBluetoothController {
    func setConnectResults(_ results: [Bool], for address: DeviceAddress) {
        connectResults[address] = results
    }

    func setDiscoverResults(_ results: [Bool], for address: DeviceAddress) {
        discoverResults[address] = results
    }

    func setConnected(_ addresses: Set<DeviceAddress>) {
        connected = addresses
    }
}

extension MockPeer {
    func setReachable(_ value: Bool) { reachable = value }
    func setRemoteClaims(_ claims: [ClaimStamp]) { remoteClaims = claims }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    if !condition() {
        Issue.record("Condition not met within \(timeout)s")
    }
}

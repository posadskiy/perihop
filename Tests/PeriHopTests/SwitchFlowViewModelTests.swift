import Foundation
import Testing
@testable import PeriHop

@MainActor
struct HandoffCoordinatorTests {
    private let keyboard = DeviceEntry(name: "Magic Keyboard", address: "aa-bb-cc-dd-ee-ff")
    private let trackpad = DeviceEntry(name: "Magic Trackpad", address: "11-22-33-44-55-66")

    private var timings: HandoffTimings {
        HandoffTimings(
            peerPing: 0.2,
            connect: 0.05,
            pair: 0.05,
            firstPair: 0.05,
            peerDial: 0.3,
            releaseRequest: 0.5,
            release: 0.2,
            settle: 0.05,
            retryPause: 0.02,
            userWindow: 1,
            pushedWindow: 0.4,
            reclaimWindow: 1,
            eagerWindow: 0.5,
            slowPause: 0.05,
            slowPair: 0.05,
            adoptWindow: 0.6,
            adoptAttempts: 3,
            outcomeWait: 0.4,
            releaseGrace: 60,
            wakeDelay: 0.01,
            sleepBudget: 1
        )
    }

    private func make(
        _ bluetooth: MockBluetoothController,
        _ peer: MockPeer,
        devices: [DeviceEntry]? = nil
    ) async throws -> HandoffCoordinator {
        let coordinator = HandoffCoordinator(bluetooth: bluetooth, peer: peer, timings: timings)
        coordinator.useDevices(devices ?? [keyboard, trackpad])
        coordinator.start()
        try await waitUntil { coordinator.checked }
        // The event stream is subscribed in a task of its own.
        try await Task.sleep(nanoseconds: 20_000_000)
        return coordinator
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out waiting")
        throw CancellationError()
    }

    // MARK: Use here

    @Test func useHereTakesADeviceTheOtherMacHolds() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.share(bluetooth)
        await peer.setHeld([keyboard.address])
        // A pairing left over from the last time it was here.
        await bluetooth.set(paired: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        #expect(coordinator.state(for: keyboard.address) == .onOtherMac)

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        #expect(await peer.releaseRequests == [[keyboard.address]])
        // The leftover pairing is known to be stale. It is replaced
        // without first being tried against the device.
        #expect(await bluetooth.calls == ["release \(keyboard.address.rawValue)", "pair \(keyboard.address.rawValue)"])
        #expect(coordinator.state(for: keyboard.address) == .here)
        #expect(coordinator.summary == "Connected Magic Keyboard.")
    }

    @Test func aMacWithNoOpenConnectionIsAskedWhileThisOneAlreadyTries() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.share(bluetooth)
        await peer.setHeld([keyboard.address])
        await peer.setSlowToAnswer(true)
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { coordinator.state(for: keyboard.address) == .here }

        // The first try came before the other Mac had let go.
        #expect(await peer.releaseRequests == [[keyboard.address]])
        #expect(await bluetooth.count("pair \(keyboard.address.rawValue)") >= 2)
    }

    @Test func useHereMovesThePointerBeforeTheKeyboard() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.share(bluetooth)
        await peer.setHeld([keyboard.address, trackpad.address])
        let coordinator = try await make(bluetooth, peer)

        coordinator.useHere(devices: [keyboard, trackpad])
        try await waitUntil { !coordinator.isSwitching }

        #expect(await bluetooth.calls == ["pair \(trackpad.address.rawValue)", "pair \(keyboard.address.rawValue)"])
        #expect(coordinator.connected == [keyboard.address, trackpad.address])
    }

    @Test func useHereIsANoOpWhenAlreadyHere() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        #expect(await peer.releaseRequests.isEmpty)
        #expect(await bluetooth.calls.isEmpty)
        #expect(coordinator.summary == "Already on this Mac.")
    }

    @Test func aPairingTheDeviceRejectsIsReplaced() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(paired: [keyboard.address], listening: [keyboard.address])
        await bluetooth.setStale([keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        let address = keyboard.address.rawValue
        #expect(await bluetooth.calls == ["connect \(address)", "release \(address)", "pair \(address)"])
        #expect(coordinator.state(for: keyboard.address) == .here)
    }

    @Test func aPairingIsKeptWhileTheDeviceDoesNotAnswer() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(paired: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        // Off or asleep. Nothing is unpaired, and this Mac keeps trying.
        #expect(await bluetooth.count("release \(keyboard.address.rawValue)") == 0)
        #expect(await bluetooth.paired == [keyboard.address])
        #expect(coordinator.state(for: keyboard.address) == .waiting)
        #expect(coordinator.hint == "Press a key or click on Magic Keyboard to wake it.")

        // The user presses a key.
        await bluetooth.wake(keyboard.address)
        try await waitUntil { coordinator.state(for: keyboard.address) == .here }
        #expect(coordinator.hint == nil)
        #expect(coordinator.summary == "Connected Magic Keyboard.")
    }

    @Test func aDeviceThatNeverAnswersGoesBackToTheOtherMac() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setHeld([keyboard.address])
        // The other Mac lets go, and the device never shows up here.
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        var results: [HandoffResult] = []
        coordinator.onFinished = { results.append($0) }

        coordinator.useHere(devices: [keyboard])
        try await waitUntil {
            if case .failed = coordinator.state(for: keyboard.address) { return true }
            return false
        }

        #expect(coordinator.state(for: keyboard.address)
            == .failed("Magic Keyboard didn't answer. Turn it off and on, then try again."))
        try await waitUntil { await peer.takeRequests == [[keyboard]] }
        #expect(results.last?.succeeded == false)
    }

    @Test func aDeviceTheOtherMacCannotFreeIsLeftAlone() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setHeld([keyboard.address])
        await peer.setGrantsRelease(false)
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        #expect(await bluetooth.calls.isEmpty)
        #expect(coordinator.state(for: keyboard.address) == .failed("The other Mac couldn't let go of Magic Keyboard."))
    }

    @Test func switchingWaitsForTrust() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        coordinator.switchingAllowed = { false }

        coordinator.useHere(devices: [keyboard])

        #expect(!coordinator.isSwitching)
        #expect(coordinator.summary == coordinator.switchingBlockedMessage)
        #expect(await bluetooth.calls.isEmpty)
    }

    @Test func bluetoothOffIsReported() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.setPowered(false)
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        #expect(coordinator.summary == "Bluetooth is off on this Mac.")
    }

    // MARK: Hand off

    @Test func handOffFreesTheDeviceAndTheOtherMacTakesIt() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        await peer.onTake { devices in
            for device in devices {
                await coordinator.handleOutcome(device.address, connected: true)
            }
        }

        coordinator.handOff(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        #expect(await bluetooth.calls == ["release \(keyboard.address.rawValue)"])
        #expect(await peer.takeRequests == [[keyboard]])
        #expect(coordinator.state(for: keyboard.address) == .onOtherMac)
        #expect(coordinator.summary == "Sent Magic Keyboard to the other Mac.")
        // Letting go on purpose is not a drop, so nothing reaches for it.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await bluetooth.count("pair \(keyboard.address.rawValue)") == 0)
    }

    @Test func aDeviceTheOtherMacDoesNotTakeComesBack() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        await peer.onTake { devices in
            for device in devices {
                await coordinator.handleOutcome(device.address, connected: false)
            }
        }

        coordinator.handOff(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        #expect(coordinator.state(for: keyboard.address) == .here)
        #expect(coordinator.summary == "The other Mac didn't take Magic Keyboard. It stays on this Mac.")
        #expect(await bluetooth.connected == [keyboard.address])
    }

    @Test func handOffToASleepingMacLeavesTheDeviceFree() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.handOff(devices: [keyboard])
        try await waitUntil { !coordinator.isSwitching }

        #expect(await peer.takeRequests.isEmpty)
        #expect(await bluetooth.paired.isEmpty)
        #expect(coordinator.summary == "Released Magic Keyboard. The other Mac is asleep and can take over when it wakes.")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(coordinator.state(for: keyboard.address) == .away)
    }

    @Test func toggleSendsWhatIsHereAndTakesOtherwise() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(connected: [keyboard.address], listening: [trackpad.address])
        let coordinator = try await make(bluetooth, peer)

        coordinator.toggle(devices: [keyboard, trackpad])
        try await waitUntil { !coordinator.isSwitching }
        #expect(await bluetooth.calls == ["release \(keyboard.address.rawValue)"])

        coordinator.toggle(devices: [trackpad])
        try await waitUntil { !coordinator.isSwitching }
        #expect(coordinator.state(for: trackpad.address) == .here)
    }

    // MARK: Requests from the other Mac

    @Test func aReleaseForTheOtherMacIsNotFollowedByAReconnect() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        let freed = await coordinator.handleRelease([keyboard.address])

        #expect(freed == [keyboard.address])
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(await bluetooth.calls == ["release \(keyboard.address.rawValue)"])
        #expect(coordinator.state(for: keyboard.address) != .waiting)
    }

    @Test func aLinkThatWillNotDropIsReportedAsNotFreed() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        await bluetooth.setStuck([keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        let freed = await coordinator.handleRelease([keyboard.address])

        #expect(freed.isEmpty)
        #expect(coordinator.state(for: keyboard.address) == .here)
    }

    @Test func aDeviceSentHereIsPairedAndReportedBack() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(listening: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [])
        var saved: [DeviceEntry] = []
        coordinator.onDevicesChanged = { saved = $0 }

        coordinator.handleTake([keyboard])
        try await waitUntil { await peer.outcomes[keyboard.address] == true }

        // A device this Mac had never seen is added to its list.
        #expect(saved == [keyboard])
        #expect(coordinator.state(for: keyboard.address) == .here)
    }

    @Test func aDeviceSentHereThatNeverAnswersIsReportedBack() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.handleTake([keyboard])
        try await waitUntil { await peer.outcomes[keyboard.address] == false }

        #expect(coordinator.state(for: keyboard.address) != .here)
    }

    // MARK: Sleep and wake

    @Test func sleepFreesTheDevicesAndOffersThemToTheOtherMac() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address, trackpad.address])
        let coordinator = try await make(bluetooth, peer)

        await coordinator.prepareForSleep()

        #expect(await bluetooth.paired.isEmpty)
        #expect(await peer.takeRequests.first?.count == 2)
    }

    @Test func aDockedMacKeepsItsKeyboardWhenNobodyCanTakeIt() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        coordinator.wakesFromDevices = { true }

        await coordinator.prepareForSleep()
        #expect(await bluetooth.calls.isEmpty)

        // With the other Mac there to take it, it is handed over as usual.
        await coordinator.didWake()
        await peer.setReachable(true)
        await coordinator.prepareForSleep()
        #expect(await bluetooth.calls == ["release \(keyboard.address.rawValue)"])
        #expect(await peer.takeRequests == [[keyboard]])
    }

    @Test func sleepWithNoOtherMacLinkedKeepsThePairing() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.set(linked: false)
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        await coordinator.prepareForSleep()

        #expect(await bluetooth.calls.isEmpty)
        #expect(await bluetooth.paired == [keyboard.address])
    }

    @Test func sleepKeepsThePairingWhenTheSettingIsOff() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        coordinator.releaseOnSleep = { false }

        await coordinator.prepareForSleep()

        #expect(await bluetooth.calls.isEmpty)
    }

    @Test func wakeTakesBackWhatWasFreedForSleep() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        await coordinator.prepareForSleep()
        #expect(await bluetooth.connected.isEmpty)
        await coordinator.didWake()
        try await waitUntil { coordinator.state(for: keyboard.address) == .here }

        #expect(await bluetooth.count("pair \(keyboard.address.rawValue)") == 1)
    }

    @Test func wakeLeavesADeviceTheOtherMacTookWhileThisOneSlept() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        await coordinator.prepareForSleep()
        await peer.setHeld([keyboard.address])
        await coordinator.didWake()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await bluetooth.count("pair \(keyboard.address.rawValue)") == 0)
        #expect(coordinator.state(for: keyboard.address) == .onOtherMac)
    }

    @Test func wakeAdoptsAFreeDeviceOnlyAfterTheOtherMacStaysSilent() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(listening: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        await coordinator.prepareForSleep()
        await coordinator.didWake()
        try await waitUntil { coordinator.state(for: keyboard.address) == .here }

        #expect(await bluetooth.count("pair \(keyboard.address.rawValue)") == 1)
    }

    @Test func wakeDoesNotAdoptWhenTheSettingIsOff() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(listening: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        coordinator.takeOnWake = { false }

        await coordinator.prepareForSleep()
        await coordinator.didWake()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await bluetooth.calls.isEmpty)
    }

    @Test func aDarkWakeTouchesNothing() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        await bluetooth.set(listening: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        coordinator.userIsPresent = { false }

        await coordinator.prepareForSleep()
        await coordinator.didWake()
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(await bluetooth.calls.isEmpty)
    }

    @Test func adoptionGivesUpAfterAFewAttempts() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        await coordinator.prepareForSleep()
        await coordinator.didWake()
        try await waitUntil { coordinator.state(for: keyboard.address) == .away }

        #expect(await bluetooth.count("pair \(keyboard.address.rawValue)") == 3)
    }

    // MARK: Drops

    @Test func aDeviceThatDropsIsReconnectedWhenItComesBack() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        await bluetooth.drop(keyboard.address)
        try await waitUntil { coordinator.state(for: keyboard.address) == .waiting }
        await bluetooth.wake(keyboard.address)
        try await waitUntil { coordinator.state(for: keyboard.address) == .here }

        // The pairing was still good, so it was opened, not replaced.
        #expect(await bluetooth.count("pair \(keyboard.address.rawValue)") == 0)
        #expect(await bluetooth.count("release \(keyboard.address.rawValue)") == 0)
    }

    @Test func aDroppedDeviceTheOtherMacNowHasIsLeftThere() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        await peer.setHeld([keyboard.address])
        await bluetooth.drop(keyboard.address)
        try await waitUntil { coordinator.state(for: keyboard.address) == .onOtherMac }

        #expect(await bluetooth.count("connect \(keyboard.address.rawValue)") == 0)
    }

    @Test func droppedDevicesAreLeftAloneWhenTheSettingIsOff() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(connected: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])
        coordinator.reconnectDropped = { false }

        await bluetooth.drop(keyboard.address)
        try await waitUntil { coordinator.state(for: keyboard.address) == .away }
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await bluetooth.calls.isEmpty)
    }

    @Test func stopEndsTheWaiting() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await peer.setReachable(false)
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { coordinator.state(for: keyboard.address) == .waiting }
        coordinator.stop()

        #expect(coordinator.state(for: keyboard.address) == .away)
        #expect(coordinator.hint == nil)
        #expect(coordinator.summary == "Stopped.")
        try await waitUntil { await bluetooth.cancelled }
    }

    @Test func theOtherMacIsToldWhatThisOneHolds() async throws {
        let bluetooth = MockBluetoothController()
        let peer = MockPeer()
        await bluetooth.set(listening: [keyboard.address])
        let coordinator = try await make(bluetooth, peer, devices: [keyboard])

        coordinator.useHere(devices: [keyboard])
        try await waitUntil { await peer.statuses.last?.held == [keyboard.address] }
    }
}

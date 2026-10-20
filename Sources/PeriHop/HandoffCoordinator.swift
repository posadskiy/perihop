import Foundation

struct ClaimStamp: Codable, Sendable, Equatable {
    var address: String
    var holderSince: Date
    /// True when this Mac believes it currently holds the accessory.
    var mine: Bool
}

enum HandoffClaims {
    /// A newer claim from the other Mac wins. That is how a switch made
    /// while this Mac was asleep sticks after it wakes up.
    static func apply(local: [DeviceEntry], remote: [ClaimStamp]) -> [DeviceEntry] {
        local.map { entry in
            guard let stamp = remote.first(where: { DeviceAddress($0.address) == entry.address }),
                  stamp.mine
            else { return entry }
            let localDate = entry.holderSince ?? .distantPast
            guard stamp.holderSince > localDate else { return entry }
            var updated = entry
            updated.holder = .otherMac
            updated.holderSince = stamp.holderSince
            return updated
        }
    }
}

enum HandoffPrompt: Equatable, Sendable {
    case none
    case peerAsleep
    case pressKey(String)
    /// The other Mac is closed or asleep, so the accessory is still bonded to it.
    case powerCycle(String)
}

enum HandoffActivity: Equatable, Sendable {
    case idle
    case working
    case finished
}

struct HandoffResult: Equatable, Sendable {
    var devices: [DeviceEntry]
    var summary: String
    var succeeded: Bool
}

protocol PeerLinking: Sendable {
    func ping(timeout: TimeInterval) async -> Bool
    func requestRelease(_ address: DeviceAddress, forget: Bool, timeout: TimeInterval) async throws
    func notifyOwned(_ address: DeviceAddress) async
    func notifyFailed(_ address: DeviceAddress) async
    func requestRollback(_ address: DeviceAddress, timeout: TimeInterval) async
    func notifySleeping(_ addresses: [DeviceAddress]) async
    func exchangeClaims(_ local: [ClaimStamp], timeout: TimeInterval) async -> [ClaimStamp]
}

private enum HandoffStepState: Equatable {
    case idle
    case working
    /// The accessory is being released and must not be paged back.
    case releasing
    case connectedOnExistingBond
    case waitingForKeyPress
    case pairedLocally
    case failedKeepingOtherMacKey(String)
    case failed(String)
    case cancelled
}

@MainActor
private struct TakeAccessoryStep {
    let bluetooth: BluetoothControlling
    let peer: PeerLinking
    let timings: HandoffTimings

    func run(
        _ entry: DeviceEntry,
        peerUp: Bool,
        isCurrent: () -> Bool,
        transition: (HandoffStepState) -> Void
    ) async -> HandoffStepState {
        transition(.working)
        AppLog.switchFlow.info("take \(label(entry)) peerUp=\(peerUp)")
        await bluetooth.stopSuppressing(entry.address)

        // The accessory only shows up while it is awake, so ask for input
        // right away instead of after the release round trip.
        if !(await bluetooth.isPaired(entry.address)) {
            transition(.waitingForKeyPress)
        }

        if peerUp {
            transition(.releasing)
            guard await requestRelease(entry.address) else {
                let message = "The other Mac still has \(entry.name)."
                AppLog.switchFlow.error("take \(entry.address.rawValue) release refused")
                return .failed(message)
            }
        } else {
            AppLog.switchFlow.info("release skipped, peer down \(entry.address.rawValue)")
        }

        await logDeviceState(entry.address, "after release")

        // A Mac with no link key cannot page the accessory, so pair fresh.
        guard await bluetooth.isPaired(entry.address) else {
            AppLog.switchFlow.info("take \(entry.address.rawValue) not paired on this Mac")
            return await pairFresh(entry, peerUp: peerUp, isCurrent: isCurrent, transition: transition)
        }

        switch await connectTwice(entry.address) {
        case .connected:
            guard isCurrent() else { return .cancelled }
            AppLog.switchFlow.info("take \(entry.address.rawValue) existing bond connected")
            return .connectedOnExistingBond
        case .refused:
            guard isCurrent() else { return .cancelled }
            // The stored key is stale: the accessory holds another key.
            // Drop it and re-pair from scratch.
            AppLog.switchFlow.error("take \(entry.address.rawValue) link key stale, forgetting and re-pairing")
            await bluetooth.forget(entry.address)
            return await pairFresh(entry, peerUp: peerUp, isCurrent: isCurrent, transition: transition)
        case .absent:
            return await pairFresh(entry, peerUp: peerUp, isCurrent: isCurrent, transition: transition)
        }
    }

    private func requestRelease(_ address: DeviceAddress) async -> Bool {
        do {
            // The other Mac must delete its key. Otherwise the accessory keeps
            // paging it and never becomes discoverable for this Mac.
            try await peer.requestRelease(address, forget: true, timeout: timings.releaseTimeout)
            AppLog.switchFlow.info("release \(address.rawValue) forget=true accepted")
            return true
        } catch {
            AppLog.switchFlow.error("release \(address.rawValue) forget=true failed: \(error.localizedDescription)")
            return false
        }
    }

    private func logDeviceState(_ address: DeviceAddress, _ when: String) async {
        let connected = await bluetooth.isConnected(address)
        let paired = await bluetooth.isPaired(address)
        AppLog.switchFlow.info("state \(address.rawValue) \(when) connected=\(connected) paired=\(paired)")
    }

    private func connectTwice(_ address: DeviceAddress) async -> LinkResult {
        let first = await bluetooth.connect(address, timeout: timings.connect)
        if first == .connected {
            AppLog.switchFlow.info("connect \(address.rawValue) attempt 1 ok")
            return .connected
        }
        if first == .refused {
            AppLog.switchFlow.error("connect \(address.rawValue) attempt 1 rejected")
            return .refused
        }
        AppLog.switchFlow.info("connect \(address.rawValue) attempt 1 failed")
        let second = await bluetooth.connect(address, timeout: timings.connect)
        switch second {
        case .connected:
            AppLog.switchFlow.info("connect \(address.rawValue) attempt 2 ok")
        case .refused:
            AppLog.switchFlow.error("connect \(address.rawValue) attempt 2 rejected")
        case .absent:
            AppLog.switchFlow.info("connect \(address.rawValue) attempt 2 failed")
        }
        return second
    }

    private func pairFresh(
        _ entry: DeviceEntry,
        peerUp: Bool,
        isCurrent: () -> Bool,
        transition: (HandoffStepState) -> Void
    ) async -> HandoffStepState {
        transition(.waitingForKeyPress)
        AppLog.switchFlow.info("take \(entry.address.rawValue) waiting for a key press")
        await logDeviceState(entry.address, "before discover")
        let started = Date()
        // With the other Mac closed the accessory is still bonded to it and
        // will not appear until power-cycled, so fail sooner.
        let window = peerUp ? timings.discover : min(timings.discover, timings.discoverPeerDown)
        let seen = await bluetooth.waitUntilDiscovered(entry.address, timeout: window)
        AppLog.switchFlow.info("discover \(entry.address.rawValue) took \(Int(Date().timeIntervalSince(started)))s")
        AppLog.switchFlow.info(
            "discover \(entry.address.rawValue) \(seen ? "found" : "missed within \(Int(window))s")"
        )
        guard isCurrent() else { return .cancelled }
        guard seen else {
            return await failedKeepingOtherMacKey(entry, peerUp: peerUp)
        }

        do {
            try await bluetooth.pair(entry.address)
        } catch {
            AppLog.switchFlow.error("pair \(entry.address.rawValue) failed: \(error.localizedDescription)")
            return await failedKeepingOtherMacKey(entry, peerUp: peerUp)
        }
        guard isCurrent() else { return .cancelled }

        let connected = await bluetooth.connect(entry.address, timeout: timings.connect) == .connected
        AppLog.switchFlow.info("discover \(entry.address.rawValue) connect \(connected ? "ok" : "failed")")
        guard connected, isCurrent() else {
            return await failedKeepingOtherMacKey(entry, peerUp: peerUp)
        }
        return .pairedLocally
    }

    private func failedKeepingOtherMacKey(
        _ entry: DeviceEntry,
        peerUp: Bool
    ) async -> HandoffStepState {
        AppLog.switchFlow.error("take \(entry.address.rawValue) repair failed")
        // Don't spend the full rollback timeout on a Mac that went away.
        if peerUp, await peer.ping(timeout: timings.peerPing) {
            await peer.requestRollback(entry.address, timeout: timings.releaseTimeout)
        }
        return .failedKeepingOtherMacKey(
            "Couldn't reach \(entry.name). Turn it off and on, then try again."
        )
    }

    private func label(_ entry: DeviceEntry) -> String {
        "\(entry.name) \(entry.address.rawValue) bond=\(entry.bondMode.rawValue) holder=\(entry.holder.rawValue)"
    }
}

private struct RemoteOwnershipStep {
    enum SleepReleaseOutcome {
        case notConnected
        case releasedToPeer
        case heldForWake
    }

    let bluetooth: BluetoothControlling
    let timings: HandoffTimings

    func release(_ address: DeviceAddress, forget: Bool) async -> Bool {
        do {
            try await bluetooth.disconnect(address, timeout: timings.releaseDisconnect)
        } catch {
            AppLog.switchFlow.error(
                "remote release disconnect \(address.rawValue) failed: \(error.localizedDescription)"
            )
            return false
        }
        if forget {
            // No key means no paging. Suppressing would only keep the
            // accessory in a reconnect loop and hide it from discovery.
            await bluetooth.forget(address)
        } else {
            await bluetooth.suppress(address, safetyTimeout: timings.suppressSafety)
        }
        return true
    }

    func acceptRemoteOwnership(_ address: DeviceAddress) async {
        await bluetooth.stopSuppressing(address)
    }

    func forgetRejectedBond(_ address: DeviceAddress) async {
        try? await bluetooth.disconnect(address, timeout: timings.sleepDisconnect)
        await bluetooth.forget(address)
        await bluetooth.suppress(address, safetyTimeout: timings.suppressSafety)
    }

    func rollBack(_ address: DeviceAddress) async -> Bool {
        await bluetooth.stopSuppressing(address)
        if await bluetooth.isPaired(address) {
            let result = await bluetooth.connect(address, timeout: timings.connect)
            if result == .connected { return true }
            if result == .refused { await bluetooth.forget(address) }
        }
        // The key was deleted on release, so re-pair.
        guard await bluetooth.waitUntilDiscovered(address, timeout: timings.rollbackDiscover) else {
            return false
        }
        do { try await bluetooth.pair(address) } catch { return false }
        return await bluetooth.connect(address, timeout: timings.connect) == .connected
    }

    func takeAfterRemoteSleep(_ address: DeviceAddress) async -> Bool {
        await bluetooth.stopSuppressing(address)
        return await bluetooth.connect(address, timeout: timings.connect) == .connected
    }

    func releaseForSleep(
        _ address: DeviceAddress,
        peerUp: Bool
    ) async -> SleepReleaseOutcome {
        guard await bluetooth.isConnected(address) else { return .notConnected }
        try? await bluetooth.disconnect(address, timeout: timings.sleepDisconnect)
        if peerUp {
            await bluetooth.suppress(address, safetyTimeout: 30)
            return .releasedToPeer
        }
        // Nobody can take it yet. Keep refusing so this Mac does not
        // reconnect it on the way into sleep.
        await bluetooth.suppress(address, safetyTimeout: 12 * 60 * 60)
        return .heldForWake
    }
}

@MainActor
private struct ReturnWatcher {
    let bluetooth: BluetoothControlling
    let timings: HandoffTimings

    func run(
        devices: () -> [DeviceEntry],
        shouldContinue: () -> Bool,
        stillOwns: (DeviceAddress) -> Bool,
        didReconnect: (DeviceAddress) -> Void
    ) async {
        let deadline = Date().addingTimeInterval(timings.wakeWatch)
        while Date() < deadline, !Task.isCancelled, shouldContinue() {
            for entry in devices() where entry.holder == .thisMac || entry.holder == .unknown {
                if await bluetooth.connect(entry.address, timeout: timings.connect) == .connected {
                    guard stillOwns(entry.address) else {
                        await disconnectReleased(entry.address)
                        continue
                    }
                    AppLog.switchFlow.info("return \(entry.address.rawValue) reconnected")
                    didReconnect(entry.address)
                    continue
                }

                let slice = min(4, deadline.timeIntervalSinceNow)
                guard slice > 0 else { break }
                // waitUntilDiscovered owns the inquiry for this slice.
                guard await bluetooth.waitUntilDiscovered(entry.address, timeout: slice) else { continue }
                AppLog.switchFlow.info("return \(entry.address.rawValue) discovered")
                try? await bluetooth.pair(entry.address)
                guard await bluetooth.connect(entry.address, timeout: timings.connect) == .connected else {
                    continue
                }
                guard stillOwns(entry.address) else {
                    await disconnectReleased(entry.address)
                    continue
                }
                AppLog.switchFlow.info("return \(entry.address.rawValue) paired and connected")
                didReconnect(entry.address)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func disconnectReleased(_ address: DeviceAddress) async {
        AppLog.switchFlow.info("return \(address.rawValue) released during reconnect")
        try? await bluetooth.disconnect(address, timeout: timings.releaseDisconnect)
    }
}

@MainActor
final class HandoffCoordinator: ObservableObject {
    @Published private(set) var activity: HandoffActivity = .idle
    @Published private(set) var statuses: [DeviceAddress: DeviceStatus] = [:]
    @Published private(set) var prompt: HandoffPrompt = .none
    @Published private(set) var peerReachable = false
    @Published private(set) var summary: String?

    var onDevicesChanged: (([DeviceEntry]) -> Void)?
    var onFinished: ((HandoffResult) -> Void)?
    /// When this returns false, a switch is refused before any device is touched.
    var switchingAllowed: () -> Bool = { true }
    var switchingBlockedMessage = "The other Mac's identity changed. Trust it in Settings before switching."

    private let bluetooth: BluetoothControlling
    private let peer: PeerLinking
    private let timings: HandoffTimings
    private var handoffState: HandoffStepState = .idle
    private var runTask: Task<Void, Never>?
    private var returnWatch: Task<Void, Never>?
    /// Addresses this Mac has been asked to give up. The return watcher must
    /// not page them back while the disconnect is still in progress.
    private var releasing: Set<DeviceAddress> = []
    private var devices: [DeviceEntry] = []
    /// Bumped on every new switch and on Stop, so a late result from the
    /// previous attempt cannot mark the new one failed.
    private var generation = 0

    init(
        bluetooth: BluetoothControlling,
        peer: PeerLinking,
        timings: HandoffTimings = HandoffTimings()
    ) {
        self.bluetooth = bluetooth
        self.peer = peer
        self.timings = timings
    }

    func status(for address: DeviceAddress) -> DeviceStatus {
        statuses[address] ?? .unknown
    }

    func noteConnected(_ address: DeviceAddress) {
        statuses[address] = .success
    }

    func useDevices(_ devices: [DeviceEntry]) {
        guard activity != .working else { return }
        self.devices = devices
    }

    func integrateClaims(_ remote: [ClaimStamp]) -> [ClaimStamp] {
        let updated = HandoffClaims.apply(local: devices, remote: remote)
        for entry in updated {
            guard let before = devices.first(where: { $0.address == entry.address }) else { continue }
            guard before.holder != entry.holder || before.holderSince != entry.holderSince else { continue }
            AppLog.switchFlow.info("claim \(label(entry)) was \(before.holder.rawValue)")
        }
        replace(updated)
        return claimStamps()
    }

    func refreshStatuses(devices: [DeviceEntry]) {
        guard activity != .working else { return }
        self.devices = devices
        let addresses = devices.map(\.address)
        Task {
            var connected: [DeviceAddress: Bool] = [:]
            for address in addresses {
                connected[address] = await bluetooth.isConnected(address)
            }
            guard activity != .working else { return }
            for (address, isConnected) in connected {
                let previous = statuses[address]
                if isConnected {
                    // A rejected link key stays "connected" for a few seconds
                    // and does not type. Don't paint that as success.
                    if case .failure = previous {
                    } else {
                        statuses[address] = .success
                    }
                } else {
                    statuses[address] = .disconnected
                    if previous == .success {
                        AppLog.switchFlow.info("dropped \(address.rawValue)")
                        noteDropped(address)
                    }
                }
            }
        }
    }

    func useHere(devices: [DeviceEntry]) {
        start { token in await self.runUseHere(devices, token: token) }
    }

    func handOff(devices: [DeviceEntry]) {
        start { token in await self.runHandOff(devices, token: token) }
    }

    func stop() {
        AppLog.switchFlow.info("stop")
        generation += 1
        runTask?.cancel()
        runTask = nil
        returnWatch?.cancel()
        prompt = .none
        activity = .idle
        summary = "Stopped."
        Task { await bluetooth.cancelOperations() }
    }

    /// Drops the accessory and keeps this Mac from paging it back.
    /// Returns false when the baseband link is still up, so the other Mac is not told to connect.
    @discardableResult
    func handleRemoteRelease(_ address: DeviceAddress, forget: Bool) async -> Bool {
        AppLog.switchFlow.info("remote release \(address.rawValue) forget=\(forget)")
        releasing.insert(address)
        handoffState = .releasing
        defer {
            releasing.remove(address)
            handoffState = .idle
        }
        returnWatch?.cancel()
        let step = RemoteOwnershipStep(bluetooth: bluetooth, timings: timings)
        guard await step.release(address, forget: forget) else {
            return false
        }
        let now = Date()
        update(address) { entry in
            if forget {
                entry.bondMode = .single
            }
            entry.holder = .otherMac
            entry.holderSince = now
        }
        statuses[address] = .disconnected
        return true
    }

    func handleRemoteOwned(_ address: DeviceAddress, at date: Date = Date()) async {
        AppLog.switchFlow.info("remote owned \(address.rawValue)")
        let step = RemoteOwnershipStep(bluetooth: bluetooth, timings: timings)
        await step.acceptRemoteOwnership(address)
        update(address) { entry in
            entry.bondMode = .single
            entry.holder = .otherMac
            entry.holderSince = date
        }
        statuses[address] = .disconnected
    }

    func handleRemoteFailed(_ address: DeviceAddress) async {
        AppLog.switchFlow.info("remote failed \(address.rawValue), forgetting bond")
        let step = RemoteOwnershipStep(bluetooth: bluetooth, timings: timings)
        await step.forgetRejectedBond(address)
        update(address) { entry in
            entry.bondMode = .single
            entry.holder = .otherMac
            entry.holderSince = Date()
        }
    }

    func handleRemoteRollback(_ address: DeviceAddress) async {
        AppLog.switchFlow.info("remote rollback \(address.rawValue)")
        let step = RemoteOwnershipStep(bluetooth: bluetooth, timings: timings)
        let connected = await step.rollBack(address)
        AppLog.switchFlow.info("remote rollback \(address.rawValue) connected=\(connected)")
        update(address) { entry in
            entry.holder = connected ? .thisMac : entry.holder
            entry.holderSince = connected ? Date() : entry.holderSince
        }
        statuses[address] = connected ? .success : .failure("Couldn't reconnect \(name(of: address)).")
    }

    func handleWillSleep() async {
        let peerUp = await peer.ping(timeout: timings.peerPing)
        peerReachable = peerUp
        AppLog.switchFlow.info("sleep peerUp=\(peerUp)")
        let step = RemoteOwnershipStep(bluetooth: bluetooth, timings: timings)
        var released: [DeviceAddress] = []
        let now = Date()
        for entry in devices {
            switch await step.releaseForSleep(entry.address, peerUp: peerUp) {
            case .notConnected:
                continue
            case .releasedToPeer:
                update(entry.address) { device in
                    device.holder = .otherMac
                    device.holderSince = now
                }
                released.append(entry.address)
            case .heldForWake:
                update(entry.address) { device in
                    device.holder = .unknown
                    device.holderSince = now
                }
            }
            statuses[entry.address] = .disconnected
        }
        if peerUp, !released.isEmpty {
            AppLog.switchFlow.info("sleep released \(released.map(\.rawValue).joined(separator: ","))")
            await peer.notifySleeping(released)
        }
    }

    func handleRemoteSleeping(_ address: DeviceAddress) async {
        AppLog.switchFlow.info("remote sleeping \(address.rawValue)")
        let step = RemoteOwnershipStep(bluetooth: bluetooth, timings: timings)
        if await step.takeAfterRemoteSleep(address) {
            AppLog.switchFlow.info("remote sleeping \(address.rawValue) connected")
            _ = await adopted(entryFor(address), mode: bondMode(of: address), peerUp: true)
        } else {
            AppLog.switchFlow.info("remote sleeping \(address.rawValue) not connected")
        }
    }

    func handleDidWake() async {
        for entry in devices {
            await bluetooth.stopSuppressing(entry.address)
        }
        let remote = await peer.exchangeClaims(claimStamps(), timeout: timings.claimTimeout)
        let answered = await peer.ping(timeout: timings.peerPing)
        peerReachable = !remote.isEmpty || answered
        AppLog.switchFlow.info("wake peerUp=\(peerReachable) claims=\(remote.count)")
        _ = integrateClaims(remote)
        for entry in devices where entry.holder == .otherMac {
            if await bluetooth.isConnected(entry.address) {
                try? await bluetooth.disconnect(entry.address, timeout: timings.sleepDisconnect)
            }
            statuses[entry.address] = .disconnected
        }
        watchForReturn()
    }

    private func start(_ body: @escaping @MainActor (Int) async -> HandoffResult) {
        guard switchingAllowed() else {
            AppLog.switchFlow.error("switch blocked: \(switchingBlockedMessage)")
            summary = switchingBlockedMessage
            activity = .finished
            onFinished?(HandoffResult(devices: devices, summary: switchingBlockedMessage, succeeded: false))
            return
        }
        generation += 1
        let token = generation
        AppLog.switchFlow.info("switch start token=\(token)")
        runTask?.cancel()
        returnWatch?.cancel()
        runTask = Task {
            let result = await body(token)
            guard token == self.generation, !Task.isCancelled else {
                AppLog.switchFlow.info("switch token=\(token) discarded")
                return
            }
            AppLog.switchFlow.info("switch token=\(token) \(result.succeeded ? "ok" : "failed"): \(result.summary)")
            summary = result.summary
            activity = .finished
            prompt = .none
            onFinished?(result)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }

    private func runUseHere(_ requested: [DeviceEntry], token: Int) async -> HandoffResult {
        activity = .working
        prompt = .none
        let targets = Set(requested.map(\.address))
        merge(requested)
        AppLog.switchFlow.info("useHere \(requested.map(label).joined(separator: " | "))")
        var todo: [DeviceEntry] = []
        for entry in DeviceEntry.handoffOrder(devices) where targets.contains(entry.address) {
            let connected = await bluetooth.isConnected(entry.address)
            let alreadyHere = entry.holder == .thisMac && connected
            AppLog.switchFlow.info("useHere \(label(entry)) connected=\(connected) alreadyHere=\(alreadyHere)")
            if alreadyHere {
                statuses[entry.address] = .success
            } else {
                todo.append(entry)
            }
        }
        if todo.isEmpty {
            return HandoffResult(devices: devices, summary: "Already on this Mac.", succeeded: true)
        }

        let peerUp = await peer.ping(timeout: timings.peerPing)
        peerReachable = peerUp
        AppLog.switchFlow.info("useHere peerUp=\(peerUp)")
        if !peerUp {
            prompt = .peerAsleep
        }

        var failures: [String] = []
        var moved: [String] = []
        for entry in todo {
            if !isCurrent(token) {
                AppLog.switchFlow.info("useHere cancelled before \(entry.address.rawValue)")
                break
            }
            if await take(entry, peerUp: peerUp, token: token) {
                moved.append(entry.name)
            } else if isCurrent(token) {
                failures.append(entry.name)
            }
        }
        return HandoffResult(
            devices: devices,
            summary: summarize(moved: moved, failed: failures),
            succeeded: failures.isEmpty && !moved.isEmpty
        )
    }

    private func take(_ entry: DeviceEntry, peerUp: Bool, token: Int) async -> Bool {
        statuses[entry.address] = .working
        let step = TakeAccessoryStep(bluetooth: bluetooth, peer: peer, timings: timings)
        let outcome = await step.run(
            entry,
            peerUp: peerUp,
            isCurrent: { self.isCurrent(token) },
            transition: { state in
                self.handoffState = state
                if state == .waitingForKeyPress {
                    self.prompt = peerUp ? .pressKey(entry.name) : .powerCycle(entry.name)
                }
            }
        )
        handoffState = outcome

        switch outcome {
        case .connectedOnExistingBond, .pairedLocally:
            // The other Mac deleted its key on release, so only this Mac
            // holds a key now.
            return await adopted(entry, mode: peerUp ? .single : .multi, peerUp: peerUp)
        case let .failedKeepingOtherMacKey(message):
            update(entry.address) { device in
                if message.hasPrefix("Pair ") {
                    device.bondMode = .single
                }
            }
            statuses[entry.address] = .failure(message)
            prompt = peerUp ? .none : .peerAsleep
            return false
        case let .failed(message):
            statuses[entry.address] = .failure(message)
            return false
        case .cancelled, .idle, .working, .releasing, .waitingForKeyPress:
            return false
        }
    }

    private func adopted(_ entry: DeviceEntry, mode: BondMode, peerUp: Bool) async -> Bool {
        AppLog.switchFlow.info("adopted \(entry.address.rawValue) mode=\(mode.rawValue) peerUp=\(peerUp)")
        await bluetooth.stopSuppressing(entry.address)
        if peerUp {
            await peer.notifyOwned(entry.address)
        }
        let now = Date()
        update(entry.address) { device in
            device.bondMode = mode
            device.holder = .thisMac
            device.holderSince = now
        }
        statuses[entry.address] = .success
        prompt = .none
        handoffState = .idle
        return true
    }

    private func runHandOff(_ requested: [DeviceEntry], token: Int) async -> HandoffResult {
        activity = .working
        prompt = .none
        let targets = Set(requested.map(\.address))
        merge(requested)
        AppLog.switchFlow.info("handOff \(requested.map(label).joined(separator: " | "))")
        var moved: [String] = []
        for entry in DeviceEntry.handoffOrder(devices) where targets.contains(entry.address) {
            if !isCurrent(token) {
                AppLog.switchFlow.info("handOff cancelled before \(entry.address.rawValue)")
                break
            }
            let connected = await bluetooth.isConnected(entry.address)
            let alreadyGone = entry.holder == .otherMac && connected == false
            AppLog.switchFlow.info("handOff \(label(entry)) connected=\(connected) alreadyGone=\(alreadyGone)")
            if alreadyGone {
                statuses[entry.address] = .disconnected
                continue
            }
            statuses[entry.address] = .working
            do {
                try await bluetooth.disconnect(entry.address, timeout: timings.connect)
            } catch {
                AppLog.switchFlow.error("handOff disconnect \(entry.address.rawValue) failed: \(error.localizedDescription)")
            }
            await bluetooth.suppress(entry.address, safetyTimeout: timings.suppressSafety)
            if entry.bondMode != .multi {
                AppLog.switchFlow.info("handOff forget \(entry.address.rawValue)")
                await bluetooth.forget(entry.address)
                await bluetooth.stopSuppressing(entry.address)
            } else {
                AppLog.switchFlow.info("handOff keep bond \(entry.address.rawValue)")
            }
            let now = Date()
            update(entry.address) { device in
                if device.bondMode != .multi {
                    device.bondMode = .single
                }
                device.holder = .otherMac
                device.holderSince = now
            }
            statuses[entry.address] = .disconnected
            moved.append(entry.name)
        }
        if moved.isEmpty {
            return HandoffResult(devices: devices, summary: "Already handed off.", succeeded: true)
        }
        return HandoffResult(
            devices: devices,
            summary: "Handed off \(moved.joined(separator: ", ")).",
            succeeded: true
        )
    }

    /// After wake, or after a device drops while this Mac should have it,
    /// keep listening so a power cycle reconnects without opening the menu.
    func watchForReturn() {
        guard timings.wakeWatch > 0 else { return }
        AppLog.switchFlow.info("watch for return \(Int(timings.wakeWatch))s")
        returnWatch?.cancel()
        returnWatch = Task {
            let watcher = ReturnWatcher(bluetooth: self.bluetooth, timings: self.timings)
            await watcher.run(
                devices: { self.devices },
                shouldContinue: { self.activity != .working },
                stillOwns: { self.stillOwns($0) },
                didReconnect: { address in
                    self.statuses[address] = .success
                    self.update(address) { device in
                        device.holder = .thisMac
                        device.holderSince = Date()
                    }
                }
            )
        }
    }

    func noteDropped(_ address: DeviceAddress) {
        guard devices.first(where: { $0.address == address })?.holder == .thisMac else { return }
        guard activity != .working else { return }
        watchForReturn()
    }

    private func stillOwns(_ address: DeviceAddress) -> Bool {
        guard !releasing.contains(address) else { return false }
        let holder = devices.first(where: { $0.address == address })?.holder
        return holder == .thisMac || holder == .unknown
    }

    private func entryFor(_ address: DeviceAddress) -> DeviceEntry {
        devices.first(where: { $0.address == address })
            ?? DeviceEntry(name: address.rawValue, address: address)
    }

    private func bondMode(of address: DeviceAddress) -> BondMode {
        devices.first(where: { $0.address == address })?.bondMode ?? .unknown
    }

    private func claimStamps() -> [ClaimStamp] {
        devices.compactMap { entry in
            guard let since = entry.holderSince else { return nil }
            return ClaimStamp(address: entry.address.rawValue, holderSince: since, mine: entry.holder == .thisMac)
        }
    }

    private func update(_ address: DeviceAddress, _ change: (inout DeviceEntry) -> Void) {
        guard let index = devices.firstIndex(where: { $0.address == address }) else { return }
        change(&devices[index])
        onDevicesChanged?(devices)
    }

    /// A switch for one accessory must not drop the others from the saved list.
    private func merge(_ incoming: [DeviceEntry]) {
        var merged = devices
        for entry in incoming {
            if let index = merged.firstIndex(where: { $0.address == entry.address }) {
                merged[index] = entry
            } else {
                merged.append(entry)
            }
        }
        replace(merged)
    }

    private func replace(_ devices: [DeviceEntry]) {
        self.devices = devices
        onDevicesChanged?(devices)
    }

    private func label(_ entry: DeviceEntry) -> String {
        "\(entry.name) \(entry.address.rawValue) bond=\(entry.bondMode.rawValue) holder=\(entry.holder.rawValue)"
    }

    private func name(of address: DeviceAddress) -> String {
        devices.first(where: { $0.address == address })?.name ?? address.rawValue
    }

    private func summarize(moved: [String], failed: [String]) -> String {
        if moved.isEmpty && failed.isEmpty { return "No devices to bring over." }
        if failed.isEmpty { return "Connected \(moved.joined(separator: ", "))." }
        if moved.isEmpty { return "Couldn't bring \(failed.joined(separator: ", "))." }
        return "Connected \(moved.joined(separator: ", ")). Couldn't bring \(failed.joined(separator: ", "))."
    }
}

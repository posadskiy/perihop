import Foundation

/// What a device row shows.
enum DeviceState: Equatable, Sendable {
    /// Not checked yet.
    case unknown
    /// Connected to this Mac.
    case here
    /// The other Mac says it has the device.
    case onOtherMac
    /// Connected to neither Mac as far as this one knows.
    case away
    /// A switch is working on it. The text says what it is doing.
    case moving(String)
    /// This Mac keeps trying in the background, for example until the
    /// device is woken with a key press.
    case waiting
    case failed(String)
}

struct PeerStatus: Sendable, Equatable {
    /// Devices connected to the other Mac right now.
    var held: [DeviceAddress]
    /// The devices the other Mac is set up to switch.
    var devices: [DeviceEntry]
}

/// The other Mac, as the engine sees it.
protocol PeerLinking: Sendable {
    /// True when this Mac has been linked with another Mac, reachable or not.
    func isLinked() async -> Bool
    /// True while a connection to the other Mac is open. When none is, the
    /// other Mac is most likely asleep, and finding out for sure takes a
    /// few seconds.
    func isConnected() async -> Bool
    func ping(timeout: TimeInterval) async -> Bool
    func status(timeout: TimeInterval) async -> PeerStatus?
    /// Asks the other Mac to let go. Returns the addresses it freed, or nil
    /// when it did not answer.
    func requestRelease(_ addresses: [DeviceAddress], timeout: TimeInterval) async -> Set<DeviceAddress>?
    /// Asks the other Mac to take devices this Mac has just freed. True when
    /// it accepted. The result of each device arrives later as an outcome.
    func requestTake(_ devices: [DeviceEntry], timeout: TimeInterval) async -> Bool
    func notifyOutcome(_ address: DeviceAddress, connected: Bool) async
    func notifyStatus(_ status: PeerStatus) async
}

struct HandoffTimings: Sendable, Equatable {
    var peerPing: TimeInterval = 1.5
    /// Page time for opening a link with an existing pairing.
    var connect: TimeInterval = 4
    /// How long one pairing attempt pages the device.
    var pair: TimeInterval = 20
    /// The first attempt of a switch is shorter, so a device that is asleep
    /// does not hold up the next one.
    var firstPair: TimeInterval = 8
    /// How long to wait for the other Mac when no connection to it is open.
    var peerDial: TimeInterval = 8
    /// How long the other Mac gets to unpair.
    var releaseRequest: TimeInterval = 12
    /// How long a local unpair may wait for the link to drop.
    var release: TimeInterval = 6
    /// After pairing, how long to wait for the link to come up by itself.
    var settle: TimeInterval = 3
    /// Pause between background attempts.
    var retryPause: TimeInterval = 3
    /// How long a switch the user asked for keeps trying.
    var userWindow: TimeInterval = 120
    /// How long a device the other Mac pushed here is tried.
    var pushedWindow: TimeInterval = 75
    /// How long a device that dropped, or was freed for sleep, is tried.
    var reclaimWindow: TimeInterval = 1800
    /// After this long, attempts for such a device are spaced out, so a
    /// device that stays away does not keep the radio busy.
    var eagerWindow: TimeInterval = 120
    var slowPause: TimeInterval = 30
    var slowPair: TimeInterval = 6
    /// How long a free device is tried after this Mac wakes.
    var adoptWindow: TimeInterval = 120
    /// Pairing attempts for a free device before giving up. A device held
    /// by a Mac this one cannot reach never answers, so this stays small.
    var adoptAttempts = 3
    /// How long the sender of a hand off waits for the other Mac's result.
    var outcomeWait: TimeInterval = 80
    /// A disconnect this soon after a deliberate release is that release.
    var releaseGrace: TimeInterval = 60
    /// Wi-Fi needs a moment after wake before the other Mac can answer.
    var wakeDelay: TimeInterval = 3
    /// The longest sleep is held back while devices are freed.
    var sleepBudget: TimeInterval = 6
}

struct HandoffResult: Equatable, Sendable {
    var summary: String
    var succeeded: Bool
}

/// Moves accessories between this Mac and the other one.
///
/// A Magic accessory keeps one host, so only one Mac ever holds a pairing.
/// The Mac that has the device unpairs it while connected, which makes the
/// device listen for a new host, and the Mac that wants it pairs it by
/// address. Who has a device is read from the live Bluetooth link, never
/// from a saved record.
@MainActor
final class HandoffCoordinator: ObservableObject {
    @Published private(set) var connected: Set<DeviceAddress> = []
    @Published private(set) var peerHeld: Set<DeviceAddress> = []
    @Published private(set) var peerDevices: [DeviceEntry] = []
    @Published private(set) var progress: [DeviceAddress: String] = [:]
    @Published private(set) var failures: [DeviceAddress: String] = [:]
    @Published private(set) var hint: String?
    @Published private(set) var summary: String?
    @Published private(set) var peerReachable = false
    @Published private(set) var isSwitching = false
    @Published private(set) var devices: [DeviceEntry] = []
    @Published private(set) var checked = false

    /// Called when a device was added because the other Mac sent it here.
    var onDevicesChanged: (([DeviceEntry]) -> Void)?
    var onFinished: ((HandoffResult) -> Void)?
    /// When this returns false, a switch is refused before any device is touched.
    var switchingAllowed: () -> Bool = { true }
    var switchingBlockedMessage = "The other Mac's identity changed. Trust it in Settings before switching."
    /// False during a dark wake, when nobody is at this Mac.
    var userIsPresent: () -> Bool = { true }
    var releaseOnSleep: () -> Bool = { true }
    /// True when this Mac is woken from its keyboard: lid closed, on an
    /// external display. Its devices are then only given up to a Mac that
    /// is there to take them.
    var wakesFromDevices: () -> Bool = { false }
    var takeOnWake: () -> Bool = { true }
    var reconnectDropped: () -> Bool = { true }

    private enum ChaseKind: Equatable {
        /// The user asked for it here.
        case user
        /// The other Mac freed it and asked this Mac to take it.
        case pushed
        /// It was on this Mac and dropped, or was freed for sleep.
        case reclaim
        /// It is free and this Mac just woke up.
        case adopt
    }

    private struct Chase {
        var kind: ChaseKind
        var started = Date()
        var nextAttempt = Date.distantPast
        var deadline: Date
        var pairAttempts = 0
        var peerSilent = 0
        /// The other Mac gave it up for this attempt and should get it back
        /// if this Mac cannot connect it.
        var returnToPeer = false
    }

    private let bluetooth: BluetoothControlling
    private let peer: PeerLinking
    private let timings: HandoffTimings
    private var chases: [DeviceAddress: Chase] = [:]
    private var chaseLoop: Task<Void, Never>?
    /// Identifies the running loop, so one that was cancelled for sleep and
    /// is still unwinding cannot be mistaken for its replacement.
    private var chaseLoopID = 0
    private var runTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    /// Bumped on every switch and on Stop, so a late result from an earlier
    /// attempt cannot change the current one.
    private var generation = 0
    /// Releases this Mac made on purpose, with the time, so the disconnect
    /// that follows is not treated as a drop.
    private var released: [DeviceAddress: Date] = [:]
    private var outcomes: [DeviceAddress: Bool] = [:]
    private var freedForSleep: Set<DeviceAddress> = []
    /// Devices the other Mac freed after this Mac had already started on them.
    private var lateFreed: Set<DeviceAddress> = []
    private var asleep = false
    private var lastStatusSent: PeerStatus?

    init(
        bluetooth: BluetoothControlling,
        peer: PeerLinking,
        timings: HandoffTimings = HandoffTimings()
    ) {
        self.bluetooth = bluetooth
        self.peer = peer
        self.timings = timings
    }

    // MARK: State

    func state(for address: DeviceAddress) -> DeviceState {
        if let text = progress[address] { return .moving(text) }
        if connected.contains(address) { return .here }
        if chases[address] != nil { return .waiting }
        if let message = failures[address] { return .failed(message) }
        if peerHeld.contains(address) { return .onOtherMac }
        return checked ? .away : .unknown
    }

    var localStatus: PeerStatus {
        PeerStatus(held: devices.map(\.address).filter(connected.contains), devices: devices)
    }

    func start() {
        guard eventsTask == nil else { return }
        eventsTask = Task { [weak self] in
            guard let stream = await self?.bluetooth.events() else { return }
            for await event in stream {
                await self?.handle(event)
            }
        }
        Task { await refresh() }
    }

    func useDevices(_ devices: [DeviceEntry]) {
        self.devices = devices
        let known = Set(devices.map(\.address))
        connected = connected.intersection(known)
        for address in chases.keys where !known.contains(address) {
            chases[address] = nil
        }
        Task { await refresh() }
    }

    /// Re-reads the links and asks the other Mac what it has.
    func refresh() async {
        var live: Set<DeviceAddress> = []
        for entry in devices where await bluetooth.isConnected(entry.address) {
            live.insert(entry.address)
        }
        let dropped = connected.subtracting(live)
        connected = live
        checked = true
        for address in live {
            failures[address] = nil
        }
        for address in dropped {
            noteDropped(address)
        }
        await refreshPeer()
        await announce()
    }

    func refreshPeer() async {
        guard await peer.isLinked() else {
            peerReachable = false
            peerHeld = []
            return
        }
        apply(await peer.status(timeout: timings.peerPing))
    }

    /// The other Mac told this one what it has.
    func notePeerStatus(_ status: PeerStatus) {
        apply(status)
    }

    private func apply(_ status: PeerStatus?) {
        peerReachable = status != nil
        guard let status else {
            peerHeld = []
            return
        }
        peerHeld = Set(status.held)
        peerDevices = status.devices
        for address in status.held {
            // The other Mac has it, so this Mac stops trying to get it back.
            if let chase = chases[address], chase.kind == .reclaim || chase.kind == .adopt {
                AppLog.switchFlow.info("chase \(address.rawValue) ended, the other Mac has it")
                chases[address] = nil
            }
        }
    }

    // MARK: Switches the user starts

    func useHere(devices requested: [DeviceEntry]) {
        begin { token in await self.runUseHere(requested, token: token) }
    }

    func handOff(devices requested: [DeviceEntry]) {
        begin { token in await self.runHandOff(requested, token: token) }
    }

    /// Devices on this Mac go to the other one. If none are here, they come here.
    func toggle(devices requested: [DeviceEntry]) {
        let here = requested.filter { connected.contains($0.address) }
        if here.isEmpty {
            useHere(devices: requested)
        } else {
            handOff(devices: here)
        }
    }

    func stop() {
        AppLog.switchFlow.info("stop")
        generation += 1
        runTask?.cancel()
        runTask = nil
        for (address, chase) in chases where chase.kind == .user || chase.kind == .pushed {
            chases[address] = nil
        }
        progress = [:]
        hint = nil
        isSwitching = false
        summary = "Stopped."
        Task { await bluetooth.cancelOperations() }
    }

    private func begin(_ body: @escaping @MainActor (Int) async -> HandoffResult) {
        guard switchingAllowed() else {
            AppLog.switchFlow.error("switch blocked: \(switchingBlockedMessage)")
            summary = switchingBlockedMessage
            onFinished?(HandoffResult(summary: switchingBlockedMessage, succeeded: false))
            return
        }
        guard !isSwitching else {
            // Two switches at once would pair the same device twice.
            AppLog.switchFlow.info("switch ignored, one is already running")
            return
        }
        generation += 1
        let token = generation
        isSwitching = true
        summary = nil
        hint = nil
        runTask = Task {
            let result = await body(token)
            guard token == self.generation, !Task.isCancelled else { return }
            AppLog.switchFlow.info("switch \(result.succeeded ? "ok" : "failed"): \(result.summary)")
            self.progress = [:]
            self.isSwitching = false
            self.summary = result.summary
            self.onFinished?(result)
            await self.announce()
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }

    private func runUseHere(_ requested: [DeviceEntry], token: Int) async -> HandoffResult {
        guard await bluetooth.isPoweredOn() else {
            return HandoffResult(summary: "Bluetooth is off on this Mac.", succeeded: false)
        }
        var todo: [DeviceEntry] = []
        for entry in DeviceEntry.handoffOrder(requested) {
            failures[entry.address] = nil
            if await bluetooth.isConnected(entry.address) {
                connected.insert(entry.address)
            } else {
                todo.append(entry)
            }
        }
        AppLog.switchFlow.info("use here \(todo.map(label).joined(separator: " | "))")
        guard !todo.isEmpty else {
            return HandoffResult(summary: "Already on this Mac.", succeeded: true)
        }
        for entry in todo {
            chases[entry.address] = nil
            progress[entry.address] = "Connecting…"
        }

        // The other Mac lets go first. A device it was holding has no key
        // for this Mac, so the saved pairing here is dropped unused.
        var freed: Set<DeviceAddress> = []
        if await peer.isLinked() {
            if await peer.isConnected() {
                let status = await peer.status(timeout: timings.peerPing)
                apply(status)
                let there = todo.filter { status?.held.contains($0.address) == true }
                if !there.isEmpty {
                    for entry in there {
                        progress[entry.address] = "Asking the other Mac…"
                    }
                    let answer = await peer.requestRelease(there.map(\.address), timeout: timings.releaseRequest)
                    guard isCurrent(token) else { return cancelled }
                    freed = answer ?? []
                    AppLog.switchFlow.info("the other Mac freed \(freed.map(\.rawValue).sorted().joined(separator: ","))")
                    for entry in there where !freed.contains(entry.address) {
                        progress[entry.address] = nil
                        failures[entry.address] = "The other Mac couldn't let go of \(entry.name)."
                    }
                    todo.removeAll { entry in there.contains(entry) && !freed.contains(entry.address) }
                    peerHeld.subtract(freed)
                }
            } else {
                // No connection is open, so the other Mac is probably
                // asleep. This Mac starts on the devices now and asks it to
                // let go if it turns out to be there after all.
                askLate(todo, token: token)
            }
        }

        var moved: [String] = []
        var pending: [DeviceEntry] = []
        for entry in todo {
            guard isCurrent(token) else { return cancelled }
            progress[entry.address] = "Connecting…"
            let linked = await link(entry.address, staleBond: freed.contains(entry.address), pairTimeout: timings.firstPair)
            guard isCurrent(token) else { return cancelled }
            progress[entry.address] = nil
            if linked {
                adopt(entry.address)
                moved.append(entry.name)
            } else {
                pending.append(entry)
            }
        }

        // A device that did not answer is usually asleep. Keep trying in
        // the background so one key press brings it over.
        for entry in pending {
            chase(entry.address, kind: .user, returnToPeer: freed.contains(entry.address) || lateFreed.contains(entry.address))
        }
        if let first = pending.first {
            hint = wakeHint(first.name, more: pending.count - 1)
        }
        let failed = requested.filter { failures[$0.address] != nil }.map(\.name)
        return HandoffResult(
            summary: Self.takeSummary(moved: moved, waiting: pending.map(\.name), failed: failed),
            succeeded: pending.isEmpty && failed.isEmpty
        )
    }

    private func runHandOff(_ requested: [DeviceEntry], token: Int) async -> HandoffResult {
        var targets: [DeviceEntry] = []
        for entry in DeviceEntry.handoffOrder(requested) {
            failures[entry.address] = nil
            if await bluetooth.isConnected(entry.address) {
                targets.append(entry)
            } else if chases[entry.address] != nil {
                // Not here, and no longer wanted here.
                chases[entry.address] = nil
            }
        }
        AppLog.switchFlow.info("hand off \(targets.map(label).joined(separator: " | "))")
        guard !targets.isEmpty else {
            return HandoffResult(summary: "Nothing on this Mac to hand off.", succeeded: true)
        }
        let linked = await peer.isLinked()
        for entry in targets {
            progress[entry.address] = linked ? "Sending…" : "Releasing…"
        }
        // Answering a ping is the proof the other Mac can act. An open
        // socket is not: a Mac going to sleep keeps its sockets for a while.
        var peerUp = false
        if linked {
            peerUp = await peer.isConnected()
                ? await peer.ping(timeout: timings.peerPing)
                : await peer.status(timeout: timings.peerDial) != nil
        }
        peerReachable = peerUp
        guard isCurrent(token) else { return cancelled }

        let freed = await free(targets.map(\.address))
        guard isCurrent(token) else { return cancelled }
        let stuck = targets.filter { !freed.contains($0.address) }
        for entry in stuck {
            progress[entry.address] = nil
            failures[entry.address] = "Couldn't release \(entry.name)."
        }
        let sent = targets.filter { freed.contains($0.address) }
        let names = sent.map(\.name).joined(separator: ", ")
        guard !sent.isEmpty else {
            return HandoffResult(summary: "Couldn't release \(stuck.map(\.name).joined(separator: ", ")).", succeeded: false)
        }
        guard linked else {
            return HandoffResult(summary: "Released \(names).", succeeded: stuck.isEmpty)
        }
        guard peerUp else {
            return HandoffResult(
                summary: "Released \(names). The other Mac is asleep and can take over when it wakes.",
                succeeded: stuck.isEmpty
            )
        }

        for entry in sent {
            outcomes[entry.address] = nil
        }
        let accepted = await peer.requestTake(sent, timeout: timings.releaseRequest)
        guard isCurrent(token) else { return cancelled }
        var arrived: [String] = []
        var returned: [DeviceEntry] = []
        if accepted {
            for entry in sent {
                if await outcome(of: entry.address, token: token) {
                    arrived.append(entry.name)
                    peerHeld.insert(entry.address)
                } else {
                    returned.append(entry)
                }
                progress[entry.address] = nil
                guard isCurrent(token) else { return cancelled }
            }
        } else {
            returned = sent
        }

        // Nothing is left on neither Mac: what the other Mac did not take
        // comes back here.
        for entry in returned {
            AppLog.switchFlow.error("hand off \(entry.address.rawValue) not taken, bringing it back")
            progress[entry.address] = "Bringing it back…"
            released[entry.address] = nil
            if await link(entry.address, staleBond: false, pairTimeout: timings.pair) {
                adopt(entry.address)
            } else {
                chase(entry.address, kind: .reclaim)
            }
            progress[entry.address] = nil
            guard isCurrent(token) else { return cancelled }
        }
        if returned.isEmpty {
            return HandoffResult(summary: "Sent \(arrived.joined(separator: ", ")) to the other Mac.", succeeded: stuck.isEmpty)
        }
        let back = returned.map(\.name).joined(separator: ", ")
        return HandoffResult(summary: "The other Mac didn't take \(back). It stays on this Mac.", succeeded: false)
    }

    /// Reaches the other Mac in the background while this Mac is already
    /// trying the devices, and has it let go of any it turns out to hold.
    /// The pairing attempt in progress here then goes through.
    private func askLate(_ wanted: [DeviceEntry], token: Int) {
        lateFreed = []
        Task {
            let status = await peer.status(timeout: timings.peerDial)
            guard token == generation else { return }
            apply(status)
            let there = wanted.filter { status?.held.contains($0.address) == true && !connected.contains($0.address) }
            guard !there.isEmpty else { return }
            let freed = await peer.requestRelease(there.map(\.address), timeout: timings.releaseRequest) ?? []
            AppLog.switchFlow.info("the other Mac freed \(freed.map(\.rawValue).sorted().joined(separator: ","))")
            guard token == generation else { return }
            lateFreed.formUnion(freed)
            peerHeld.subtract(freed)
            for address in freed where chases[address] != nil {
                chases[address]?.returnToPeer = true
            }
        }
    }

    private var cancelled: HandoffResult {
        HandoffResult(summary: "Stopped.", succeeded: false)
    }

    /// Waits for the other Mac to say whether it connected the device.
    private func outcome(of address: DeviceAddress, token: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(timings.outcomeWait)
        while Date() < deadline, isCurrent(token) {
            if let result = outcomes[address] { return result }
            if peerHeld.contains(address) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return outcomes[address] ?? false
    }

    // MARK: Requests from the other Mac

    /// The other Mac wants these devices. Returns the ones whose link is down.
    func handleRelease(_ addresses: [DeviceAddress]) async -> Set<DeviceAddress> {
        AppLog.switchFlow.info("the other Mac asks for \(addresses.map(\.rawValue).joined(separator: ","))")
        for address in addresses {
            chases[address] = nil
        }
        let freed = await free(addresses)
        await announce()
        return freed
    }

    /// The other Mac freed these devices for this Mac.
    func handleTake(_ offered: [DeviceEntry]) {
        AppLog.switchFlow.info("the other Mac sends \(offered.map(label).joined(separator: " | "))")
        var added = false
        for entry in offered where !devices.contains(where: { $0.address == entry.address }) {
            devices.append(entry)
            added = true
        }
        if added {
            onDevicesChanged?(devices)
        }
        for entry in offered {
            released[entry.address] = nil
            failures[entry.address] = nil
            peerHeld.remove(entry.address)
            chase(entry.address, kind: .pushed)
        }
    }

    func handleOutcome(_ address: DeviceAddress, connected: Bool) {
        AppLog.switchFlow.info("the other Mac \(connected ? "connected" : "could not connect") \(address.rawValue)")
        outcomes[address] = connected
        if connected {
            peerHeld.insert(address)
        }
    }

    // MARK: Sleep and wake

    /// Runs with sleep held back. Devices connected here are freed so they
    /// are not left attached to a sleeping Mac, where only a power cycle
    /// gets them out. A Mac with no other Mac linked keeps its pairings.
    func prepareForSleep() async {
        asleep = true
        stopChaseLoop()
        generation += 1
        runTask?.cancel()
        await bluetooth.cancelOperations()
        progress = [:]
        isSwitching = false
        hint = nil
        let linked = await peer.isLinked()
        guard linked, releaseOnSleep() else {
            AppLog.switchFlow.info("sleep, keeping pairings (linked=\(linked))")
            return
        }
        var held: [DeviceEntry] = []
        for entry in devices where await bluetooth.isConnected(entry.address) {
            held.append(entry)
        }
        guard !held.isEmpty else {
            AppLog.switchFlow.info("sleep, nothing connected")
            return
        }
        let peerUp = await peer.ping(timeout: timings.peerPing)
        if !peerUp, wakesFromDevices() {
            AppLog.switchFlow.info("sleep, keeping pairings so the keyboard can wake this Mac")
            return
        }
        let freed = await free(held.map(\.address))
        freedForSleep = freed
        AppLog.switchFlow.info("sleep freed \(freed.map(\.rawValue).sorted().joined(separator: ",")) peerUp=\(peerUp)")
        if peerUp {
            _ = await peer.requestTake(held.filter { freed.contains($0.address) }, timeout: timings.peerPing)
        }
    }

    func didWake() async {
        guard asleep else { return }
        asleep = false
        AppLog.switchFlow.info("wake, freed before sleep: \(freedForSleep.map(\.rawValue).sorted().joined(separator: ","))")
        let mine = freedForSleep
        freedForSleep = []
        for address in mine {
            released[address] = nil
        }
        // Give Wi-Fi time to come back, so a Mac that is using the devices
        // can say so before this one reaches for them.
        try? await Task.sleep(nanoseconds: UInt64(timings.wakeDelay * 1_000_000_000))
        guard !asleep else { return }
        await refresh()
        guard userIsPresent() else {
            AppLog.switchFlow.info("wake without a user, leaving devices alone")
            return
        }
        startChaseLoop()
        let linked = await peer.isLinked()
        for entry in devices where !connected.contains(entry.address) && !peerHeld.contains(entry.address) {
            if mine.contains(entry.address) {
                chase(entry.address, kind: .reclaim)
            } else if linked, takeOnWake() {
                chase(entry.address, kind: .adopt)
            }
        }
    }

    // MARK: Radio

    private func handle(_ event: LinkEvent) async {
        switch event {
        case .connected(let address):
            guard devices.contains(where: { $0.address == address }) else { return }
            AppLog.switchFlow.info("link up \(address.rawValue)")
            adopt(address)
            await announce()
        case .disconnected(let address):
            guard connected.contains(address) else { return }
            AppLog.switchFlow.info("link down \(address.rawValue)")
            connected.remove(address)
            noteDropped(address)
            await announce()
        }
    }

    private func noteDropped(_ address: DeviceAddress) {
        if let at = released[address], Date().timeIntervalSince(at) < timings.releaseGrace {
            return
        }
        released[address] = nil
        guard !asleep, reconnectDropped(), progress[address] == nil else { return }
        chase(address, kind: .reclaim)
    }

    private func adopt(_ address: DeviceAddress) {
        connected.insert(address)
        peerHeld.remove(address)
        failures[address] = nil
        released[address] = nil
        if let chase = chases.removeValue(forKey: address) {
            finish(address, chase: chase, connected: true)
        }
        clearStaleHint()
    }

    /// Unpairs devices this Mac is giving up. Returns those whose link is down.
    private func free(_ addresses: [DeviceAddress]) async -> Set<DeviceAddress> {
        let now = Date()
        for address in addresses {
            released[address] = now
        }
        var freed: Set<DeviceAddress> = []
        await withTaskGroup(of: (DeviceAddress, Bool).self) { group in
            for address in addresses {
                group.addTask { [bluetooth, timings] in
                    (address, await bluetooth.release(address, timeout: timings.release))
                }
            }
            for await (address, down) in group {
                if down {
                    freed.insert(address)
                    connected.remove(address)
                } else {
                    released[address] = nil
                }
            }
        }
        return freed
    }

    /// One attempt to get a device onto this Mac. An existing pairing is
    /// opened. A pairing the device rejects is stale and is replaced. With
    /// no pairing, the device is paired by address.
    private func link(_ address: DeviceAddress, staleBond: Bool, pairTimeout: TimeInterval) async -> Bool {
        if await bluetooth.isConnected(address) { return true }
        if await bluetooth.isPaired(address) {
            if staleBond {
                _ = await bluetooth.release(address, timeout: timings.release)
            } else {
                switch await bluetooth.connect(address, timeout: timings.connect) {
                case .connected:
                    return true
                case .refused:
                    AppLog.switchFlow.info("link \(address.rawValue) pairing is stale, pairing again")
                    _ = await bluetooth.release(address, timeout: timings.release)
                case .absent:
                    // Off, asleep, or with another host. The pairing may
                    // still be good, so it stays.
                    return false
                }
            }
        }
        do {
            try await bluetooth.pair(address, timeout: pairTimeout)
        } catch {
            AppLog.switchFlow.info("link \(address.rawValue) pair: \(error.localizedDescription)")
            return false
        }
        // Pairing a keyboard or trackpad brings its link up without a
        // connect. Opening one too early drops it.
        let deadline = Date().addingTimeInterval(timings.settle)
        while Date() < deadline {
            if await bluetooth.isConnected(address) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await bluetooth.connect(address, timeout: timings.connect) == .connected
    }

    // MARK: Background attempts

    private func chase(_ address: DeviceAddress, kind: ChaseKind, returnToPeer: Bool = false) {
        guard !asleep else { return }
        if let existing = chases[address], existing.kind == .user || existing.kind == .pushed, kind != .user {
            return
        }
        let window: TimeInterval
        switch kind {
        case .user: window = timings.userWindow
        case .pushed: window = timings.pushedWindow
        case .reclaim: window = timings.reclaimWindow
        case .adopt: window = timings.adoptWindow
        }
        AppLog.switchFlow.info("chase \(address.rawValue) \(kind) for \(Int(window))s")
        chases[address] = Chase(kind: kind, deadline: Date().addingTimeInterval(window), returnToPeer: returnToPeer)
        startChaseLoop()
    }

    private func startChaseLoop() {
        guard chaseLoop == nil, !chases.isEmpty, !asleep else { return }
        chaseLoopID += 1
        let id = chaseLoopID
        chaseLoop = Task { [weak self] in
            await self?.runChases(id)
        }
    }

    private func stopChaseLoop() {
        chaseLoopID += 1
        chaseLoop?.cancel()
        chaseLoop = nil
    }

    private func runChases(_ id: Int) async {
        defer {
            if chaseLoopID == id { chaseLoop = nil }
        }
        while !chases.isEmpty, chaseLoopID == id, !asleep {
            for address in DeviceEntry.handoffOrder(devices).map(\.address) {
                guard let chase = chases[address], chaseLoopID == id, !asleep else { continue }
                await attempt(address, chase)
            }
            clearStaleHint()
            guard !chases.isEmpty, chaseLoopID == id else { break }
            try? await Task.sleep(nanoseconds: UInt64(timings.retryPause * 1_000_000_000))
        }
        clearStaleHint()
    }

    /// The wake hint is only for devices the user asked for.
    private func clearStaleHint() {
        if !chases.values.contains(where: { $0.kind == .user }) {
            hint = nil
        }
    }

    private func attempt(_ address: DeviceAddress, _ chase: Chase) async {
        var chase = chase
        if await bluetooth.isConnected(address) {
            adopt(address)
            return
        }
        guard Date() < chase.deadline else {
            expire(address, chase)
            return
        }
        guard Date() >= chase.nextAttempt else { return }
        let eager = chase.kind != .reclaim || Date().timeIntervalSince(chase.started) < timings.eagerWindow
        chase.nextAttempt = Date().addingTimeInterval(eager ? 0 : timings.slowPause)
        chases[address] = chase
        // A device this Mac only hopes to get is left alone while the other
        // Mac has it, and while that Mac might still be coming back online.
        if chase.kind == .reclaim || chase.kind == .adopt, await peer.isLinked() {
            let status = await peer.status(timeout: timings.peerPing)
            apply(status)
            guard chases[address] != nil else { return }
            if status == nil, chase.kind == .adopt {
                chase.peerSilent += 1
                chases[address] = chase
                if chase.peerSilent < 2 { return }
            }
        }
        let paired = await bluetooth.isPaired(address)
        if !paired {
            if chase.kind == .adopt, chase.pairAttempts >= timings.adoptAttempts {
                expire(address, chase)
                return
            }
            chase.pairAttempts += 1
            chases[address] = chase
        }
        let remaining = max(1, chase.deadline.timeIntervalSinceNow)
        let linked = await link(address, staleBond: false, pairTimeout: min(eager ? timings.pair : timings.slowPair, remaining))
        // The chase may have been ended while the radio was busy.
        guard chases[address] != nil else {
            if linked, released[address] != nil {
                _ = await bluetooth.release(address, timeout: timings.release)
            }
            return
        }
        if linked {
            adopt(address)
        }
    }

    private func expire(_ address: DeviceAddress, _ chase: Chase) {
        chases[address] = nil
        AppLog.switchFlow.info("chase \(address.rawValue) \(chase.kind) gave up")
        finish(address, chase: chase, connected: false)
    }

    private func finish(_ address: DeviceAddress, chase: Chase, connected: Bool) {
        let name = name(of: address)
        switch chase.kind {
        case .user:
            if connected {
                summary = "Connected \(name)."
                onFinished?(HandoffResult(summary: "Connected \(name).", succeeded: true))
            } else {
                failures[address] = "\(name) didn't answer. Turn it off and on, then try again."
                onFinished?(HandoffResult(summary: "Couldn't connect \(name).", succeeded: false))
                if chase.returnToPeer, let entry = devices.first(where: { $0.address == address }) {
                    Task { _ = await peer.requestTake([entry], timeout: timings.releaseRequest) }
                }
            }
        case .pushed:
            Task { await peer.notifyOutcome(address, connected: connected) }
        case .reclaim, .adopt:
            break
        }
        Task { await announce() }
    }

    /// Tells the other Mac what this one has, when that changed.
    private func announce() async {
        let status = localStatus
        guard status != lastStatusSent, await peer.isLinked() else { return }
        lastStatusSent = status
        await peer.notifyStatus(status)
    }

    // MARK: Text

    private func wakeHint(_ name: String, more: Int) -> String {
        let others = more > 0 ? " and \(more) more" : ""
        return "Press a key or click on \(name)\(others) to wake it."
    }

    private func name(of address: DeviceAddress) -> String {
        devices.first(where: { $0.address == address })?.name ?? address.rawValue
    }

    private func label(_ entry: DeviceEntry) -> String {
        "\(entry.name) \(entry.address.rawValue)"
    }

    static func takeSummary(moved: [String], waiting: [String], failed: [String]) -> String {
        var parts: [String] = []
        if !moved.isEmpty { parts.append("Connected \(moved.joined(separator: ", ")).") }
        if !waiting.isEmpty { parts.append("Waiting for \(waiting.joined(separator: ", ")).") }
        if !failed.isEmpty { parts.append("Couldn't bring \(failed.joined(separator: ", ")).") }
        return parts.isEmpty ? "No devices to bring over." : parts.joined(separator: " ")
    }
}

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
    private var runTask: Task<Void, Never>?
    private var returnWatch: Task<Void, Never>?
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
                statuses[address] = isConnected ? .success : .disconnected
                if previous == .success, !isConnected {
                    noteDropped(address)
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
        generation += 1
        runTask?.cancel()
        runTask = nil
        returnWatch?.cancel()
        prompt = .none
        activity = .idle
        summary = "Stopped."
        Task { await bluetooth.cancelOperations() }
    }

    func handleRemoteRelease(_ address: DeviceAddress, forget: Bool) async {
        try? await bluetooth.disconnect(address, timeout: timings.sleepDisconnect)
        await bluetooth.suppress(address, safetyTimeout: timings.suppressSafety)
        if forget {
            await bluetooth.forget(address)
            update(address) { entry in
                entry.bondMode = .single
            }
        }
    }

    func handleRemoteOwned(_ address: DeviceAddress, at date: Date = Date()) async {
        await bluetooth.stopSuppressing(address)
        update(address) { entry in
            entry.holder = .otherMac
            entry.holderSince = date
        }
        statuses[address] = .disconnected
    }

    func handleRemoteFailed(_ address: DeviceAddress) async {
        try? await bluetooth.disconnect(address, timeout: timings.sleepDisconnect)
        await bluetooth.forget(address)
        await bluetooth.suppress(address, safetyTimeout: timings.suppressSafety)
        update(address) { entry in
            entry.bondMode = .single
            entry.holder = .otherMac
            entry.holderSince = Date()
        }
    }

    func handleRemoteRollback(_ address: DeviceAddress) async {
        await bluetooth.stopSuppressing(address)
        let connected = await bluetooth.connect(address, timeout: timings.connect)
        update(address) { entry in
            entry.holder = connected ? .thisMac : entry.holder
            entry.holderSince = connected ? Date() : entry.holderSince
        }
        statuses[address] = connected ? .success : .failure("Couldn't reconnect \(name(of: address)).")
    }

    func handleWillSleep() async {
        let peerUp = await peer.ping(timeout: timings.peerPing)
        peerReachable = peerUp
        var released: [DeviceAddress] = []
        let now = Date()
        for entry in devices {
            guard await bluetooth.isConnected(entry.address) else { continue }
            try? await bluetooth.disconnect(entry.address, timeout: timings.sleepDisconnect)
            if peerUp {
                await bluetooth.suppress(entry.address, safetyTimeout: 30)
                update(entry.address) { device in
                    device.holder = .otherMac
                    device.holderSince = now
                }
                released.append(entry.address)
            } else {
                // Nobody can take them yet. Keep refusing so this Mac does
                // not reconnect them on the way into sleep.
                await bluetooth.suppress(entry.address, safetyTimeout: 12 * 60 * 60)
                update(entry.address) { device in
                    device.holder = .unknown
                    device.holderSince = now
                }
            }
            statuses[entry.address] = .disconnected
        }
        if peerUp, !released.isEmpty {
            await peer.notifySleeping(released)
        }
    }

    func handleRemoteSleeping(_ address: DeviceAddress) async {
        await bluetooth.stopSuppressing(address)
        if await bluetooth.connect(address, timeout: timings.connect) {
            _ = await adopted(entryFor(address), mode: bondMode(of: address), peerUp: true)
        }
    }

    func handleDidWake() async {
        for entry in devices {
            await bluetooth.stopSuppressing(entry.address)
        }
        let remote = await peer.exchangeClaims(claimStamps(), timeout: timings.claimTimeout)
        let answered = await peer.ping(timeout: timings.peerPing)
        peerReachable = !remote.isEmpty || answered
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
            summary = switchingBlockedMessage
            activity = .finished
            onFinished?(HandoffResult(devices: devices, summary: switchingBlockedMessage, succeeded: false))
            return
        }
        generation += 1
        let token = generation
        runTask?.cancel()
        returnWatch?.cancel()
        runTask = Task {
            let result = await body(token)
            guard token == self.generation, !Task.isCancelled else { return }
            summary = result.summary
            activity = .finished
            prompt = .none
            onFinished?(result)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }

    private func runUseHere(_ starting: [DeviceEntry], token: Int) async -> HandoffResult {
        activity = .working
        prompt = .none
        replace(starting)
        var todo: [DeviceEntry] = []
        for entry in DeviceEntry.handoffOrder(devices) {
            let connected = await bluetooth.isConnected(entry.address)
            let alreadyHere = entry.holder == .thisMac && connected
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
        if !peerUp {
            prompt = .peerAsleep
        }

        var failures: [String] = []
        var moved: [String] = []
        for entry in todo {
            if !isCurrent(token) { break }
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
        await bluetooth.stopSuppressing(entry.address)
        if entry.bondMode != .single {
            if peerUp {
                try? await peer.requestRelease(entry.address, forget: false, timeout: timings.releaseTimeout)
            }
            if await connectTwice(entry.address), isCurrent(token) {
                return await adopted(entry, mode: .multi, peerUp: peerUp)
            }
            guard isCurrent(token) else { return false }
            // A device that is here and still refuses the bond is the only
            // case where the old pairing should be thrown away.
            let seen = await bluetooth.waitUntilDiscovered(entry.address, timeout: timings.rangeProbe)
            guard isCurrent(token) else { return false }
            if seen {
                if peerUp {
                    await peer.notifyFailed(entry.address)
                }
            } else if await bluetooth.connect(entry.address, timeout: timings.connect) {
                return await adopted(entry, mode: .multi, peerUp: peerUp)
            } else {
                if peerUp {
                    await peer.requestRollback(entry.address, timeout: timings.releaseTimeout)
                }
                statuses[entry.address] = .failure("Couldn't reach \(entry.name). The existing pairing was kept.")
                prompt = peerUp ? .none : .peerAsleep
                return false
            }
        } else if peerUp {
            try? await peer.requestRelease(entry.address, forget: true, timeout: timings.releaseTimeout)
        }

        prompt = .pressKey(entry.name)
        if await discoverPairConnect(entry.address, timeout: timings.discoverFirst), isCurrent(token) {
            return await adopted(entry, mode: .single, peerUp: peerUp)
        }
        guard isCurrent(token) else { return false }
        prompt = .powerCycle(entry.name)
        if await discoverPairConnect(entry.address, timeout: timings.discoverSecond), isCurrent(token) {
            return await adopted(entry, mode: .single, peerUp: peerUp)
        }
        guard isCurrent(token) else { return false }
        if peerUp {
            await peer.requestRollback(entry.address, timeout: timings.releaseTimeout)
        }
        statuses[entry.address] = .failure("Couldn't bring \(entry.name) to this Mac.")
        prompt = peerUp ? .none : .peerAsleep
        return false
    }

    private func connectTwice(_ address: DeviceAddress) async -> Bool {
        if await bluetooth.connect(address, timeout: timings.connect) { return true }
        return await bluetooth.connect(address, timeout: timings.connect)
    }

    private func discoverPairConnect(_ address: DeviceAddress, timeout: TimeInterval) async -> Bool {
        guard await bluetooth.waitUntilDiscovered(address, timeout: timeout) else { return false }
        do {
            try await bluetooth.pair(address)
        } catch {
            AppLog.switchFlow.error("Pair \(address.rawValue) failed: \(error.localizedDescription)")
            return false
        }
        return await bluetooth.connect(address, timeout: timings.connect)
    }

    private func adopted(_ entry: DeviceEntry, mode: BondMode, peerUp: Bool) async -> Bool {
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
        return true
    }

    private func runHandOff(_ starting: [DeviceEntry], token: Int) async -> HandoffResult {
        activity = .working
        prompt = .none
        replace(starting)
        var moved: [String] = []
        for entry in DeviceEntry.handoffOrder(devices) {
            if !isCurrent(token) { break }
            let connected = await bluetooth.isConnected(entry.address)
            let alreadyGone = entry.holder == .otherMac && connected == false
            if alreadyGone {
                statuses[entry.address] = .disconnected
                continue
            }
            statuses[entry.address] = .working
            try? await bluetooth.disconnect(entry.address, timeout: timings.connect)
            await bluetooth.suppress(entry.address, safetyTimeout: timings.suppressSafety)
            if entry.bondMode != .multi {
                await bluetooth.forget(entry.address)
                await bluetooth.stopSuppressing(entry.address)
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
        returnWatch?.cancel()
        returnWatch = Task {
            let deadline = Date().addingTimeInterval(self.timings.wakeWatch)
            while Date() < deadline, !Task.isCancelled, self.activity != .working {
                if self.activity == .working { break }
                for entry in self.devices where entry.holder == .thisMac || entry.holder == .unknown {
                    if await self.bluetooth.isConnected(entry.address) {
                        self.statuses[entry.address] = .success
                        continue
                    }
                    if await self.bluetooth.connect(entry.address, timeout: self.timings.connect) {
                        self.statuses[entry.address] = .success
                        self.update(entry.address) { device in
                            device.holder = .thisMac
                            device.holderSince = Date()
                        }
                        continue
                    }
                    let slice = min(4, deadline.timeIntervalSinceNow)
                    guard slice > 0 else { break }
                    if await self.bluetooth.waitUntilDiscovered(entry.address, timeout: slice) {
                        try? await self.bluetooth.pair(entry.address)
                        if await self.bluetooth.connect(entry.address, timeout: self.timings.connect) {
                            self.statuses[entry.address] = .success
                            self.update(entry.address) { device in
                                device.holder = .thisMac
                                device.holderSince = Date()
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func noteDropped(_ address: DeviceAddress) {
        guard devices.first(where: { $0.address == address })?.holder == .thisMac else { return }
        guard activity != .working else { return }
        watchForReturn()
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

    private func replace(_ devices: [DeviceEntry]) {
        self.devices = devices
        onDevicesChanged?(devices)
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

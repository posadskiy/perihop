import AppKit
import Combine
import Foundation

/// What the menu says about the other Mac.
enum PeerLinkState: Equatable, Sendable {
    case notLinked
    case reachable(bluetooth: Bool)
    case unreachable
    case untrusted
    case outdated
}

@MainActor
final class AppModel: ObservableObject {
    let handoff: HandoffCoordinator
    let peer: PeerService

    @Published var config: DeviceConfig?
    @Published var menuVisible = false
    @Published var pairingCode: String
    @Published var peerHost: String
    @Published var pairingCodeError: String?
    @Published private(set) var isPairing = false
    @Published private(set) var trustMismatch = false
    @Published private(set) var offeredFingerprint = ""
    @Published private(set) var peerOutdated = false
    @Published private(set) var linkOverBluetooth = false
    @Published private(set) var batteries: [DeviceAddress: Int] = [:]
    @Published var takeShortcut = Shortcut.empty
    @Published var sendShortcut = Shortcut.empty
    @Published var toggleShortcut = Shortcut.empty
    @Published var dockDisplays: [String] = []
    @Published var releaseOnSleep: Bool { didSet { defaults.set(releaseOnSleep, forKey: "releaseOnSleep") } }
    @Published var takeOnWake: Bool { didSet { defaults.set(takeOnWake, forKey: "takeOnWake") } }
    @Published var reconnectDropped: Bool { didSet { defaults.set(reconnectDropped, forKey: "reconnectDropped") } }
    @Published var bluetoothLink: Bool {
        didSet {
            defaults.set(bluetoothLink, forKey: "bluetoothLink")
            restartPeer()
        }
    }

    #if DEBUG
    /// Page the menu is asked to show by `perihop://snapshot`.
    @Published var debugPage = "devices"
    #endif

    private let defaults = UserDefaults.standard
    private let bluetooth: BluetoothControlling
    private let notifier = HandoffNotifier()
    private let hotkeys = HotkeyCenter()
    private let displays = DisplayWatcher()
    private let power = PowerMonitor()
    private var usb: USBAccessoryWatcher?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var refreshLoop: Task<Void, Never>?
    /// Code this Mac is listening with before the link is confirmed.
    private var listeningCode = ""
    private var offeredCode = ""
    private(set) var poweringOff = false

    var devices: [DeviceEntry] { config?.devices ?? [] }

    var isLinked: Bool { !pairingCode.isEmpty }

    var peerState: PeerLinkState {
        guard isLinked else { return .notLinked }
        if trustMismatch { return .untrusted }
        if peerOutdated { return .outdated }
        return handoff.peerReachable ? .reachable(bluetooth: linkOverBluetooth) : .unreachable
    }

    var menuSymbol: String {
        if trustMismatch || peerOutdated { return "exclamationmark.triangle" }
        if handoff.isSwitching { return "arrow.left.arrow.right" }
        let here = devices.contains { handoff.connected.contains($0.address) }
        return here ? "keyboard.fill" : "keyboard"
    }

    init(bluetooth: BluetoothControlling = LiveBluetoothController()) {
        let peer = PeerService()
        let handoff = HandoffCoordinator(bluetooth: bluetooth, peer: peer)
        self.bluetooth = bluetooth
        self.peer = peer
        self.handoff = handoff
        defaults.register(defaults: [
            "releaseOnSleep": true,
            "takeOnWake": true,
            "reconnectDropped": true,
            "bluetoothLink": true,
        ])
        releaseOnSleep = defaults.bool(forKey: "releaseOnSleep")
        takeOnWake = defaults.bool(forKey: "takeOnWake")
        reconnectDropped = defaults.bool(forKey: "reconnectDropped")
        bluetoothLink = defaults.bool(forKey: "bluetoothLink")
        pairingCode = KeychainStore.readCode() ?? ""
        peerHost = defaults.string(forKey: "peerHost") ?? ""
        config = DeviceConfigStore.load()
        dockDisplays = defaults.stringArray(forKey: "dockDisplays") ?? []

        handoff.onDevicesChanged = { [weak self] devices in
            self?.save(devices)
        }
        handoff.onFinished = { [weak self] result in
            guard let self else { return }
            self.notifier.notify(body: result.summary, menuVisible: self.menuVisible)
        }
        handoff.switchingAllowed = { [weak self] in self?.trustMismatch != true }
        handoff.releaseOnSleep = { [weak self] in self?.releaseOnSleep ?? true }
        handoff.takeOnWake = { [weak self] in self?.takeOnWake ?? true }
        handoff.reconnectDropped = { [weak self] in self?.reconnectDropped ?? true }
        handoff.userIsPresent = { PowerMonitor.displayIsAwake() }
        handoff.wakesFromDevices = {
            PowerMonitor.lidIsClosed() && !DisplayWatcher.externalOnline().isEmpty
        }
        handoff.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        peer.linked = isLinked
        peer.onRequest = { [weak self] message in
            await self?.reply(to: message)
        }
        peer.onIdentity = { [weak self] fingerprint, trusted in
            Task { @MainActor in
                self?.offeredFingerprint = fingerprint
                self?.trustMismatch = !trusted
            }
        }
        if defaults.string(forKey: "pinnedFingerprint") == nil, pairingCode.count >= PairingCode.length {
            defaults.set(PeerCrypto.fingerprint(code: pairingCode), forKey: "pinnedFingerprint")
        }

        handoff.useDevices(devices)
        handoff.start()
        restartPeer()
        observePower()
        startTriggers()
        startRefreshing()
    }

    // MARK: Devices

    func saveDevices(_ devices: [DeviceEntry]) throws {
        let config = DeviceConfig(devices: devices)
        try DeviceConfigStore.save(config)
        self.config = config
        handoff.useDevices(devices)
    }

    func bringHere(_ devices: [DeviceEntry]) {
        handoff.useHere(devices: devices)
    }

    func sendAway(_ devices: [DeviceEntry]) {
        handoff.handOff(devices: devices)
    }

    func toggle(_ devices: [DeviceEntry]) {
        handoff.toggle(devices: devices)
    }

    /// Re-reads links, the other Mac, and battery levels.
    func refresh() async {
        await handoff.refresh()
        linkOverBluetooth = await peer.usesBluetooth()
        var levels: [DeviceAddress: Int] = [:]
        for device in devices where handoff.connected.contains(device.address) {
            if let percent = await bluetooth.batteryPercent(device.address) {
                levels[device.address] = percent
            }
        }
        batteries = levels
    }

    // MARK: Linking the Macs

    /// Shows a code and listens for the other Mac. The link is saved only after both sides talk.
    func prepareOffer() -> String {
        if !pairingCode.isEmpty { return pairingCode }
        if offeredCode.count < PairingCode.length {
            offeredCode = PairingCode.generate()
        }
        listen(offeredCode)
        return offeredCode
    }

    func refreshOffer() -> String {
        offeredCode = PairingCode.generate()
        pairingCodeError = nil
        listen(offeredCode)
        return offeredCode
    }

    func pair(code: String, host: String) async -> Bool {
        let normalized = PairingCode.normalize(code)
        guard normalized.count >= PairingCode.length else {
            pairingCodeError = "Enter the \(PairingCode.length)-character code from the other Mac."
            return false
        }
        isPairing = true
        defer { isPairing = false }
        pairingCodeError = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        listeningCode = normalized
        offeredCode = normalized
        await peer.activate(
            code: normalized,
            manualHost: trimmedHost.isEmpty ? nil : trimmedHost,
            pinnedFingerprint: nil,
            learnedHost: nil,
            bluetooth: bluetoothLink
        )
        for attempt in 1...3 {
            AppLog.peer.info("pair attempt \(attempt)")
            // Long enough for the Bluetooth link to come up when the
            // network keeps the Macs apart.
            if await peer.ping(timeout: 8) {
                do {
                    try persistLink(code: normalized, host: trimmedHost)
                    AppLog.peer.info("pair confirmed from this Mac")
                    await refresh()
                    return true
                } catch {
                    pairingCodeError = error.localizedDescription
                    return false
                }
            }
        }
        pairingCodeError = "Couldn't reach the other Mac. Leave its code on screen and try again."
        return false
    }

    func unpair() async {
        do {
            try KeychainStore.saveCode("")
            pairingCode = ""
            offeredCode = ""
            listeningCode = ""
            peerHost = ""
            peer.linked = false
            defaults.set("", forKey: "peerHost")
            defaults.removeObject(forKey: "pinnedFingerprint")
            defaults.removeObject(forKey: "learnedPeerHost")
            trustMismatch = false
            peerOutdated = false
            offeredFingerprint = ""
            pairingCodeError = nil
            await peer.activate(code: "", manualHost: nil, pinnedFingerprint: nil, learnedHost: nil)
            await handoff.refreshPeer()
        } catch {
            pairingCodeError = error.localizedDescription
        }
    }

    func updatePeerHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != peerHost else { return }
        peerHost = trimmed
        defaults.set(peerHost, forKey: "peerHost")
        restartPeer()
    }

    func trustOffered() {
        guard !offeredFingerprint.isEmpty else { return }
        defaults.set(offeredFingerprint, forKey: "pinnedFingerprint")
        trustMismatch = false
        restartPeer()
    }

    // MARK: Triggers

    func setDock(_ id: String, enabled: Bool) {
        if enabled {
            if !dockDisplays.contains(id) { dockDisplays.append(id) }
        } else {
            dockDisplays.removeAll { $0 == id }
        }
        defaults.set(dockDisplays, forKey: "dockDisplays")
    }

    func saveShortcuts() {
        store(takeShortcut, key: "hotkeyTake")
        store(sendShortcut, key: "hotkeySend")
        store(toggleShortcut, key: "hotkeyToggle")
        installHotkeys()
    }

    /// Frees the devices before this Mac shuts down, as it does before sleep.
    func prepareForPowerOff() async {
        await handoff.prepareForSleep()
    }

    // MARK: Requests from the other Mac

    private func reply(to message: PeerMessage) async -> PeerMessage? {
        if (message.version ?? 1) < PeerMessage.currentVersion {
            peerOutdated = true
        } else if peerOutdated {
            peerOutdated = false
        }
        switch message.type {
        case "ping":
            if pairingCode.isEmpty {
                acceptIncomingLink()
            }
            return message.reply(type: "pong")
        case "status":
            return statusReply(to: message, type: "status")
        case "release":
            let addresses = (message.addresses ?? []).map { DeviceAddress($0) }
            let freed = await handoff.handleRelease(addresses)
            return message.reply(type: "released", addresses: freed.map(\.rawValue).sorted())
        case "take":
            // A Mac that woke only to answer the network has nobody at it.
            guard isLinked, handoff.userIsPresent() else {
                return message.reply(type: "declined")
            }
            handoff.handleTake(message.devices ?? [])
            return message.reply(type: "taking")
        case "outcome":
            for raw in message.addresses ?? [] {
                handoff.handleOutcome(DeviceAddress(raw), connected: message.ok ?? false)
            }
            return message.reply(type: "ack")
        case "hello":
            if let host = message.host, !host.isEmpty, host != defaults.string(forKey: "learnedPeerHost") {
                defaults.set(host, forKey: "learnedPeerHost")
                await peer.learn(host: host)
            }
            if let status = message.status {
                handoff.notePeerStatus(status)
            }
            return message.reply(type: "ack")
        default:
            return nil
        }
    }

    private func statusReply(to message: PeerMessage, type: String) -> PeerMessage {
        let status = handoff.localStatus
        return message.reply(type: type, devices: status.devices, held: status.held.map(\.rawValue))
    }

    // MARK: Private

    private func save(_ devices: [DeviceEntry]) {
        let config = DeviceConfig(devices: devices)
        self.config = config
        do {
            try DeviceConfigStore.save(config)
        } catch {
            AppLog.config.error("Failed to save config: \(error.localizedDescription)")
        }
    }

    private func listen(_ code: String) {
        let normalized = PairingCode.normalize(code)
        listeningCode = normalized
        peer.start(
            code: normalized,
            manualHost: peerHost.isEmpty ? nil : peerHost,
            pinnedFingerprint: nil,
            learnedHost: nil,
            bluetooth: bluetoothLink
        )
    }

    /// The other Mac completed the handshake and pinged us, so this side is linked too.
    private func acceptIncomingLink() {
        guard pairingCode.isEmpty else { return }
        guard listeningCode.count >= PairingCode.length else { return }
        do {
            try persistLink(code: listeningCode, host: peerHost)
            AppLog.peer.info("pair confirmed from the other Mac")
        } catch {
            pairingCodeError = error.localizedDescription
        }
    }

    private func persistLink(code: String, host: String) throws {
        let normalized = PairingCode.normalize(code)
        try KeychainStore.saveCode(normalized)
        pairingCode = normalized
        offeredCode = normalized
        peer.linked = true
        peerHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(peerHost, forKey: "peerHost")
        defaults.set(PeerCrypto.fingerprint(code: normalized), forKey: "pinnedFingerprint")
        trustMismatch = false
        pairingCodeError = nil
    }

    private func restartPeer() {
        peer.start(
            code: pairingCode,
            manualHost: peerHost.isEmpty ? nil : peerHost,
            pinnedFingerprint: defaults.string(forKey: "pinnedFingerprint"),
            learnedHost: defaults.string(forKey: "learnedPeerHost"),
            bluetooth: bluetoothLink
        )
    }

    private func observePower() {
        power.budget = 6
        power.onWillSleep = { [weak self] in
            await self?.handoff.prepareForSleep()
        }
        power.onDidWake = { [weak self] in
            Task { @MainActor in
                await self?.handoff.didWake()
                await self?.refresh()
            }
        }
        power.start()
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.poweringOff = true }
            }
        )
    }

    private func startTriggers() {
        // A Magic accessory pairs itself when its cable is plugged in.
        let watcher = USBAccessoryWatcher { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.refresh()
            }
        }
        watcher.start()
        usb = watcher
        takeShortcut = load("hotkeyTake")
        sendShortcut = load("hotkeySend")
        toggleShortcut = load("hotkeyToggle")
        hotkeys.onAction = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                switch id {
                case 1: self.bringHere(self.devices)
                case 2: self.sendAway(self.devices)
                case 3: self.toggle(self.devices)
                default: break
                }
            }
        }
        installHotkeys()
        displays.onAdded = { [weak self] id in
            Task { @MainActor in
                guard let self, self.dockDisplays.contains(id) else { return }
                self.bringHere(self.devices)
            }
        }
        displays.start()
    }

    /// Link events keep the state current. This slow poll is the safety net
    /// for one that never arrives, and keeps the other Mac's side fresh.
    private func startRefreshing() {
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let pause: UInt64 = self?.menuVisible == true ? 5 : 30
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
            }
        }
    }

    /// `perihop://switch?direction=take|send|toggle&peripheral=name` moves
    /// devices. `perihop://show` opens the menu.
    func open(_ url: URL) {
        guard url.scheme == "perihop" else { return }
        AppLog.switchFlow.info("url \(url.absoluteString)")
        if url.host == "show" {
            StatusMenu.shared.open()
            return
        }
        #if DEBUG
        if url.host == "snapshot" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            debugPage = query.first(where: { $0.name == "page" })?.value ?? "devices"
            StatusMenu.shared.open()
            if let path = query.first(where: { $0.name == "path" })?.value {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    StatusMenu.shared.snapshot(to: URL(fileURLWithPath: path))
                }
            }
            return
        }
        #endif
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let direction = items.first(where: { $0.name == "direction" })?.value ?? "take"
        let filters = items.filter { $0.name == "peripheral" }.compactMap(\.value)
        let chosen = Self.matching(filters, in: devices)
        switch direction {
        case "send":
            sendAway(chosen)
        case "toggle":
            toggle(chosen)
        default:
            bringHere(chosen)
        }
    }

    nonisolated static func matching(_ filters: [String], in devices: [DeviceEntry]) -> [DeviceEntry] {
        guard !filters.isEmpty else { return devices }
        return devices.filter { device in
            filters.contains { filter in
                let needle = filter.lowercased()
                return device.address.rawValue == DeviceAddress(filter).rawValue
                    || device.name.lowercased().contains(needle)
            }
        }
    }

    private func load(_ key: String) -> Shortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .empty }
        return shortcut
    }

    private func store(_ shortcut: Shortcut, key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        }
    }

    private func installHotkeys() {
        hotkeys.install([
            (1, takeShortcut),
            (2, sendShortcut),
            (3, toggleShortcut),
        ])
    }
}

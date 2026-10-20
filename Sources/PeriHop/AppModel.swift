import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let handoff: HandoffCoordinator
    let peer: PeerService

    @Published var config: DeviceConfig?
    @Published var menuVisible = false
    @Published var pairingCode: String
    @Published var peerHost: String
    @Published var pairingCodeError: String?
    @Published private(set) var peerReachable = false
    @Published private(set) var trustMismatch = false
    @Published private(set) var offeredFingerprint = ""
    @Published private(set) var batteries: [DeviceAddress: Int] = [:]
    @Published var takeShortcut = Shortcut.empty
    @Published var sendShortcut = Shortcut.empty
    @Published var toggleShortcut = Shortcut.empty
    @Published var dockDisplays: [String] = []

    private let bluetooth: LiveBluetoothController
    private let notifier = HandoffNotifier()
    private let hotkeys = HotkeyCenter()
    private let displays = DisplayWatcher()
    private let urls = URLReceiver()
    private var usb: USBAccessoryWatcher?
    private var sleepObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    var menuSymbol: String {
        if pairingCode.isEmpty || trustMismatch { return "exclamationmark.triangle" }
        if handoff.activity == .working { return "arrow.left.arrow.right" }
        let connectedHere = config?.devices.contains { device in
            handoff.status(for: device.address) == .success
        } ?? false
        return connectedHere ? "keyboard.fill" : "keyboard"
    }

    init() {
        let bluetooth = LiveBluetoothController()
        let peer = PeerService()
        let handoff = HandoffCoordinator(bluetooth: bluetooth, peer: peer)
        self.bluetooth = bluetooth
        self.peer = peer
        self.handoff = handoff
        pairingCode = KeychainStore.readCode() ?? ""
        peerHost = UserDefaults.standard.string(forKey: "peerHost") ?? ""
        config = DeviceConfigStore.load()
        if let config {
            handoff.useDevices(config.devices)
        }

        handoff.onDevicesChanged = { [weak self] devices in
            self?.save(devices)
        }
        handoff.onFinished = { [weak self] result in
            guard let self else { return }
            self.notifier.notify(body: result.summary, menuVisible: self.menuVisible)
        }
        peer.onRequest = { [weak self] message in
            guard let self else { return nil }
            return await self.reply(to: message)
        }
        peer.onIdentity = { [weak self] fingerprint, trusted in
            Task { @MainActor in
                self?.offeredFingerprint = fingerprint
                self?.trustMismatch = !trusted
            }
        }
        handoff.switchingAllowed = { [weak self] in
            MainActor.assumeIsolated { self?.trustMismatch != true }
        }
        handoff.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        if UserDefaults.standard.string(forKey: "pinnedFingerprint") == nil, pairingCode.count >= 8 {
            UserDefaults.standard.set(PeerCrypto.fingerprint(code: pairingCode), forKey: "pinnedFingerprint")
        }
        restartPeer()
        observeSleep()
        let watcher = USBAccessoryWatcher { [weak self] in
            Task { @MainActor in
                await self?.noteCableAttach()
            }
        }
        watcher.start()
        usb = watcher
        loadShortcuts()
        dockDisplays = UserDefaults.standard.stringArray(forKey: "dockDisplays") ?? []
        hotkeys.onAction = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                switch id {
                case 1: self.bringHere(self.selectedDevices())
                case 2: self.sendAway(self.selectedDevices())
                case 3: self.toggle(self.selectedDevices())
                default: break
                }
            }
        }
        installHotkeys()
        displays.onAdded = { [weak self] id in
            Task { @MainActor in
                self?.displayConnected(id)
            }
        }
        displays.start()
        urls.onURL = { [weak self] url in
            Task { @MainActor in
                self?.open(url)
            }
        }
        urls.start()
    }

    func savePairing(code: String, host: String) {
        let normalized = PairingCode.normalize(code)
        if !normalized.isEmpty && normalized.count < 8 {
            pairingCodeError = "Use at least 8 characters, or generate a code."
            return
        }
        do {
            try KeychainStore.saveCode(normalized)
            pairingCode = normalized
            peerHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(peerHost, forKey: "peerHost")
            if normalized.count >= 8 {
                UserDefaults.standard.set(PeerCrypto.fingerprint(code: normalized), forKey: "pinnedFingerprint")
                trustMismatch = false
            }
            pairingCodeError = nil
            restartPeer()
        } catch {
            pairingCodeError = error.localizedDescription
        }
    }

    func refreshPeer() async {
        peerReachable = await peer.ping(timeout: 0.8)
        await refreshBatteries()
    }

    func bringHere(_ devices: [DeviceEntry]) {
        handoff.useHere(devices: devices)
    }

    func sendAway(_ devices: [DeviceEntry]) {
        handoff.handOff(devices: devices)
    }

    func toggle(_ devices: [DeviceEntry]) {
        let here = devices.filter { handoff.status(for: $0.address) == .success }
        if here.isEmpty {
            bringHere(devices)
        } else {
            sendAway(here)
        }
    }

    func trustOffered() {
        guard !offeredFingerprint.isEmpty else { return }
        UserDefaults.standard.set(offeredFingerprint, forKey: "pinnedFingerprint")
        trustMismatch = false
        restartPeer()
    }

    func setDock(_ id: String, enabled: Bool) {
        if enabled {
            if !dockDisplays.contains(id) { dockDisplays.append(id) }
        } else {
            dockDisplays.removeAll { $0 == id }
        }
        UserDefaults.standard.set(dockDisplays, forKey: "dockDisplays")
    }

    func saveShortcuts() {
        store(takeShortcut, key: "hotkeyTake")
        store(sendShortcut, key: "hotkeySend")
        store(toggleShortcut, key: "hotkeyToggle")
        installHotkeys()
    }

    func noteCableAttach() async {
        guard var config else { return }
        var changed = false
        for index in config.devices.indices {
            let address = config.devices[index].address
            let paired = await bluetooth.isPaired(address)
            let connected = await bluetooth.isConnected(address)
            guard paired || connected else { continue }
            config.devices[index].holder = .thisMac
            config.devices[index].holderSince = Date()
            if config.devices[index].bondMode == .unknown {
                config.devices[index].bondMode = .multi
            }
            handoff.noteConnected(address)
            changed = true
        }
        guard changed else { return }
        self.config = config
        handoff.useDevices(config.devices)
        try? DeviceConfigStore.save(config)
        notifier.notify(body: "An accessory was plugged in and paired to this Mac.", menuVisible: menuVisible)
    }

    private func reply(to message: PeerMessage) async -> PeerMessage? {
        switch message.type {
        case "ping":
            return message.reply(type: "pong")
        case "claims":
            let stamps = handoff.integrateClaims(message.stamps ?? [])
            return message.reply(type: "claimsAck", stamps: stamps)
        case "release":
            guard let raw = message.address else { return nil }
            let address = DeviceAddress(raw)
            await handoff.handleRemoteRelease(address, forget: message.forget ?? false)
            return message.reply(type: "released")
        case "owned":
            guard let raw = message.address else { return nil }
            let address = DeviceAddress(raw)
            await handoff.handleRemoteOwned(address)
            return message.reply(type: "ack")
        case "failed":
            guard let raw = message.address else { return nil }
            let address = DeviceAddress(raw)
            await handoff.handleRemoteFailed(address)
            return message.reply(type: "ack")
        case "rollback":
            guard let raw = message.address else { return nil }
            let address = DeviceAddress(raw)
            await handoff.handleRemoteRollback(address)
            return message.reply(type: "rolledBack")
        case "hello":
            if peerHost.isEmpty, let host = message.host, !host.isEmpty {
                UserDefaults.standard.set(host, forKey: "learnedPeerHost")
            }
            return message.reply(type: "ack")
        case "sleeping":
            for raw in message.addresses ?? [] {
                await handoff.handleRemoteSleeping(DeviceAddress(raw))
            }
            return message.reply(type: "ack")
        default:
            return nil
        }
    }

    private func save(_ devices: [DeviceEntry]) {
        var config = self.config ?? DeviceConfig(devices: devices)
        config.devices = devices
        self.config = config
        do {
            try DeviceConfigStore.save(config)
        } catch {
            AppLog.config.error("Failed to save config: \(error.localizedDescription)")
        }
    }

    private func restartPeer() {
        peer.start(
            code: pairingCode,
            manualHost: peerHost.isEmpty ? nil : peerHost,
            pinnedFingerprint: UserDefaults.standard.string(forKey: "pinnedFingerprint"),
            learnedHost: UserDefaults.standard.string(forKey: "learnedPeerHost")
        )
    }

    private func selectedDevices() -> [DeviceEntry] {
        config?.devices ?? []
    }

    private func open(_ url: URL) {
        guard url.scheme == "perihop" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let direction = items.first(where: { $0.name == "direction" })?.value ?? "take"
        let filters = items.filter { $0.name == "peripheral" }.compactMap(\.value)
        let devices = matching(filters)
        switch direction {
        case "send":
            sendAway(devices)
        case "toggle":
            toggle(devices)
        default:
            bringHere(devices)
        }
    }

    private func matching(_ filters: [String]) -> [DeviceEntry] {
        let devices = config?.devices ?? []
        guard !filters.isEmpty else { return devices }
        return devices.filter { device in
            filters.contains { filter in
                let needle = filter.lowercased()
                return device.name.lowercased() == needle
                    || device.address.rawValue.lowercased() == needle
                    || device.name.lowercased().contains(needle)
            }
        }
    }

    private func displayConnected(_ id: String) {
        guard dockDisplays.contains(id) else { return }
        bringHere(selectedDevices())
    }

    private func refreshBatteries() async {
        guard let config else { return }
        var next: [DeviceAddress: Int] = [:]
        for device in config.devices {
            if let percent = await bluetooth.batteryPercent(device.address) {
                next[device.address] = percent
            }
        }
        batteries = next
    }

    private func loadShortcuts() {
        takeShortcut = load("hotkeyTake")
        sendShortcut = load("hotkeySend")
        toggleShortcut = load("hotkeyToggle")
    }

    private func load(_ key: String) -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .empty }
        return shortcut
    }

    private func store(_ shortcut: Shortcut, key: String) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func installHotkeys() {
        hotkeys.install([
            (1, takeShortcut),
            (2, sendShortcut),
            (3, toggleShortcut),
        ])
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await self?.handoff.handleWillSleep()
                }
            }
        )
        sleepObservers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await self?.handoff.handleDidWake()
                }
            }
        )
    }
}

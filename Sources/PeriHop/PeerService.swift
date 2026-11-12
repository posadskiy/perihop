import CryptoKit
import Foundation
import Network

/// Moves messages to and from the other Mac. Bonjour or a manual address
/// finds it; the pairing code authenticates it.
final class PeerService: PeerLinking, @unchecked Sendable {
    typealias RequestHandler = @Sendable (PeerMessage) async -> PeerMessage?
    typealias IdentityHandler = @Sendable (_ fingerprint: String, _ trusted: Bool) -> Void

    private let engine = PeerEngine()
    private let lock = NSLock()
    private var requestHandler: RequestHandler?
    private var identityHandler: IdentityHandler?
    /// Start and stop calls apply in the order they were made.
    private var lastChange: Task<Void, Never>?
    private var confirmed = false

    /// True once both Macs have confirmed the pairing code. A code that is
    /// only on offer does not count: nothing is handed to a Mac that never
    /// answered.
    var linked: Bool {
        get { locked { confirmed } }
        set { locked { confirmed = newValue } }
    }

    var onRequest: RequestHandler? {
        get { locked { requestHandler } }
        set { locked { requestHandler = newValue } }
    }

    var onIdentity: IdentityHandler? {
        get { locked { identityHandler } }
        set { locked { identityHandler = newValue } }
    }

    func start(code: String, manualHost: String?, pinnedFingerprint: String? = nil, learnedHost: String? = nil, bluetooth: Bool = true) {
        enqueue {
            await self.configure(code: code, manualHost: manualHost, pinnedFingerprint: pinnedFingerprint, learnedHost: learnedHost, bluetooth: bluetooth)
        }
    }

    func activate(code: String, manualHost: String?, pinnedFingerprint: String? = nil, learnedHost: String? = nil, bluetooth: Bool = true) async {
        await enqueue {
            await self.configure(code: code, manualHost: manualHost, pinnedFingerprint: pinnedFingerprint, learnedHost: learnedHost, bluetooth: bluetooth)
        }.value
    }

    func stop() {
        enqueue { [engine] in await engine.stop() }
    }

    func isLinked() async -> Bool {
        guard linked else { return false }
        return await engine.isConfigured
    }

    func isConnected() async -> Bool {
        await engine.hasOpenLink
    }

    func ping(timeout: TimeInterval) async -> Bool {
        guard await engine.isConfigured else {
            await engine.noteReachable(false, detail: "no pairing code")
            return false
        }
        do {
            let reply = try await engine.request(PeerMessage(type: "ping"), timeout: timeout)
            let ok = reply.type == "pong"
            await engine.noteReachable(ok, detail: ok ? "" : "reply \(reply.type)")
            return ok
        } catch {
            await engine.noteReachable(false, detail: error.localizedDescription)
            return false
        }
    }

    func status(timeout: TimeInterval) async -> PeerStatus? {
        guard await engine.isConfigured else { return nil }
        do {
            // With no link open, the answer has to wait for a dial, which
            // over Bluetooth takes a few seconds.
            let patience = await engine.hasOpenLink ? timeout : max(timeout, PeerEngine.dialPatience)
            let reply = try await engine.request(PeerMessage(type: "status"), timeout: patience)
            await engine.noteReachable(true, detail: "")
            return reply.status ?? PeerStatus(held: [], devices: [])
        } catch {
            await engine.noteReachable(false, detail: error.localizedDescription)
            return nil
        }
    }

    func requestRelease(_ addresses: [DeviceAddress], timeout: TimeInterval) async -> Set<DeviceAddress>? {
        let message = PeerMessage(type: "release", addresses: addresses.map(\.rawValue))
        guard let reply = try? await engine.request(message, timeout: timeout), reply.type == "released" else {
            return nil
        }
        return Set((reply.addresses ?? []).map { DeviceAddress($0) })
    }

    func requestTake(_ devices: [DeviceEntry], timeout: TimeInterval) async -> Bool {
        guard !devices.isEmpty else { return true }
        let reply = try? await engine.request(PeerMessage(type: "take", devices: devices), timeout: timeout)
        return reply?.type == "taking"
    }

    func notifyOutcome(_ address: DeviceAddress, connected: Bool) async {
        let message = PeerMessage(type: "outcome", addresses: [address.rawValue], ok: connected)
        _ = try? await engine.request(message, timeout: 4)
    }

    func notifyStatus(_ status: PeerStatus) async {
        await engine.setStatus(status)
    }

    /// The other Mac's address, learned from its heartbeat.
    func learn(host: String) async {
        await engine.learn(host: host)
    }

    /// True while the link runs over Bluetooth instead of the network.
    func usesBluetooth() async -> Bool {
        await engine.usesBluetooth
    }

    private func configure(code: String, manualHost: String?, pinnedFingerprint: String?, learnedHost: String?, bluetooth: Bool) async {
        let normalized = PairingCode.normalize(code)
        guard normalized.count >= PairingCode.length else {
            AppLog.peer.info("peer stopped, pairing code is too short")
            await engine.stop()
            return
        }
        let key = PeerCrypto.deriveKey(code: normalized)
        let settings = PeerEngine.Settings(
            fingerprint: PeerCrypto.fingerprint(key: key),
            manualHost: manualHost,
            pinnedFingerprint: pinnedFingerprint,
            learnedHost: learnedHost,
            bluetooth: bluetooth
        )
        await engine.start(
            key: key,
            settings: settings,
            onRequest: { [weak self] message in
                await self?.onRequest?(message)
            },
            onIdentity: { [weak self] fingerprint, trusted in
                self?.onIdentity?(fingerprint, trusted)
            }
        )
    }

    @discardableResult
    private func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        locked {
            let previous = lastChange
            let task = Task {
                await previous?.value
                await work()
            }
            lastChange = task
            return task
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Keeps the links to the other Mac, matches replies to requests, and hands
/// incoming requests to `onRequest` one at a time, in arrival order.
///
/// Both Macs may dial at the same moment, so more than one link can be up.
/// Each stays usable: a reply goes back on the link its request came in on.
private actor PeerEngine {
    struct Settings: Equatable, Sendable {
        var fingerprint: String
        var manualHost: String?
        var pinnedFingerprint: String?
        var learnedHost: String?
        var bluetooth = true
    }

    private struct Pending {
        let continuation: CheckedContinuation<PeerMessage, Error>
        let timer: Task<Void, Never>
        var socket: PeerSocket?
    }

    private struct Inbound: Sendable {
        let message: PeerMessage
        let socket: PeerSocket
    }

    /// How long a request may wait for a link to come up from nothing.
    static let dialPatience: TimeInterval = 7

    private static let handshakeTimeout: TimeInterval = 6
    private static let heartbeatInterval: UInt64 = 15_000_000_000
    /// A link nobody has used for this long is closed when a newer one exists.
    private static let idleLimit: TimeInterval = 50
    /// The network gets this head start before Bluetooth is tried.
    private static let bluetoothDelay: TimeInterval = 1.2
    private static let bluetoothDial: TimeInterval = 5
    /// After a Bluetooth dial finds nobody, heartbeats skip it for this
    /// long, doubling up to the limit, so an absent Mac costs little radio.
    private static let bluetoothBackoff: TimeInterval = 30
    private static let bluetoothBackoffLimit: TimeInterval = 300

    private let listener = PeerListener()
    private let bluetooth = BluetoothLink()
    private var directory: PeerDirectory
    private var key: SymmetricKey?
    private var settings: Settings?
    private var limiter = HandshakeLimiter()
    private var browser: NWBrowser?
    /// Open links, oldest first. Requests go out on the newest.
    private var sockets: [PeerSocket] = []
    private var dialing: Task<PeerSocket, Error>?
    private var dialingUrgent = false
    private var heartbeat: Task<Void, Never>?
    private var inbox: AsyncStream<Inbound>.Continuation?
    private var pendings: [UUID: Pending] = [:]
    private var onRequest: PeerService.RequestHandler?
    private var onIdentity: PeerService.IdentityHandler?
    private var announcedPeers: [String: Bool] = [:]
    private var lastReachable: Bool?
    private var status: PeerStatus?
    private var bluetoothQuietUntil = Date.distantPast
    private var bluetoothBackoff = PeerEngine.bluetoothBackoff
    /// Bumped by every start and stop; links finishing under an older value are dropped.
    private var generation = 0

    init() {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        directory = PeerDirectory(localName: name, localInstance: UUID().uuidString)
    }

    var isConfigured: Bool { key != nil }

    var hasOpenLink: Bool { preferredSocket != nil }

    var usesBluetooth: Bool {
        preferredSocket?.stream is ChannelStream
    }

    /// The newest open link, with the network ahead of Bluetooth.
    private var preferredSocket: PeerSocket? {
        sockets.last { $0.isOpen && !($0.stream is ChannelStream) } ?? sockets.last(where: \.isOpen)
    }

    func start(
        key: SymmetricKey,
        settings: Settings,
        onRequest: @escaping PeerService.RequestHandler,
        onIdentity: @escaping PeerService.IdentityHandler
    ) async {
        self.onRequest = onRequest
        self.onIdentity = onIdentity
        if settings == self.settings, await listener.isListening {
            return
        }
        await teardown()
        self.key = key
        self.settings = settings
        directory.codeFingerprint = settings.fingerprint
        directory.pinnedFingerprint = settings.pinnedFingerprint
        AppLog.peer.info("listening name=\(directory.localName) manualHost=\(settings.manualHost ?? "-") bluetooth=\(settings.bluetooth)")
        startInbox()
        await listener.start(
            PeerListener.Advertisement(
                name: directory.localName,
                fingerprint: settings.fingerprint,
                instance: directory.localInstance
            )
        ) { [weak self] connection in
            Task { await self?.accept(NetworkStream(connection)) }
        }
        if settings.bluetooth {
            bluetooth.start(key: key) { [weak self] stream in
                Task { await self?.accept(stream) }
            }
        }
        startBrowser()
        startHeartbeat()
    }

    func stop() async {
        await teardown()
    }

    func noteReachable(_ ok: Bool, detail: String) {
        guard lastReachable != ok else { return }
        lastReachable = ok
        if ok {
            AppLog.peer.info("peer reachable")
        } else {
            AppLog.peer.error("peer unreachable: \(detail)")
        }
    }

    func setStatus(_ status: PeerStatus) async {
        self.status = status
        await sendHello()
    }

    func learn(host: String) {
        guard settings?.learnedHost != host else { return }
        settings?.learnedHost = host
    }

    /// `timeout` covers dialing, the handshake, and the reply.
    func request(_ message: PeerMessage, timeout: TimeInterval) async throws -> PeerMessage {
        let loud = PeerTraffic.notable(message)
        if loud {
            AppLog.peer.info("out \(PeerTraffic.line(message))")
        }
        do {
            let reply = try await exchange(message, timeout: timeout)
            if loud || PeerTraffic.notable(reply) {
                AppLog.peer.info("ack \(PeerTraffic.line(reply))")
            }
            return reply
        } catch {
            if loud {
                AppLog.peer.error("out \(message.type) failed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    // MARK: Requests

    private func exchange(_ message: PeerMessage, timeout: TimeInterval) async throws -> PeerMessage {
        let id = message.id
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.expire(id)
            }
            pendings[id] = Pending(continuation: continuation, timer: timer)
            Task { await self.deliver(message) }
        }
    }

    private func deliver(_ message: PeerMessage) async {
        do {
            // A heartbeat is not worth waking the Bluetooth radio for.
            let socket = try await connection(urgent: message.type != "hello")
            guard pendings[message.id] != nil else { return }
            pendings[message.id]?.socket = socket
            try await socket.send(message)
        } catch {
            resolve(message.id, with: .failure(error))
        }
    }

    /// A request that got no answer on a link that has gone quiet means the
    /// link is dead: the other Mac fell asleep with the socket open. Closing
    /// it makes the next request dial again instead of waiting on it.
    private func expire(_ id: UUID) {
        if let socket = pendings[id]?.socket, Date().timeIntervalSince(socket.lastHeard) > 3 {
            drop(socket, reason: "no answer")
        }
        resolve(id, with: .failure(PeerError.timeout))
    }

    private func resolve(_ id: UUID, with result: Result<PeerMessage, Error>) {
        guard let pending = pendings.removeValue(forKey: id) else { return }
        pending.timer.cancel()
        pending.continuation.resume(with: result)
    }

    /// A reply can only come back on the link the request went out on.
    private func failPendings(sentOn socket: PeerSocket) {
        let ids = pendings.filter { $0.value.socket === socket }.map(\.key)
        for id in ids {
            resolve(id, with: .failure(PeerError.closed))
        }
    }

    private func failAllPendings() {
        for id in Array(pendings.keys) {
            resolve(id, with: .failure(PeerError.closed))
        }
    }

    // MARK: Links

    /// Concurrent requests share one dial instead of racing each other.
    private func connection(urgent: Bool) async throws -> PeerSocket {
        if let socket = preferredSocket { return socket }
        // A dial a heartbeat started skips Bluetooth. A request that matters
        // does not settle for it.
        if let dialing, dialingUrgent || !urgent { return try await dialing.value }
        let task = Task { try await self.dial(urgent: urgent) }
        dialing = task
        dialingUrgent = urgent
        defer { if dialing == task { dialing = nil } }
        return try await task.value
    }

    /// Dials over the network and, a moment later, over Bluetooth. The first
    /// link to come up wins. The network is tried at the address typed in
    /// Settings, then where Bonjour sees the other Mac now, then at the
    /// address it last reported.
    private func dial(urgent: Bool) async throws -> PeerSocket {
        guard let key else { throw PeerError.noCode }
        let generation = self.generation
        let (results, feed) = AsyncStream.makeStream(of: Result<PeerSocket, Error>.self)
        var running = 1
        Task {
            do {
                feed.yield(.success(try await self.dialNetwork(key: key, generation: generation)))
            } catch {
                feed.yield(.failure(error))
            }
        }
        if settings?.bluetooth == true, urgent || Date() >= bluetoothQuietUntil {
            running += 1
            Task {
                do {
                    feed.yield(.success(try await self.dialBluetooth(key: key, generation: generation)))
                } catch {
                    feed.yield(.failure(error))
                }
            }
        }
        var lastError: Error = PeerError.unreachable
        for await result in results {
            running -= 1
            switch result {
            case .success(let socket):
                return socket
            case .failure(let error):
                if error as? PeerError != .closed { lastError = error }
            }
            if running == 0 { break }
        }
        throw lastError
    }

    private func dialNetwork(key: SymmetricKey, generation: Int) async throws -> PeerSocket {
        var lastError: Error = PeerError.unreachable
        for endpoint in endpoints() {
            guard generation == self.generation else { throw PeerError.closed }
            let stream = NetworkStream(NWConnection(to: endpoint, using: PeerEndpoint.parameters))
            do {
                return try await open(stream, key: key, generation: generation)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func dialBluetooth(key: SymmetricKey, generation: Int) async throws -> PeerSocket {
        try? await Task.sleep(nanoseconds: UInt64(Self.bluetoothDelay * 1_000_000_000))
        // The network answered during the head start.
        guard generation == self.generation, preferredSocket == nil else { throw PeerError.closed }
        do {
            let stream = try await bluetooth.connect(timeout: Self.bluetoothDial)
            let socket = try await open(stream, key: key, generation: generation)
            bluetoothBackoff = Self.bluetoothBackoff
            bluetoothQuietUntil = .distantPast
            return socket
        } catch {
            bluetoothQuietUntil = Date().addingTimeInterval(bluetoothBackoff)
            bluetoothBackoff = min(bluetoothBackoff * 2, Self.bluetoothBackoffLimit)
            throw error
        }
    }

    private func open(_ stream: PeerStream, key: SymmetricKey, generation: Int) async throws -> PeerSocket {
        let socket = PeerSocket(stream: stream, role: .client, key: key)
        let host = socket.remoteHost
        guard limiter.allow(host) else { throw PeerError.handshakeFailed }
        do {
            try await socket.open(timeout: Self.handshakeTimeout)
        } catch {
            if error as? PeerError == .handshakeFailed {
                limiter.recordFailure(host)
                AppLog.peer.error("outgoing link \(host) rejected the pairing code")
            }
            throw error
        }
        guard generation == self.generation else {
            socket.cancel()
            throw PeerError.closed
        }
        limiter.recordSuccess(host)
        AppLog.peer.info("link up outgoing \(host)")
        adopt(socket)
        return socket
    }

    private func accept(_ stream: PeerStream) async {
        guard let key else {
            stream.close()
            return
        }
        let generation = self.generation
        let socket = PeerSocket(stream: stream, role: .server, key: key)
        let host = socket.remoteHost
        guard limiter.allow(host) else {
            AppLog.peer.error("Ignoring \(host) after repeated handshake failures")
            stream.close()
            return
        }
        do {
            try await socket.open(timeout: Self.handshakeTimeout)
        } catch {
            // The server's answer already carries a MAC of the pairing code,
            // so a client that takes it and hangs up counts as a failure too.
            limiter.recordFailure(host)
            AppLog.peer.error("incoming link \(host) failed: \(error.localizedDescription)")
            return
        }
        guard generation == self.generation else {
            socket.cancel()
            return
        }
        limiter.recordSuccess(host)
        AppLog.peer.info("link up incoming \(host)")
        adopt(socket)
    }

    private func adopt(_ socket: PeerSocket) {
        sockets.removeAll { !$0.isOpen }
        sockets.append(socket)
        Task { await self.receiveLoop(socket) }
    }

    private func drop(_ socket: PeerSocket, reason: String) {
        guard sockets.contains(where: { $0 === socket }) else { return }
        AppLog.peer.info("link down \(socket.remoteHost): \(reason)")
        socket.cancel()
        sockets.removeAll { $0 === socket }
        failPendings(sentOn: socket)
    }

    private func receiveLoop(_ socket: PeerSocket) async {
        var reason = "closed"
        while true {
            let message: PeerMessage
            do {
                message = try await socket.receive()
            } catch {
                reason = error.localizedDescription
                break
            }
            if pendings[message.id] != nil {
                resolve(message.id, with: .success(message))
            } else {
                inbox?.yield(Inbound(message: message, socket: socket))
            }
        }
        drop(socket, reason: reason)
    }

    /// Closes links that a newer one has replaced and nobody talks on.
    private func pruneIdle() {
        guard let newest = preferredSocket else { return }
        for socket in sockets where socket !== newest {
            if Date().timeIntervalSince(socket.lastHeard) > Self.idleLimit {
                drop(socket, reason: "idle")
            }
        }
    }

    /// Runs requests from the other Mac in order, off the receive loop, so a
    /// slow handler never holds up replies to this Mac's own requests.
    private func startInbox() {
        guard inbox == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Inbound.self)
        inbox = continuation
        Task { [weak self] in
            for await inbound in stream {
                await self?.handle(inbound)
            }
        }
    }

    private func handle(_ inbound: Inbound) async {
        let message = inbound.message
        let notable = PeerTraffic.notable(message)
        if notable {
            AppLog.peer.info("in \(PeerTraffic.line(message))")
        }
        guard let reply = await onRequest?(message) else {
            if notable {
                AppLog.peer.error("in \(message.type) ignored")
            }
            return
        }
        if PeerTraffic.notable(reply) {
            AppLog.peer.info("out \(PeerTraffic.line(reply))")
        }
        do {
            try await inbound.socket.send(reply)
        } catch {
            AppLog.peer.error("reply \(reply.type) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Discovery

    private func endpoints() -> [NWEndpoint] {
        var result: [NWEndpoint] = []
        func add(_ endpoint: NWEndpoint?) {
            guard let endpoint, !result.contains(endpoint) else { return }
            result.append(endpoint)
        }
        add(settings?.manualHost.flatMap(PeerEndpoint.endpoint(from:)))
        add(directory.dialable)
        add(settings?.learnedHost.flatMap(PeerEndpoint.endpoint(from:)))
        return result
    }

    private func startBrowser() {
        let generation = self.generation
        let browser = NWBrowser(for: .bonjour(type: PeerListener.serviceType, domain: nil), using: PeerEndpoint.parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let sightings = results.compactMap(PeerSighting.init)
            Task { await self?.see(sightings, generation: generation) }
        }
        browser.start(queue: .global())
        self.browser = browser
    }

    private func see(_ sightings: [PeerSighting], generation: Int) {
        guard generation == self.generation else { return }
        directory.update(sightings)
        let trust = directory.trustByName
        for (name, trusted) in trust where announcedPeers[name] != trusted {
            AppLog.peer.info("peer \(name) trusted=\(trusted)")
        }
        for name in announcedPeers.keys where trust[name] == nil {
            AppLog.peer.info("peer \(name) gone")
        }
        announcedPeers = trust
        if let identity = directory.identity {
            onIdentity?(identity.fingerprint, identity.trusted)
        }
    }

    private func startHeartbeat() {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatInterval)
                guard !Task.isCancelled else { return }
                await self?.sendHello()
            }
        }
    }

    private func sendHello() async {
        guard key != nil else { return }
        pruneIdle()
        let message = PeerMessage(
            type: "hello",
            devices: status?.devices,
            held: status?.held.map(\.rawValue),
            host: LocalAddress.ipv4()
        )
        _ = try? await request(message, timeout: 3)
    }

    /// Clears the key first so nothing accepted during the awaits below uses it.
    private func teardown() async {
        generation += 1
        key = nil
        settings = nil
        heartbeat?.cancel()
        heartbeat = nil
        browser?.cancel()
        browser = nil
        directory.clear()
        announcedPeers = [:]
        dialing?.cancel()
        dialing = nil
        for socket in sockets {
            socket.cancel()
        }
        sockets = []
        failAllPendings()
        bluetooth.stop()
        await listener.stop()
    }
}

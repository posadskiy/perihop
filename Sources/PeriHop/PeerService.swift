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

    var onRequest: RequestHandler? {
        get { locked { requestHandler } }
        set { locked { requestHandler = newValue } }
    }

    var onIdentity: IdentityHandler? {
        get { locked { identityHandler } }
        set { locked { identityHandler = newValue } }
    }

    func start(code: String, manualHost: String?, pinnedFingerprint: String? = nil, learnedHost: String? = nil) {
        enqueue {
            await self.configure(code: code, manualHost: manualHost, pinnedFingerprint: pinnedFingerprint, learnedHost: learnedHost)
        }
    }

    func activate(code: String, manualHost: String?, pinnedFingerprint: String? = nil, learnedHost: String? = nil) async {
        await enqueue {
            await self.configure(code: code, manualHost: manualHost, pinnedFingerprint: pinnedFingerprint, learnedHost: learnedHost)
        }.value
    }

    func stop() {
        enqueue { [engine] in await engine.stop() }
    }

    func ping(timeout: TimeInterval) async -> Bool {
        guard await engine.isConfigured else {
            await engine.noteReachable(false, detail: "no pairing code")
            return false
        }
        do {
            let reply = try await engine.request(PeerMessage(id: UUID(), type: "ping"), timeout: timeout)
            let ok = reply.type == "pong"
            await engine.noteReachable(ok, detail: ok ? "" : "reply \(reply.type)")
            return ok
        } catch {
            await engine.noteReachable(false, detail: error.localizedDescription)
            return false
        }
    }

    func requestRelease(_ address: DeviceAddress, forget: Bool, timeout: TimeInterval) async throws {
        let reply = try await engine.request(
            PeerMessage(id: UUID(), type: "release", address: address.rawValue, forget: forget),
            timeout: timeout
        )
        guard reply.type == "released" else { throw PeerError.closed }
    }

    func notifyOwned(_ address: DeviceAddress) async {
        await notify("owned", address: address)
    }

    func notifyFailed(_ address: DeviceAddress) async {
        await notify("failed", address: address)
    }

    func requestRollback(_ address: DeviceAddress, timeout: TimeInterval) async {
        _ = try? await engine.request(
            PeerMessage(id: UUID(), type: "rollback", address: address.rawValue),
            timeout: timeout
        )
    }

    func notifySleeping(_ addresses: [DeviceAddress]) async {
        guard !addresses.isEmpty else { return }
        _ = try? await engine.request(
            PeerMessage(id: UUID(), type: "sleeping", addresses: addresses.map(\.rawValue)),
            timeout: 4
        )
    }

    func exchangeClaims(_ local: [ClaimStamp], timeout: TimeInterval) async -> [ClaimStamp] {
        guard await engine.isConfigured else { return [] }
        do {
            let reply = try await engine.request(
                PeerMessage(id: UUID(), type: "claims", stamps: local),
                timeout: timeout
            )
            return reply.stamps ?? []
        } catch {
            return []
        }
    }

    private func notify(_ type: String, address: DeviceAddress) async {
        _ = try? await engine.request(
            PeerMessage(id: UUID(), type: type, address: address.rawValue),
            timeout: 3
        )
    }

    private func configure(code: String, manualHost: String?, pinnedFingerprint: String?, learnedHost: String?) async {
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
            learnedHost: learnedHost
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

/// Holds at most one link to the other Mac, matches replies to requests, and
/// hands incoming requests to `onRequest` one at a time, in arrival order.
private actor PeerEngine {
    struct Settings: Equatable, Sendable {
        var fingerprint: String
        var manualHost: String?
        var pinnedFingerprint: String?
        var learnedHost: String?
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

    private static let handshakeTimeout: TimeInterval = 6
    private static let heartbeatInterval: UInt64 = 15_000_000_000

    private let listener = PeerListener()
    private var directory: PeerDirectory
    private var key: SymmetricKey?
    private var settings: Settings?
    private var limiter = HandshakeLimiter()
    private var browser: NWBrowser?
    private var socket: PeerSocket?
    private var dialing: Task<PeerSocket, Error>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var inbox: AsyncStream<Inbound>.Continuation?
    private var pendings: [UUID: Pending] = [:]
    private var onRequest: PeerService.RequestHandler?
    private var onIdentity: PeerService.IdentityHandler?
    private var announcedPeers: [String: Bool] = [:]
    private var lastReachable: Bool?
    /// Bumped by every start and stop; links finishing under an older value are dropped.
    private var generation = 0

    init() {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        directory = PeerDirectory(localName: name, localInstance: UUID().uuidString)
    }

    var isConfigured: Bool { key != nil }

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
        AppLog.peer.info("listening name=\(directory.localName) manualHost=\(settings.manualHost ?? "-") pinned=\(settings.pinnedFingerprint != nil)")
        startInbox()
        await listener.start(
            PeerListener.Advertisement(
                name: directory.localName,
                fingerprint: settings.fingerprint,
                instance: directory.localInstance
            )
        ) { [weak self] connection in
            Task { await self?.accept(connection) }
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
            if loud || message.type == "hello" {
                AppLog.peer.error("out \(message.type) \(message.address ?? "-") failed: \(error.localizedDescription)")
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
                self.resolve(id, with: .failure(PeerError.timeout))
            }
            pendings[id] = Pending(continuation: continuation, timer: timer)
            Task { await self.deliver(message) }
        }
    }

    private func deliver(_ message: PeerMessage) async {
        do {
            let socket = try await connection()
            guard pendings[message.id] != nil else { return }
            pendings[message.id]?.socket = socket
            try await socket.send(message)
        } catch {
            resolve(message.id, with: .failure(error))
        }
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

    /// Concurrent requests share one dial instead of racing to replace each other's link.
    private func connection() async throws -> PeerSocket {
        if let socket, socket.isOpen { return socket }
        if let dialing { return try await dialing.value }
        let task = Task { try await self.dial() }
        dialing = task
        defer { if dialing == task { dialing = nil } }
        return try await task.value
    }

    private func dial() async throws -> PeerSocket {
        guard let key else { throw PeerError.noCode }
        guard let endpoint = resolveEndpoint() else { throw PeerError.unreachable }
        let generation = self.generation
        let socket = PeerSocket(connection: NWConnection(to: endpoint, using: PeerEndpoint.parameters), role: .client, key: key)
        let host = socket.remoteHost
        guard limiter.allow(host) else { throw PeerError.handshakeFailed }
        do {
            try await socket.open(timeout: Self.handshakeTimeout)
        } catch {
            if error as? PeerError == .handshakeFailed {
                limiter.recordFailure(host)
            }
            AppLog.peer.error("outgoing link \(host) failed: \(error.localizedDescription)")
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

    private func accept(_ connection: NWConnection) async {
        guard let key else {
            connection.cancel()
            return
        }
        let generation = self.generation
        let socket = PeerSocket(connection: connection, role: .server, key: key)
        let host = socket.remoteHost
        guard limiter.allow(host) else {
            AppLog.peer.error("Ignoring \(host) after repeated handshake failures")
            connection.cancel()
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
        receiveTask?.cancel()
        if let old = self.socket, old !== socket {
            old.cancel()
            failPendings(sentOn: old)
        }
        self.socket = socket
        receiveTask = Task { await self.receiveLoop(socket) }
    }

    private func receiveLoop(_ socket: PeerSocket) async {
        while !Task.isCancelled {
            let message: PeerMessage
            do {
                message = try await socket.receive()
            } catch {
                AppLog.peer.info("link down: \(error.localizedDescription)")
                break
            }
            if pendings[message.id] != nil {
                resolve(message.id, with: .success(message))
            } else {
                inbox?.yield(Inbound(message: message, socket: socket))
            }
        }
        socket.cancel()
        failPendings(sentOn: socket)
        if self.socket === socket {
            self.socket = nil
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
                AppLog.peer.error("in \(message.type) \(message.address ?? "-") ignored")
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

    private func resolveEndpoint() -> NWEndpoint? {
        if let host = settings?.manualHost, let endpoint = PeerEndpoint.endpoint(from: host) {
            return endpoint
        }
        if let host = settings?.learnedHost, let endpoint = PeerEndpoint.endpoint(from: host) {
            return endpoint
        }
        return directory.dialable
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
        let message = PeerMessage(id: UUID(), type: "hello", host: LocalAddress.ipv4())
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
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel()
        socket = nil
        failAllPendings()
        await listener.stop()
    }
}

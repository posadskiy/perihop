import CryptoKit
import Foundation
import Network

/// Bonjour plus an optional manual address. Messages are sealed with a key
/// derived from the code the user typed on both Macs.
final class PeerService: PeerLinking, @unchecked Sendable {
    var onRequest: (@Sendable (PeerMessage) async -> PeerMessage?)?
    var onIdentity: (@Sendable (_ fingerprint: String, _ trusted: Bool) -> Void)?

    private let engine = PeerEngine()

    func start(code: String, manualHost: String?, pinnedFingerprint: String? = nil, learnedHost: String? = nil) {
        let normalized = PairingCode.normalize(code)
        guard normalized.count >= 8 else {
            stop()
            return
        }
        let key = PeerCrypto.deriveKey(code: normalized)
        let fingerprint = PeerCrypto.fingerprint(code: normalized)
        Task { [self] in
            await engine.start(
                key: key,
                manualHost: manualHost,
                fingerprint: fingerprint,
                pinnedFingerprint: pinnedFingerprint,
                learnedHost: learnedHost,
                onRequest: { [weak self] message in
                    await self?.onRequest?(message)
                },
                onIdentity: { [weak self] fingerprint, trusted in
                    self?.onIdentity?(fingerprint, trusted)
                }
            )
        }
    }

    func stop() {
        Task { await engine.stop() }
    }

    func ping(timeout: TimeInterval) async -> Bool {
        guard await engine.isConfigured else { return false }
        do {
            let reply = try await engine.request(PeerMessage(id: UUID(), type: "ping"), timeout: timeout)
            return reply.type == "pong"
        } catch {
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
}

private actor PeerEngine {
    private var key: SymmetricKey?
    private var manualHost: String?
    private var learnedHost: String?
    private var pinnedFingerprint: String?
    private var fingerprint = ""
    private var limiter = HandshakeLimiter()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var results: Set<NWBrowser.Result> = []
    private var socket: PeerSocket?
    private var receiveTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pendings: [UUID: PendingReply] = [:]
    private var onRequest: (@Sendable (PeerMessage) async -> PeerMessage?)?
    private var onIdentity: (@Sendable (String, Bool) -> Void)?
    private let localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    var isConfigured: Bool { key != nil }

    func start(
        key: SymmetricKey,
        manualHost: String?,
        fingerprint: String,
        pinnedFingerprint: String?,
        learnedHost: String?,
        onRequest: @escaping @Sendable (PeerMessage) async -> PeerMessage?,
        onIdentity: @escaping @Sendable (String, Bool) -> Void
    ) {
        stopListening()
        self.key = key
        self.manualHost = manualHost
        self.fingerprint = fingerprint
        self.pinnedFingerprint = pinnedFingerprint
        self.learnedHost = learnedHost
        self.onRequest = onRequest
        self.onIdentity = onIdentity
        let parameters = Self.parameters
        do {
            let listener = try NWListener(using: parameters, on: 47620)
            let record = NWTXTRecord(["fp": fingerprint])
            listener.service = NWListener.Service(name: localName, type: "_perihop._tcp", domain: nil, txtRecord: record)
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    AppLog.peer.error("Listener failed: \(error.localizedDescription)")
                }
            }
            listener.start(queue: .global())
            self.listener = listener
        } catch {
            AppLog.peer.error("Couldn't listen for the other Mac: \(error.localizedDescription)")
        }

        let browser = NWBrowser(for: .bonjour(type: "_perihop._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.setResults(results) }
        }
        browser.start(queue: .global())
        self.browser = browser
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self?.sendHello()
            }
        }
    }

    func stop() {
        stopListening()
        key = nil
    }

    func request(_ message: PeerMessage, timeout: TimeInterval) async throws -> PeerMessage {
        let socket = try await ensureConnection()
        let pending = PendingReply()
        pendings[message.id] = pending
        do {
            try await socket.send(message)
        } catch {
            pendings[message.id] = nil
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.attach(continuation)
            let id = message.id
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        pendings.removeValue(forKey: id)?.resume(with: .failure(PeerError.timeout))
    }

    private func accept(_ connection: NWConnection) async {
        guard let key else {
            connection.cancel()
            return
        }
        let host = Self.remoteHost(connection)
        guard limiter.allow(host) else {
            AppLog.peer.error("Ignoring \(host) after repeated handshake failures")
            connection.cancel()
            return
        }
        let socket = PeerSocket(connection: connection, role: .server, key: key)
        do {
            try await socket.open()
            limiter.recordSuccess(host)
        } catch let error as PeerError where error == .handshakeFailed {
            limiter.recordFailure(host)
            AppLog.peer.error("Incoming link failed: \(error.localizedDescription)")
            connection.cancel()
            return
        } catch {
            AppLog.peer.error("Incoming link failed: \(error.localizedDescription)")
            connection.cancel()
            return
        }
        adopt(socket)
    }

    private func ensureConnection() async throws -> PeerSocket {
        if let socket, socket.isOpen { return socket }
        guard let key else { throw PeerError.noCode }
        guard let endpoint = resolveEndpoint() else { throw PeerError.unreachable }
        let host = Self.remoteHost(endpoint)
        guard limiter.allow(host) else { throw PeerError.handshakeFailed }
        let connection = NWConnection(to: endpoint, using: Self.parameters)
        let socket = PeerSocket(connection: connection, role: .client, key: key)
        do {
            try await socket.open()
            limiter.recordSuccess(host)
        } catch let error as PeerError where error == .handshakeFailed {
            limiter.recordFailure(host)
            connection.cancel()
            throw error
        } catch {
            connection.cancel()
            throw error
        }
        adopt(socket)
        return socket
    }

    private func adopt(_ socket: PeerSocket) {
        receiveTask?.cancel()
        self.socket?.cancel()
        self.socket = socket
        receiveTask = Task { await self.receiveLoop(socket) }
    }

    private func receiveLoop(_ socket: PeerSocket) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                if let pending = pendings.removeValue(forKey: message.id) {
                    pending.resume(with: .success(message))
                    continue
                }
                if let reply = await onRequest?(message) {
                    try await socket.send(reply)
                }
            } catch {
                break
            }
        }
        if self.socket === socket {
            self.socket = nil
        }
    }

    private func resolveEndpoint() -> NWEndpoint? {
        if let manualHost, let endpoint = Self.endpoint(from: manualHost) {
            return endpoint
        }
        if let learnedHost, let endpoint = Self.endpoint(from: learnedHost) {
            return endpoint
        }
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint, name == localName {
                continue
            }
            return result.endpoint
        }
        return nil
    }

    private func setResults(_ results: Set<NWBrowser.Result>) {
        self.results = results
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint, name == localName {
                continue
            }
            guard case .bonjour(let record) = result.metadata else { continue }
            guard let advertised = record["fp"], !advertised.isEmpty else { continue }
            let trusted = pinnedFingerprint == nil || pinnedFingerprint == advertised
            onIdentity?(advertised, trusted)
        }
    }

    private func sendHello() async {
        guard key != nil else { return }
        let message = PeerMessage(id: UUID(), type: "hello", host: LocalAddress.ipv4())
        _ = try? await request(message, timeout: 3)
    }

    private func stopListening() {
        heartbeat?.cancel()
        heartbeat = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel()
        socket = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        results = []
        for pending in pendings.values {
            pending.resume(with: .failure(PeerError.closed))
        }
        pendings = [:]
    }

    private static func remoteHost(_ connection: NWConnection) -> String {
        remoteHost(connection.endpoint)
    }

    private static func remoteHost(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return "\(host)"
        }
        return String(describing: endpoint)
    }

    private static var parameters: NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func endpoint(from host: String) -> NWEndpoint? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        let portValue = parts.count == 2 ? UInt16(parts[1]) ?? 47620 : 47620
        guard let port = NWEndpoint.Port(rawValue: portValue) else { return nil }
        return .hostPort(host: NWEndpoint.Host(parts[0]), port: port)
    }
}

private final class PendingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PeerMessage, Error>?
    private var result: Result<PeerMessage, Error>?

    func attach(_ continuation: CheckedContinuation<PeerMessage, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let result {
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
        }
    }

    func resume(with result: Result<PeerMessage, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let continuation {
            self.continuation = nil
            self.result = result
            continuation.resume(with: result)
        } else if self.result == nil {
            self.result = result
        }
    }
}

private final class PeerSocket: @unchecked Sendable {
    enum Role { case client, server }

    let connection: NWConnection
    private let role: Role
    private let key: SymmetricKey
    private var sessionKey: SymmetricKey?
    private var buffer = Data()
    private let lock = NSLock()
    private(set) var isOpen = false

    init(connection: NWConnection, role: Role, key: SymmetricKey) {
        self.connection = connection
        self.role = role
        self.key = key
    }

    func open() async throws {
        try await waitReady()
        switch role {
        case .client:
            let hello = PeerCrypto.clientHello()
            try await sendRaw(hello.packet)
            let response = try await read(67)
            let finished = try PeerCrypto.clientFinish(serverPacket: response, clientNonce: hello.nonce, key: key)
            try await sendRaw(finished.packet)
            sessionKey = finished.session
        case .server:
            let hello = try await read(35)
            let response = try PeerCrypto.serverRespond(clientPacket: hello, key: key)
            try await sendRaw(response.packet)
            let auth = try await read(35)
            let clientNonce = hello.subdata(in: 3..<35)
            sessionKey = try PeerCrypto.serverFinish(
                clientAuth: auth,
                clientNonce: clientNonce,
                serverNonce: response.nonce,
                key: key
            )
        }
        isOpen = true
    }

    func cancel() {
        isOpen = false
        connection.cancel()
    }

    func send(_ message: PeerMessage) async throws {
        guard let sessionKey else { throw PeerError.closed }
        let sealed = try PeerCrypto.seal(message, key: sessionKey)
        var length = UInt32(sealed.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(sealed)
        try await sendRaw(packet)
    }

    func receive() async throws -> PeerMessage {
        guard let sessionKey else { throw PeerError.closed }
        let lengthData = try await read(4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 1_000_000 else { throw PeerError.closed }
        let sealed = try await read(Int(length))
        return try PeerCrypto.open(sealed, key: sessionKey)
    }

    private func waitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.run { continuation.resume() }
                case .failed(let error):
                    gate.run { continuation.resume(throwing: error) }
                case .cancelled:
                    gate.run { continuation.resume(throwing: PeerError.unreachable) }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func read(_ count: Int) async throws -> Data {
        while bufferedCount() < count {
            let chunk = try await receiveChunk()
            guard !chunk.isEmpty else { throw PeerError.closed }
            append(chunk)
        }
        return take(count)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private func bufferedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    private func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    private func take(_ count: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

enum LocalAddress {
    static func ipv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, let address = current.pointee.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard status == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let value = String(decoding: bytes, as: UTF8.self)
            if name == "en0" || name == "en1" { return value }
        }
        return nil
    }
}

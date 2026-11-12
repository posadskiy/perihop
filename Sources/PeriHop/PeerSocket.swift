import CryptoKit
import Foundation
import Network

/// A byte pipe to the other Mac: TCP on the network, or an L2CAP channel
/// over Bluetooth LE when the network is in the way.
protocol PeerStream: AnyObject, Sendable {
    /// Names the far end for the log and the handshake limiter.
    var label: String { get }
    /// Returns once bytes can flow.
    func open() async throws
    func write(_ data: Data) async throws
    /// At least one byte. Empty means the far end closed.
    func readChunk() async throws -> Data
    func close()
}

final class NetworkStream: PeerStream, @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    var label: String { PeerEndpoint.host(of: connection.endpoint) }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = FirstOnly()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.run { continuation.resume() }
                case .failed(let error):
                    gate.run { continuation.resume(throwing: error) }
                case .cancelled:
                    gate.run { continuation.resume(throwing: PeerError.unreachable) }
                case .waiting:
                    // Nothing is listening there. Waiting only helps a
                    // caller with no deadline, and every dial has one.
                    gate.run { continuation.resume(throwing: PeerError.unreachable) }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    func write(_ data: Data) async throws {
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

    func readChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }
}

/// One authenticated link to the other Mac. Runs the handshake, then frames
/// sealed messages as a 4-byte big-endian length and a ChaChaPoly box.
final class PeerSocket: @unchecked Sendable {
    enum Role: Sendable { case client, server }

    static let maxFrame = 1_000_000

    let stream: PeerStream
    private let role: Role
    private let key: SymmetricKey
    private let lock = NSLock()
    private var cipher: SessionCipher?
    private var buffer = Data()
    private var closed = false
    private var timedOut = false
    private var heardAt = Date()

    init(stream: PeerStream, role: Role, key: SymmetricKey) {
        self.stream = stream
        self.role = role
        self.key = key
    }

    convenience init(connection: NWConnection, role: Role, key: SymmetricKey) {
        self.init(stream: NetworkStream(connection), role: role, key: key)
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cipher != nil && !closed
    }

    var remoteHost: String { stream.label }

    /// When the far end was last heard from.
    var lastHeard: Date {
        lock.lock()
        defer { lock.unlock() }
        return heardAt
    }

    /// Connects and authenticates. A peer that stalls the handshake is cut off
    /// after `timeout` with `PeerError.timeout`. On any failure the stream
    /// is closed.
    func open(timeout: TimeInterval) async throws {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.expireHandshake()
        }
        defer { watchdog.cancel() }
        do {
            let session = try await handshake()
            guard install(session) else { throw PeerError.closed }
        } catch {
            cancel()
            throw handshakeExpired() ? PeerError.timeout : error
        }
    }

    private func install(_ session: SymmetricKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        cipher = SessionCipher(key: session)
        heardAt = Date()
        return true
    }

    private func handshakeExpired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func cancel() {
        lock.lock()
        closed = true
        lock.unlock()
        stream.close()
    }

    func send(_ message: PeerMessage) async throws {
        let frame = try withCipher { try $0.seal(message) }
        var length = UInt32(frame.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(frame)
        try await stream.write(packet)
    }

    func receive() async throws -> PeerMessage {
        guard isOpen else { throw PeerError.closed }
        let header = try await read(4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length < Self.maxFrame else { throw PeerError.closed }
        let frame = try await read(Int(length))
        let message = try withCipher { try $0.open(frame) }
        noteHeard()
        return message
    }

    private func noteHeard() {
        lock.lock()
        heardAt = Date()
        lock.unlock()
    }

    private func withCipher<T>(_ body: (inout SessionCipher) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, var current = cipher else { throw PeerError.closed }
        defer { cipher = current }
        return try body(&current)
    }

    private func handshake() async throws -> SymmetricKey {
        do {
            try await stream.open()
        } catch {
            markClosed()
            throw error
        }
        switch role {
        case .client:
            let hello = PeerCrypto.clientHello()
            try await stream.write(hello.packet)
            let response = try await read(PeerCrypto.serverResponseSize)
            let finished = try PeerCrypto.clientFinish(serverPacket: response, clientNonce: hello.nonce, key: key)
            try await stream.write(finished.packet)
            return finished.session
        case .server:
            let hello = try await read(PeerCrypto.clientHelloSize)
            let response = try PeerCrypto.serverRespond(clientPacket: hello, key: key)
            try await stream.write(response.packet)
            let auth = try await read(PeerCrypto.clientAuthSize)
            return try PeerCrypto.serverFinish(
                clientAuth: auth,
                clientNonce: PeerCrypto.clientNonce(hello: hello),
                serverNonce: response.nonce,
                key: key
            )
        }
    }

    private func expireHandshake() {
        lock.lock()
        timedOut = cipher == nil
        lock.unlock()
        if timedOut { stream.close() }
    }

    private func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// Only one reader runs at a time: the handshake, then the receive loop.
    private func read(_ count: Int) async throws -> Data {
        while bufferedCount() < count {
            let chunk = try await stream.readChunk()
            guard !chunk.isEmpty else { throw PeerError.closed }
            append(chunk)
        }
        return take(count)
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
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }
}

/// Seals and opens the frames of one link. Every frame carries a fresh random
/// ChaChaPoly nonce, so a nonce already seen on this link, including one this
/// side sent, is a replayed or reflected frame.
struct SessionCipher {
    enum Failure: Error, LocalizedError, Equatable {
        case replayed
        case exhausted

        var errorDescription: String? {
            switch self {
            case .replayed: return "A frame was replayed on the link."
            case .exhausted: return "The link used up its session key."
            }
        }
    }

    static let nonceSize = 12
    /// After this many frames the link is dropped and the next request
    /// handshakes a new session key.
    static let frameLimit = 100_000

    private let key: SymmetricKey
    private var nonces: Set<Data> = []

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(_ message: PeerMessage) throws -> Data {
        guard nonces.count < Self.frameLimit else { throw Failure.exhausted }
        let frame = try PeerCrypto.seal(message, key: key)
        nonces.insert(Data(frame.prefix(Self.nonceSize)))
        return frame
    }

    mutating func open(_ frame: Data) throws -> PeerMessage {
        guard nonces.count < Self.frameLimit else { throw Failure.exhausted }
        let nonce = Data(frame.prefix(Self.nonceSize))
        guard !nonces.contains(nonce) else { throw Failure.replayed }
        let message = try PeerCrypto.open(frame, key: key)
        nonces.insert(nonce)
        return message
    }
}

/// Five failed handshakes from one address inside a minute blocks that
/// address for fifteen minutes.
struct HandshakeLimiter: Equatable, Sendable {
    private struct Strike: Equatable {
        var times: [Date] = []
        var blockedUntil: Date?
    }

    private var strikes: [String: Strike] = [:]
    var limit = 5
    var window: TimeInterval = 60
    var block: TimeInterval = 15 * 60

    mutating func allow(_ host: String, now: Date = Date()) -> Bool {
        guard let until = strikes[host]?.blockedUntil else { return true }
        if until <= now {
            strikes[host]?.blockedUntil = nil
            return true
        }
        return false
    }

    mutating func recordFailure(_ host: String, now: Date = Date()) {
        prune(now)
        var strike = strikes[host] ?? Strike()
        strike.times = strike.times.filter { now.timeIntervalSince($0) < window }
        strike.times.append(now)
        if strike.times.count >= limit {
            strike.blockedUntil = now.addingTimeInterval(block)
            strike.times = []
        }
        strikes[host] = strike
    }

    mutating func recordSuccess(_ host: String) {
        strikes[host] = nil
    }

    /// Hosts with no recent strike and no active block are forgotten.
    private mutating func prune(_ now: Date) {
        strikes = strikes.filter { _, strike in
            if let until = strike.blockedUntil, until > now { return true }
            return strike.times.contains { now.timeIntervalSince($0) < window }
        }
    }
}

/// Runs the first of several racing completions and drops the rest.
final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

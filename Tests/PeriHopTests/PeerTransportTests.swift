import CryptoKit
import Foundation
import IOKit
import Network
import Testing
@testable import PeriHop

struct SessionCipherTests {
    @Test func replayedFrameIsRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = SessionCipher(key: key)
        var receiver = SessionCipher(key: key)
        let frame = try sender.seal(PeerMessage(id: UUID(), type: "release", address: "aa-bb-cc-dd-ee-ff"))

        #expect(try receiver.open(frame).type == "release")
        #expect(throws: SessionCipher.Failure.replayed) { try receiver.open(frame) }
    }

    @Test func ownFrameReflectedBackIsRejected() throws {
        var cipher = SessionCipher(key: SymmetricKey(size: .bits256))
        let frame = try cipher.seal(PeerMessage(id: UUID(), type: "ping"))

        #expect(throws: SessionCipher.Failure.replayed) { try cipher.open(frame) }
    }

    @Test func tamperedFrameDoesNotPoisonTheNonce() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = SessionCipher(key: key)
        var receiver = SessionCipher(key: key)
        let frame = try sender.seal(PeerMessage(id: UUID(), type: "ping"))
        var tampered = frame
        tampered[tampered.count - 1] ^= 0xff

        #expect(throws: (any Error).self) { try receiver.open(tampered) }
        #expect(try receiver.open(frame).type == "ping")
    }
}

struct PeerDirectoryTests {
    private let endpointA = NWEndpoint.hostPort(host: "10.0.0.2", port: 47620)
    private let endpointB = NWEndpoint.hostPort(host: "10.0.0.3", port: 47620)

    @Test func sameNamedMacIsNotMistakenForThisOne() {
        var directory = PeerDirectory(localName: "MacBook Pro", localInstance: "me")
        directory.codeFingerprint = "abcd"
        directory.update([
            PeerSighting(name: "MacBook Pro", fingerprint: "abcd", instance: "other", endpoint: endpointA),
            PeerSighting(name: "MacBook Pro (2)", fingerprint: "abcd", instance: "me", endpoint: endpointB),
        ])

        #expect(directory.peers.map(\.instance) == ["other"])
        #expect(directory.dialable == endpointA)
    }

    @Test func dialsThePeerWithThisCode() {
        var directory = PeerDirectory(localName: "Here", localInstance: "me")
        directory.codeFingerprint = "abcd"
        directory.update([
            PeerSighting(name: "A Stranger", fingerprint: "ffff", instance: "x", endpoint: endpointA),
            PeerSighting(name: "Desk", fingerprint: "abcd", instance: "y", endpoint: endpointB),
        ])

        #expect(directory.dialable == endpointB)
    }

    @Test func strangerCannotFlipATrustedPeer() {
        var directory = PeerDirectory(localName: "Here", localInstance: "me")
        directory.pinnedFingerprint = "abcd"
        directory.update([
            PeerSighting(name: "A Stranger", fingerprint: "ffff", instance: "x", endpoint: endpointA),
            PeerSighting(name: "Desk", fingerprint: "abcd", instance: "y", endpoint: endpointB),
        ])
        #expect(directory.identity?.fingerprint == "abcd")
        #expect(directory.identity?.trusted == true)

        directory.update([
            PeerSighting(name: "A Stranger", fingerprint: "ffff", instance: "x", endpoint: endpointA),
        ])
        #expect(directory.identity?.fingerprint == "ffff")
        #expect(directory.identity?.trusted == false)
    }

    @Test func manualHostsParseWithAndWithoutPorts() {
        #expect(PeerEndpoint.endpoint(from: " 10.0.0.2 ") == .hostPort(host: "10.0.0.2", port: 47620))
        #expect(PeerEndpoint.endpoint(from: "desk.local:5000") == .hostPort(host: "desk.local", port: 5000))
        #expect(PeerEndpoint.endpoint(from: "fe80::1") == .hostPort(host: "fe80::1", port: 47620))
        #expect(PeerEndpoint.endpoint(from: "[fe80::1]:5000") == .hostPort(host: "fe80::1", port: 5000))
        #expect(PeerEndpoint.endpoint(from: "  ") == nil)
    }
}

struct PeerSocketTests {
    @Test func silentClientIsCutOffDuringTheHandshake() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = AsyncStream<NWConnection>.makeStream()
        listener.newConnectionHandler = { accepted.continuation.yield($0) }
        let ready = AsyncStream<NWEndpoint.Port?>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield(listener.port) }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var readyIterator = ready.stream.makeAsyncIterator()
        let port = try #require(await readyIterator.next() ?? nil)

        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        client.start(queue: .global())
        defer { client.cancel() }

        var connections = accepted.stream.makeAsyncIterator()
        let incoming = try #require(await connections.next())
        let server = PeerSocket(connection: incoming, role: .server, key: SymmetricKey(size: .bits256))
        let started = Date()
        await #expect(throws: PeerError.timeout) {
            try await server.open(timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(!server.isOpen)
    }
}

@MainActor
struct ReconnectSuppressorTests {
    @Test func replacedLoopDoesNotOrphanItsReplacement() async throws {
        let suppressor = ReconnectSuppressor(interval: 0.01)
        let address = DeviceAddress("aa:bb:cc:dd:ee:ff")
        var closes = 0
        suppressor.start(address, safetyTimeout: 60) { nil }
        suppressor.start(address, safetyTimeout: 60) {
            closes += 1
            return kIOReturnSuccess
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(suppressor.isSuppressing(address))

        suppressor.stop(address)
        try await Task.sleep(nanoseconds: 30_000_000)
        let stoppedAt = closes
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(closes == stoppedAt)
        #expect(!suppressor.isSuppressing(address))
    }
}

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
        let frame = try sender.seal(PeerMessage(type: "release", addresses: ["aa-bb-cc-dd-ee-ff"]))

        #expect(try receiver.open(frame).type == "release")
        #expect(throws: SessionCipher.Failure.replayed) { try receiver.open(frame) }
    }

    @Test func ownFrameReflectedBackIsRejected() throws {
        var cipher = SessionCipher(key: SymmetricKey(size: .bits256))
        let frame = try cipher.seal(PeerMessage(type: "ping"))

        #expect(throws: SessionCipher.Failure.replayed) { try cipher.open(frame) }
    }

    @Test func tamperedFrameDoesNotPoisonTheNonce() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = SessionCipher(key: key)
        var receiver = SessionCipher(key: key)
        let frame = try sender.seal(PeerMessage(type: "ping"))
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

/// The Bluetooth link runs the same socket over a pair of streams. Two bound
/// stream pairs stand in for the L2CAP channel.
struct ChannelStreamTests {
    private func pipe() -> (near: ChannelStream, far: ChannelStream) {
        var nearIn: InputStream?, nearOut: OutputStream?, farIn: InputStream?, farOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &nearIn, outputStream: &farOut)
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &farIn, outputStream: &nearOut)
        return (
            ChannelStream(input: nearIn!, output: nearOut!, label: "near"),
            ChannelStream(input: farIn!, output: farOut!, label: "far")
        )
    }

    @Test func handshakeAndMessagesCrossAChannel() async throws {
        let key = SymmetricKey(size: .bits256)
        let (near, far) = pipe()
        let client = PeerSocket(stream: near, role: .client, key: key)
        let server = PeerSocket(stream: far, role: .server, key: key)

        async let accepted: Void = server.open(timeout: 5)
        try await client.open(timeout: 5)
        try await accepted

        // Larger than the stream buffer, so it has to go out in pieces.
        let devices = (0..<200).map { DeviceEntry(name: "Keyboard \($0)", address: DeviceAddress("aa-bb-cc-dd-ee-ff")) }
        try await client.send(PeerMessage(type: "take", devices: devices))
        let received = try await server.receive()
        #expect(received.type == "take")
        #expect(received.devices?.count == 200)

        try await server.send(received.reply(type: "taking"))
        #expect(try await client.receive().type == "taking")
        client.cancel()
        server.cancel()
    }

    @Test func wrongCodeIsRejectedOverAChannel() async throws {
        let (near, far) = pipe()
        let client = PeerSocket(stream: near, role: .client, key: SymmetricKey(size: .bits256))
        let server = PeerSocket(stream: far, role: .server, key: SymmetricKey(size: .bits256))

        async let accepted: Void = { try? await server.open(timeout: 2) }()
        await #expect(throws: PeerError.handshakeFailed) {
            try await client.open(timeout: 2)
        }
        await accepted
    }

    @Test func closingOneEndEndsAWaitingRead() async throws {
        let (near, far) = pipe()
        try await near.open()
        try await far.open()
        let reading = Task { try await far.readChunk() }
        try await Task.sleep(nanoseconds: 50_000_000)
        far.close()
        await #expect(throws: (any Error).self) { _ = try await reading.value }
    }

    @Test func serviceIdentifierDependsOnThePairingCode() {
        let first = BluetoothLink.identifier("perihop-ble-service", key: PeerCrypto.deriveKey(code: "ABCD"))
        let again = BluetoothLink.identifier("perihop-ble-service", key: PeerCrypto.deriveKey(code: "ABCD"))
        let other = BluetoothLink.identifier("perihop-ble-service", key: PeerCrypto.deriveKey(code: "ABCE"))
        #expect(first == again)
        #expect(first != other)
    }
}

struct PeerMessageTests {
    @Test func statusCarriesWhatTheOtherMacHolds() throws {
        let keyboard = DeviceEntry(name: "Magic Keyboard", address: "aa-bb-cc-dd-ee-ff")
        let request = PeerMessage(type: "status")
        let reply = request.reply(type: "status", devices: [keyboard], held: ["AA:BB:CC:DD:EE:FF"])
        let decoded = try PeerMessage.decoder.decode(PeerMessage.self, from: PeerMessage.encoder.encode(reply))

        #expect(decoded.id == request.id)
        #expect(decoded.version == PeerMessage.currentVersion)
        #expect(decoded.status == PeerStatus(held: [keyboard.address], devices: [keyboard]))
    }

    @Test func messageFromAnOlderVersionStillDecodes() throws {
        let old = #"{"id":"6F1C1A0E-3C54-4C0B-9C0B-0E5A7B0B3D11","type":"claims","stamps":[]}"#
        let decoded = try PeerMessage.decoder.decode(PeerMessage.self, from: Data(old.utf8))
        #expect(decoded.version == nil)
        #expect(decoded.status == nil)
    }
}

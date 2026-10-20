import CryptoKit
import Foundation
import Testing
@testable import PeriHop

struct PeerCryptoTests {
    @Test func bothSidesDeriveTheSameSessionKey() throws {
        let code = "KEYBOARD1234"
        let key = PeerCrypto.deriveKey(code: code)
        let hello = PeerCrypto.clientHello()
        let server = try PeerCrypto.serverRespond(clientPacket: hello.packet, key: key)
        let client = try PeerCrypto.clientFinish(serverPacket: server.packet, clientNonce: hello.nonce, key: key)
        let clientNonce = hello.packet.subdata(in: 3..<35)
        let serverKey = try PeerCrypto.serverFinish(
            clientAuth: client.packet,
            clientNonce: clientNonce,
            serverNonce: server.nonce,
            key: key
        )

        let message = PeerMessage(id: UUID(), type: "ping")
        let sealed = try PeerCrypto.seal(message, key: client.session)
        let opened = try PeerCrypto.open(sealed, key: serverKey)
        #expect(opened == message)
    }

    @Test func wrongCodeFailsTheHandshake() throws {
        let hello = PeerCrypto.clientHello()
        let server = try PeerCrypto.serverRespond(clientPacket: hello.packet, key: PeerCrypto.deriveKey(code: "AAAAAAAA"))
        #expect(throws: PeerError.handshakeFailed) {
            try PeerCrypto.clientFinish(
                serverPacket: server.packet,
                clientNonce: hello.nonce,
                key: PeerCrypto.deriveKey(code: "BBBBBBBB")
            )
        }
    }

    @Test func fiveFailedHandshakesBlockTheAddress() {
        var limiter = HandshakeLimiter()
        let now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<4 {
            limiter.recordFailure("10.0.0.2", now: now)
            let allowed = limiter.allow("10.0.0.2", now: now)
            #expect(allowed)
        }
        limiter.recordFailure("10.0.0.2", now: now)
        let blocked = limiter.allow("10.0.0.2", now: now)
        let later = limiter.allow("10.0.0.2", now: now.addingTimeInterval(15 * 60))
        #expect(blocked == false)
        #expect(later)
    }
}

struct HandoffClaimTests {
    @Test func newerRemoteClaimWins() {
        var local = DeviceEntry(name: "Magic Keyboard", address: "aa-bb-cc-dd-ee-ff", holder: .thisMac)
        local.holderSince = Date(timeIntervalSince1970: 10)
        let remote = [
            ClaimStamp(address: "AA:BB:CC:DD:EE:FF", holderSince: Date(timeIntervalSince1970: 30), mine: true),
        ]

        let updated = HandoffClaims.apply(local: [local], remote: remote)

        #expect(updated[0].holder == .otherMac)
        #expect(updated[0].holderSince == Date(timeIntervalSince1970: 30))
    }

    @Test func olderRemoteClaimDoesNotSteal() {
        var local = DeviceEntry(name: "Magic Keyboard", address: "aa-bb-cc-dd-ee-ff", holder: .thisMac)
        local.holderSince = Date(timeIntervalSince1970: 40)
        let remote = [
            ClaimStamp(address: local.address.rawValue, holderSince: Date(timeIntervalSince1970: 10), mine: true),
        ]

        let updated = HandoffClaims.apply(local: [local], remote: remote)

        #expect(updated[0].holder == .thisMac)
    }
}

struct DeviceAddressNormalizationTests {
    @Test func colonAndHyphenFormsMatch() {
        #expect(DeviceAddress("AA:BB:CC:DD:EE:FF") == DeviceAddress("aa-bb-cc-dd-ee-ff"))
    }
}

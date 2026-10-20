import CommonCrypto
import CryptoKit
import Foundation

enum PairingCode {
    static let length = 4
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in
            alphabet[Int(generator.next(upperBound: UInt(alphabet.count)))]
        })
    }

    static func normalize(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
    }
}

/// Pairing-code key derivation and the three-packet handshake that turns it
/// into a per-link session key. Packets on the wire:
///
///     client -> server  "P1C" | clientNonce(32)
///     server -> client  "P1S" | serverNonce(32) | HMAC(key, "perihop-server" | nonces)
///     client -> server  "P1A" | HMAC(key, "perihop-client" | nonces)
enum PeerCrypto {
    static let nonceSize = 32
    static let macSize = 32
    private static let magicSize = 3
    static let clientHelloSize = magicSize + nonceSize
    static let serverResponseSize = magicSize + nonceSize + macSize
    static let clientAuthSize = magicSize + macSize

    private static let salt = Data("perihop.peer.v1".utf8)
    private static let rounds: UInt32 = 200_000

    static func deriveKey(code: String) -> SymmetricKey {
        let password = Data(code.utf8)
        var derived = Data(count: 32)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        rounds,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        // PBKDF2 only fails on invalid parameters, and these are constants.
        // A silent fallback would derive a key the other Mac can never match.
        precondition(status == kCCSuccess, "PBKDF2 rejected constant parameters (\(status))")
        return SymmetricKey(data: derived)
    }

    static func fingerprint(code: String) -> String {
        fingerprint(key: deriveKey(code: code))
    }

    static func fingerprint(key: SymmetricKey) -> String {
        let bytes = key.withUnsafeBytes { Data($0) }
        return SHA256.hash(data: bytes).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func sessionKey(master: SymmetricKey, clientNonce: Data, serverNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: clientNonce + serverNonce,
            info: Data("perihop-session".utf8),
            outputByteCount: 32
        )
    }

    static func clientHello() -> (nonce: Data, packet: Data) {
        let nonce = randomNonce()
        return (nonce, Data("P1C".utf8) + nonce)
    }

    /// The client nonce carried by a hello packet.
    static func clientNonce(hello packet: Data) throws -> Data {
        try field(packet, magic: "P1C", size: clientHelloSize)
    }

    static func serverRespond(clientPacket: Data, key: SymmetricKey) throws -> (nonce: Data, packet: Data) {
        let clientNonce = try clientNonce(hello: clientPacket)
        let nonce = randomNonce()
        let mac = hmac(key: key, label: "perihop-server", clientNonce: clientNonce, serverNonce: nonce)
        return (nonce, Data("P1S".utf8) + nonce + mac)
    }

    static func clientFinish(serverPacket: Data, clientNonce: Data, key: SymmetricKey) throws -> (session: SymmetricKey, packet: Data) {
        let body = try field(serverPacket, magic: "P1S", size: serverResponseSize)
        let serverNonce = body.prefix(nonceSize)
        let mac = body.suffix(macSize)
        try verify(mac, key: key, label: "perihop-server", clientNonce: clientNonce, serverNonce: serverNonce)
        let auth = hmac(key: key, label: "perihop-client", clientNonce: clientNonce, serverNonce: serverNonce)
        let session = sessionKey(master: key, clientNonce: clientNonce, serverNonce: serverNonce)
        return (session, Data("P1A".utf8) + auth)
    }

    static func serverFinish(clientAuth: Data, clientNonce: Data, serverNonce: Data, key: SymmetricKey) throws -> SymmetricKey {
        let mac = try field(clientAuth, magic: "P1A", size: clientAuthSize)
        try verify(mac, key: key, label: "perihop-client", clientNonce: clientNonce, serverNonce: serverNonce)
        return sessionKey(master: key, clientNonce: clientNonce, serverNonce: serverNonce)
    }

    static func seal(_ message: PeerMessage, key: SymmetricKey) throws -> Data {
        let plain = try PeerMessage.encoder.encode(message)
        return try ChaChaPoly.seal(plain, using: key).combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> PeerMessage {
        let box = try ChaChaPoly.SealedBox(combined: data)
        let plain = try ChaChaPoly.open(box, using: key)
        return try PeerMessage.decoder.decode(PeerMessage.self, from: plain)
    }

    private static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private static func field(_ packet: Data, magic: String, size: Int) throws -> Data {
        guard packet.count == size, packet.prefix(magicSize) == Data(magic.utf8) else {
            throw PeerError.handshakeFailed
        }
        return Data(packet.dropFirst(magicSize))
    }

    private static func material(label: String, clientNonce: Data, serverNonce: Data) -> Data {
        Data(label.utf8) + clientNonce + serverNonce
    }

    private static func hmac(key: SymmetricKey, label: String, clientNonce: Data, serverNonce: Data) -> Data {
        let data = material(label: label, clientNonce: clientNonce, serverNonce: serverNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    /// Constant-time MAC check.
    private static func verify(_ mac: Data, key: SymmetricKey, label: String, clientNonce: Data, serverNonce: Data) throws {
        let data = material(label: label, clientNonce: clientNonce, serverNonce: serverNonce)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key) else {
            throw PeerError.handshakeFailed
        }
    }
}

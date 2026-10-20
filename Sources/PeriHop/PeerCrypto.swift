import CommonCrypto
import CryptoKit
import Foundation
import Security

enum PairingCode {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generate() -> String {
        String((0..<12).map { _ in alphabet.randomElement()! })
    }

    static func normalize(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isLetter || $0.isNumber })
    }
}

enum PeerCrypto {
    static func deriveKey(code: String) -> SymmetricKey {
        let password = Data(code.utf8)
        let salt = Data("perihop.peer.v1".utf8)
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
                        200_000,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        if status != kCCSuccess {
            var digest = Data(SHA256.hash(data: salt + password))
            for _ in 0..<50_000 {
                digest = Data(SHA256.hash(data: digest))
            }
            return SymmetricKey(data: digest)
        }
        return SymmetricKey(data: derived)
    }

    static func fingerprint(code: String) -> String {
        let key = deriveKey(code: code)
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

    static func serverRespond(clientPacket: Data, key: SymmetricKey) throws -> (nonce: Data, packet: Data) {
        let clientNonce = try nonce(from: clientPacket, magic: "P1C")
        let nonce = randomNonce()
        let mac = hmac(key: key, label: "perihop-server", clientNonce: clientNonce, serverNonce: nonce)
        return (nonce, Data("P1S".utf8) + nonce + mac)
    }

    static func clientFinish(serverPacket: Data, clientNonce: Data, key: SymmetricKey) throws -> (session: SymmetricKey, packet: Data) {
        guard serverPacket.count == 3 + 32 + 32, serverPacket.prefix(3) == Data("P1S".utf8) else {
            throw PeerError.handshakeFailed
        }
        let serverNonce = serverPacket.subdata(in: 3..<35)
        let mac = serverPacket.subdata(in: 35..<67)
        let expected = hmac(key: key, label: "perihop-server", clientNonce: clientNonce, serverNonce: serverNonce)
        guard mac == expected else { throw PeerError.handshakeFailed }
        let auth = hmac(key: key, label: "perihop-client", clientNonce: clientNonce, serverNonce: serverNonce)
        let session = sessionKey(master: key, clientNonce: clientNonce, serverNonce: serverNonce)
        return (session, Data("P1A".utf8) + auth)
    }

    static func serverFinish(clientAuth: Data, clientNonce: Data, serverNonce: Data, key: SymmetricKey) throws -> SymmetricKey {
        guard clientAuth.count == 3 + 32, clientAuth.prefix(3) == Data("P1A".utf8) else {
            throw PeerError.handshakeFailed
        }
        let mac = clientAuth.subdata(in: 3..<35)
        let expected = hmac(key: key, label: "perihop-client", clientNonce: clientNonce, serverNonce: serverNonce)
        guard mac == expected else { throw PeerError.handshakeFailed }
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
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    private static func nonce(from packet: Data, magic: String) throws -> Data {
        guard packet.count == 3 + 32, packet.prefix(3) == Data(magic.utf8) else {
            throw PeerError.handshakeFailed
        }
        return packet.subdata(in: 3..<35)
    }

    private static func hmac(key: SymmetricKey, label: String, clientNonce: Data, serverNonce: Data) -> Data {
        var material = Data(label.utf8)
        material.append(clientNonce)
        material.append(serverNonce)
        return Data(HMAC<SHA256>.authenticationCode(for: material, using: key))
    }
}

enum PeerError: Error, LocalizedError, Sendable, Equatable {
    case noCode
    case unreachable
    case handshakeFailed
    case timeout
    case closed

    var errorDescription: String? {
        switch self {
        case .noCode:
            return "Link the two Macs with a pairing code in Settings."
        case .unreachable:
            return "The other Mac isn't reachable."
        case .handshakeFailed:
            return "The other Mac rejected the pairing code."
        case .timeout:
            return "The other Mac didn't answer in time."
        case .closed:
            return "The link to the other Mac closed."
        }
    }
}

struct PeerMessage: Codable, Sendable, Equatable {
    var id: UUID
    var type: String
    var address: String?
    var addresses: [String]?
    var forget: Bool?
    var stamps: [ClaimStamp]?
    var name: String?
    var host: String?

    func reply(type: String, stamps: [ClaimStamp]? = nil) -> PeerMessage {
        PeerMessage(id: id, type: type, address: address, addresses: addresses, forget: forget, stamps: stamps, name: name, host: host)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
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
}

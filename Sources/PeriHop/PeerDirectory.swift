import Foundation
import Network

/// One PeriHop service seen over Bonjour.
struct PeerSighting: Hashable, Sendable {
    var name: String
    /// TXT `fp`: fingerprint of the advertiser's pairing code.
    var fingerprint: String?
    /// TXT `id`: random per launch. Bonjour renames clashing service names,
    /// so the name alone can't tell this Mac from another Mac with the same name.
    var instance: String?
    var endpoint: NWEndpoint
}

extension PeerSighting {
    init?(_ result: NWBrowser.Result) {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        var fingerprint: String?
        var instance: String?
        if case .bonjour(let record) = result.metadata {
            fingerprint = record["fp"].flatMap { $0.isEmpty ? nil : $0 }
            instance = record["id"].flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(name: name, fingerprint: fingerprint, instance: instance, endpoint: result.endpoint)
    }
}

/// Which advertised peer to dial and which identity to show. Anyone on the
/// network can advertise any fingerprint, so this only picks candidates; the
/// handshake is what authenticates them.
struct PeerDirectory: Sendable {
    let localName: String
    let localInstance: String
    var codeFingerprint = ""
    var pinnedFingerprint: String?
    /// Other Macs, sorted by name so the choice is stable.
    private(set) var peers: [PeerSighting] = []

    init(localName: String, localInstance: String) {
        self.localName = localName
        self.localInstance = localInstance
    }

    mutating func update(_ sightings: [PeerSighting]) {
        peers = sightings.filter { !isSelf($0) }.sorted { $0.name < $1.name }
    }

    mutating func clear() {
        peers = []
    }

    func isSelf(_ sighting: PeerSighting) -> Bool {
        if let instance = sighting.instance { return instance == localInstance }
        return sighting.name == localName
    }

    func isTrusted(_ fingerprint: String) -> Bool {
        pinnedFingerprint == nil || pinnedFingerprint == fingerprint
    }

    /// A peer advertising this Mac's code. Any other fingerprint would fail
    /// the handshake and count against that host.
    var dialable: NWEndpoint? {
        let match = peers.first { $0.fingerprint == codeFingerprint }
            ?? peers.first { $0.fingerprint == nil }
        return match?.endpoint
    }

    /// A trusted peer when one is visible, otherwise the first stranger, so a
    /// second advertiser can't flip a trusted link to untrusted.
    var identity: (fingerprint: String, trusted: Bool)? {
        let advertised = peers.compactMap(\.fingerprint)
        if let trusted = advertised.first(where: isTrusted) { return (trusted, true) }
        return advertised.first.map { ($0, false) }
    }

    var trustByName: [String: Bool] {
        var result: [String: Bool] = [:]
        for peer in peers {
            guard let fingerprint = peer.fingerprint else { continue }
            result[peer.name] = isTrusted(fingerprint)
        }
        return result
    }
}

enum PeerEndpoint {
    static let defaultPort: UInt16 = 47620

    static var parameters: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        // A Mac that falls asleep leaves its sockets open. Keepalive finds
        // the dead link in about twenty seconds instead of minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Parses `host`, `host:port`, `[v6]:port`, or a bare IPv6 literal.
    static func endpoint(from text: String) -> NWEndpoint? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let host: String
        var portText: String?
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.hasPrefix(":") { portText = String(rest.dropFirst()) }
        } else if trimmed.filter({ $0 == ":" }).count > 1 {
            host = trimmed
        } else {
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            host = parts[0]
            if parts.count == 2 { portText = parts[1] }
        }
        guard !host.isEmpty else { return nil }
        let portValue = portText.flatMap { UInt16($0) } ?? defaultPort
        guard let port = NWEndpoint.Port(rawValue: portValue) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    static func host(of endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return "\(host)"
        }
        return String(describing: endpoint)
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

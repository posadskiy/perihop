import Foundation
import Network

/// Owns the TCP listener and its Bonjour advertisement, and rebinds it when
/// it fails. Each `start` or `stop` supersedes any bind still in progress.
actor PeerListener {
    struct Advertisement: Equatable, Sendable {
        var name: String
        var fingerprint: String
        var instance: String
    }

    static let serviceType = "_perihop._tcp"

    private var listener: NWListener?
    private var advertisement: Advertisement?
    private var onConnection: (@Sendable (NWConnection) -> Void)?
    private var generation = 0

    var isListening: Bool { listener != nil }

    /// Returns once the old listener has released the port. Binding continues
    /// in the background.
    func start(_ advertisement: Advertisement, onConnection: @escaping @Sendable (NWConnection) -> Void) async {
        generation += 1
        let generation = self.generation
        self.advertisement = advertisement
        self.onConnection = onConnection
        await retireCurrent()
        Task { await self.bind(generation) }
    }

    func stop() async {
        generation += 1
        advertisement = nil
        onConnection = nil
        await retireCurrent()
    }

    /// Retries until it binds or is superseded. A port held by another
    /// process keeps retrying slowly instead of leaving this Mac deaf.
    private func bind(_ generation: Int) async {
        var attempt = 0
        while generation == self.generation, listener == nil, let advertisement, let onConnection {
            attempt += 1
            let quiet = attempt > 3 && attempt % 60 != 0
            let candidate: NWListener
            do {
                candidate = try NWListener(using: Self.parameters, on: NWEndpoint.Port(integerLiteral: PeerEndpoint.defaultPort))
            } catch {
                if !quiet { AppLog.peer.error("Couldn't listen for the other Mac: \(error.localizedDescription)") }
                await pause(attempt)
                continue
            }
            candidate.service = NWListener.Service(
                name: advertisement.name,
                type: Self.serviceType,
                domain: nil,
                txtRecord: NWTXTRecord(["fp": advertisement.fingerprint, "id": advertisement.instance])
            )
            candidate.newConnectionHandler = onConnection
            let ready = await waitForReady(candidate, quiet: quiet)
            guard generation == self.generation else {
                await retire(candidate)
                return
            }
            guard ready else {
                await retire(candidate)
                await pause(attempt)
                continue
            }
            listener = candidate
            let id = ObjectIdentifier(candidate)
            candidate.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                AppLog.peer.error("Listener failed: \(error.localizedDescription)")
                Task { await self?.recover(id) }
            }
        }
    }

    private func pause(_ attempt: Int) async {
        let seconds = attempt <= 3 ? 0.2 * Double(attempt) : 5
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func recover(_ id: ObjectIdentifier) async {
        guard let listener, ObjectIdentifier(listener) == id else { return }
        self.listener = nil
        await retire(listener)
        await bind(generation)
    }

    private func waitForReady(_ listener: NWListener, quiet: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = FirstOnly()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.run { continuation.resume(returning: true) }
                case .failed(let error):
                    if !quiet { AppLog.peer.error("Listener failed: \(error.localizedDescription)") }
                    gate.run { continuation.resume(returning: false) }
                case .cancelled:
                    gate.run { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                gate.run { continuation.resume(returning: false) }
            }
        }
    }

    private func retireCurrent() async {
        guard let listener else { return }
        self.listener = nil
        await retire(listener)
    }

    /// `cancel()` frees the port only once the listener reports `.cancelled`.
    /// Binding the next one earlier fails with "Address already in use".
    private func retire(_ listener: NWListener) async {
        await withCheckedContinuation { continuation in
            let gate = FirstOnly()
            listener.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    gate.run { continuation.resume() }
                default:
                    break
                }
            }
            listener.cancel()
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                gate.run { continuation.resume() }
            }
        }
    }

    private static var parameters: NWParameters {
        let parameters = PeerEndpoint.parameters
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}

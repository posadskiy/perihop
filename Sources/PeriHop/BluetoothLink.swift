import CoreBluetooth
import CryptoKit
import Foundation

/// The Mac-to-Mac link over Bluetooth LE, for when the network keeps the two
/// Macs apart (a VPN, a guest Wi-Fi, a firewall). Each Mac advertises a
/// service whose id is derived from the pairing code and publishes an L2CAP
/// channel. The Mac that needs the link scans for that service, connects,
/// and opens the channel. The same handshake and sealed frames as on TCP
/// run over it, so Bluetooth itself is not trusted with anything.
///
/// Scanning runs only while a dial is waiting, so it does not compete with
/// the keyboard and trackpad for the radio the rest of the time.
final class BluetoothLink: NSObject, @unchecked Sendable {
    typealias Inbound = @Sendable (PeerStream) -> Void

    private struct Dial {
        let id: UUID
        let continuation: CheckedContinuation<PeerStream, Error>
    }

    private let queue = DispatchQueue(label: "com.posadskiy.perihop.ble")
    private var central: CBCentralManager?
    private var publisher: CBPeripheralManager?
    private var serviceID: CBUUID?
    private var channelID: CBUUID?
    private var onInbound: Inbound?
    private var psm: CBL2CAPPSM?
    private var advertised = false
    private var dial: Dial?
    /// The other Mac while a dial is connecting to it. CoreBluetooth drops
    /// a peripheral nobody retains.
    private var target: CBPeripheral?
    /// Peripherals whose channel is in use, by stream id.
    private var inUse: [ObjectIdentifier: CBPeripheral] = [:]

    func start(key: SymmetricKey, onInbound: @escaping Inbound) {
        queue.async {
            self.teardown()
            self.serviceID = Self.identifier("perihop-ble-service", key: key)
            self.channelID = Self.identifier("perihop-ble-channel", key: key)
            self.onInbound = onInbound
            self.publisher = CBPeripheralManager(delegate: self, queue: self.queue)
            self.central = CBCentralManager(delegate: self, queue: self.queue)
        }
    }

    func stop() {
        queue.async { self.teardown() }
    }

    /// Finds the other Mac and opens a channel to it.
    func connect(timeout: TimeInterval) async throws -> PeerStream {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let central = self.central, let serviceID = self.serviceID, central.state == .poweredOn else {
                    continuation.resume(throwing: PeerError.unreachable)
                    return
                }
                guard self.dial == nil else {
                    continuation.resume(throwing: PeerError.unreachable)
                    return
                }
                self.dial = Dial(id: id, continuation: continuation)
                central.scanForPeripherals(withServices: [serviceID])
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard self.dial?.id == id else { return }
                    self.finishDial(.failure(PeerError.unreachable))
                }
            }
        }
    }

    private func finishDial(_ result: Result<PeerStream, Error>) {
        central?.stopScan()
        guard let dial else { return }
        self.dial = nil
        if case .failure = result, let target {
            central?.cancelPeripheralConnection(target)
        }
        target = nil
        dial.continuation.resume(with: result)
    }

    private func teardown() {
        finishDial(.failure(PeerError.closed))
        central?.stopScan()
        for peripheral in inUse.values {
            central?.cancelPeripheralConnection(peripheral)
        }
        inUse = [:]
        if let psm {
            publisher?.unpublishL2CAPChannel(psm)
        }
        publisher?.stopAdvertising()
        publisher?.removeAllServices()
        publisher?.delegate = nil
        central?.delegate = nil
        publisher = nil
        central = nil
        psm = nil
        advertised = false
        onInbound = nil
    }

    private func advertise() {
        guard let publisher, publisher.state == .poweredOn, let serviceID, let channelID, let psm, !advertised else {
            return
        }
        advertised = true
        var value = psm.littleEndian
        let characteristic = CBMutableCharacteristic(
            type: channelID,
            properties: .read,
            value: Data(bytes: &value, count: MemoryLayout<CBL2CAPPSM>.size),
            permissions: .readable
        )
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [characteristic]
        publisher.add(service)
        publisher.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
        AppLog.peer.info("bluetooth link advertising")
    }

    /// A 128-bit id only a Mac with the pairing code can compute.
    static func identifier(_ label: String, key: SymmetricKey) -> CBUUID {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key)
        return CBUUID(data: Data(digest.prefix(16)))
    }
}

extension BluetoothLink: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            advertised = false
            psm = nil
            return
        }
        // The frames are sealed by PeriHop, so the channel needs no
        // Bluetooth pairing between the Macs.
        peripheral.publishL2CAPChannel(withEncryption: false)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            AppLog.peer.error("bluetooth link couldn't publish a channel: \(error.localizedDescription)")
            return
        }
        psm = PSM
        advertise()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { return }
        let label = "bluetooth:\(channel.peer?.identifier.uuidString.prefix(8) ?? "peer")"
        AppLog.peer.info("bluetooth link incoming \(label)")
        onInbound?(ChannelStream(channel: channel, label: label, onClose: {}))
    }
}

extension BluetoothLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            finishDial(.failure(PeerError.unreachable))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard dial != nil, target == nil else { return }
        central.stopScan()
        target = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === target, let serviceID else { return }
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === target else { return }
        finishDial(.failure(error ?? PeerError.unreachable))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === target {
            finishDial(.failure(error ?? PeerError.closed))
        }
        inUse = inUse.filter { $0.value !== peripheral }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === target, let channelID,
              let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            if peripheral === target { finishDial(.failure(error ?? PeerError.unreachable)) }
            return
        }
        peripheral.discoverCharacteristics([channelID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === target,
              let characteristic = service.characteristics?.first(where: { $0.uuid == channelID }) else {
            if peripheral === target { finishDial(.failure(error ?? PeerError.unreachable)) }
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === target else { return }
        guard let value = characteristic.value, value.count >= MemoryLayout<CBL2CAPPSM>.size else {
            finishDial(.failure(error ?? PeerError.unreachable))
            return
        }
        let psm = value.withUnsafeBytes { $0.loadUnaligned(as: CBL2CAPPSM.self).littleEndian }
        peripheral.openL2CAPChannel(psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard peripheral === target else { return }
        guard let channel, error == nil else {
            finishDial(.failure(error ?? PeerError.unreachable))
            return
        }
        let label = "bluetooth:\(peripheral.identifier.uuidString.prefix(8))"
        let holder = StreamKey()
        let stream = ChannelStream(channel: channel, label: label) { [weak self] in
            guard let link = self else { return }
            link.queue.async {
                guard let key = holder.id, let peripheral = link.inUse.removeValue(forKey: key) else { return }
                link.central?.cancelPeripheralConnection(peripheral)
            }
        }
        holder.id = ObjectIdentifier(stream)
        inUse[ObjectIdentifier(stream)] = peripheral
        target = nil
        AppLog.peer.info("bluetooth link outgoing \(label)")
        finishDial(.success(stream))
    }
}

private final class StreamKey: @unchecked Sendable {
    var id: ObjectIdentifier?
}

/// An L2CAP channel as a `PeerStream`. Works on any bound input and output
/// stream pair, which is how the tests drive it.
final class ChannelStream: NSObject, PeerStream, StreamDelegate, @unchecked Sendable {
    let label: String

    private let channel: CBL2CAPChannel?
    private let input: InputStream
    private let output: OutputStream
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var inbox = Data()
    private var outbox = Data()
    private var reader: CheckedContinuation<Data, Error>?
    private var writers: [CheckedContinuation<Void, Error>] = []
    private var failure: Error?
    private var opened = false

    convenience init(channel: CBL2CAPChannel, label: String, onClose: @escaping @Sendable () -> Void) {
        self.init(input: channel.inputStream, output: channel.outputStream, label: label, channel: channel, onClose: onClose)
    }

    init(
        input: InputStream,
        output: OutputStream,
        label: String,
        channel: CBL2CAPChannel? = nil,
        onClose: @escaping @Sendable () -> Void = {}
    ) {
        self.input = input
        self.output = output
        self.label = label
        self.channel = channel
        self.onClose = onClose
    }

    func open() async throws {
        guard markOpened() else { return }
        input.delegate = self
        output.delegate = self
        // Stream callbacks need a run loop that never goes away.
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        input.open()
        output.open()
    }

    private func markOpened() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = !opened
        opened = true
        return first
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            outbox.append(data)
            writers.append(continuation)
            let done = drain()
            lock.unlock()
            done.forEach { $0.resume() }
        }
    }

    func readChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            lock.lock()
            if !inbox.isEmpty {
                let data = inbox
                inbox = Data()
                lock.unlock()
                continuation.resume(returning: data)
                return
            }
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            reader = continuation
            lock.unlock()
        }
    }

    func close() {
        fail(PeerError.closed)
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            pull()
        case .hasSpaceAvailable:
            lock.lock()
            let done = drain()
            lock.unlock()
            done.forEach { $0.resume() }
        case .errorOccurred:
            fail(stream.streamError ?? PeerError.closed)
        case .endEncountered:
            fail(PeerError.closed)
        default:
            break
        }
    }

    private func pull() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var received = Data()
        while input.hasBytesAvailable {
            let count = input.read(&chunk, maxLength: chunk.count)
            guard count > 0 else { break }
            received.append(chunk, count: count)
        }
        guard !received.isEmpty else { return }
        lock.lock()
        inbox.append(received)
        let waiting = reader
        reader = nil
        let data = waiting == nil ? Data() : inbox
        if waiting != nil { inbox = Data() }
        lock.unlock()
        waiting?.resume(returning: data)
    }

    /// Writes what the stream will take. Returns the writers to resume once
    /// everything queued has gone out. Called with the lock held.
    private func drain() -> [CheckedContinuation<Void, Error>] {
        while !outbox.isEmpty, output.hasSpaceAvailable {
            let written = outbox.withUnsafeBytes { bytes in
                output.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: bytes.count)
            }
            guard written > 0 else { break }
            outbox.removeFirst(written)
        }
        guard outbox.isEmpty else { return [] }
        let done = writers
        writers = []
        return done
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            return
        }
        failure = error
        let waiting = reader
        reader = nil
        let pending = writers
        writers = []
        lock.unlock()
        input.delegate = nil
        output.delegate = nil
        input.close()
        output.close()
        input.remove(from: .main, forMode: .common)
        output.remove(from: .main, forMode: .common)
        waiting?.resume(throwing: error)
        pending.forEach { $0.resume(throwing: error) }
        onClose()
    }
}

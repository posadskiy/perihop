import Foundation
import IOBluetooth

/// One IOBluetooth operation that is waiting on a callback. Callbacks may
/// arrive on a Bluetooth thread, so each one hops to the main actor with a
/// `Task` rather than assuming it is already there.
@MainActor
protocol BluetoothSession: AnyObject {
    /// Ends the wait now with a cancelled result.
    func stop()
}

/// `openConnection` with a target, so the page does not block the main actor.
@MainActor
final class ConnectionSession: NSObject, BluetoothSession {
    /// A page can outlive our timeout, and IOBluetooth messages the target
    /// when it ends. Targets stay here until that callback or a safety delay.
    private static var awaitingCallback: Set<ConnectionSession> = []

    private var continuation: CheckedContinuation<IOReturn, Never>?
    private var timeoutTask: Task<Void, Never>?

    func open(_ device: IOBluetoothDevice, pages: BluetoothHCIPageTimeout, timeout: TimeInterval) async -> IOReturn {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let result = device.openConnection(self, withPageTimeout: pages, authenticationRequired: false)
            guard result == kIOReturnSuccess else {
                self.finish(result)
                return
            }
            Self.awaitingCallback.insert(self)
            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.finish(kIOReturnTimeout)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((timeout + 30) * 1_000_000_000))
                Self.awaitingCallback.remove(self)
            }
        }
    }

    func stop() {
        finish(kIOReturnAborted)
    }

    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        Task { @MainActor in
            Self.awaitingCallback.remove(self)
            self.finish(status)
        }
    }

    private func finish(_ status: IOReturn) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(returning: status)
    }
}

@MainActor
final class PairSession: NSObject, BluetoothSession {
    private var continuation: CheckedContinuation<Void, Error>?
    private var pairer: IOBluetoothDevicePair?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func pair(_ device: IOBluetoothDevice, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            guard !finished else {
                finish(.failure(BluetoothError.failed("Stopped.")))
                return
            }
            let pairer = IOBluetoothDevicePair(device: device)
            pairer?.delegate = self
            self.pairer = pairer
            let result = pairer?.start() ?? kIOReturnError
            if result != kIOReturnSuccess {
                AppLog.bluetooth.error("pair start \(IOReturnLabel.describe(result))")
                self.finish(.failure(BluetoothError.failed("Couldn't start pairing.")))
                return
            }
            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                AppLog.bluetooth.error("pair timed out after \(Int(timeout))s")
                self.pairer?.stop()
                self.finish(.failure(BluetoothError.failed("Pairing timed out.")))
            }
        }
    }

    func stop() {
        pairer?.stop()
        finish(.failure(BluetoothError.failed("Stopped.")))
    }

    @objc nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        Task { @MainActor in
            AppLog.bluetooth.info("pair finished \(IOReturnLabel.describe(error))")
            if error == kIOReturnSuccess {
                self.finish(.success(()))
            } else {
                self.finish(.failure(BluetoothError.failed("Pairing failed (\(IOReturnLabel.describe(error))).")))
            }
        }
    }

    @objc nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: UInt32) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    @objc nonisolated func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode(data: (
            0x30, 0x30, 0x30, 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ))
        (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
    }

    /// The pairer does not retain its delegate, so it is detached once the
    /// result is in and this session may be released.
    private func finish(_ result: Result<Void, Error>) {
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        pairer?.delegate = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// One `IOBluetoothDeviceInquiry` for the whole wait, restarted while time
/// remains. Inquiries end on their own after `inquiryLength`.
@MainActor
final class InquirySession: NSObject, BluetoothSession {
    /// Released inquiries crash inside `dealloc` on the Bluetooth coordinator
    /// queue if the object dies while that queue is still unwinding `stop`.
    private static var cooling: [IOBluetoothDeviceInquiry] = []
    private static var quietUntil = Date.distantPast

    private var continuation: CheckedContinuation<Bool, Never>?
    private var listContinuation: CheckedContinuation<[BTDevice], Never>?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var target: DeviceAddress?
    private var deadline = Date()
    private var startedAt = Date()
    private var finished = false
    private var foundTarget = false
    private var found: [BTDevice] = []
    private var pending: Task<Void, Never>?

    override init() {
        super.init()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else { return }
        inquiry.updateNewDeviceNames = false
        self.inquiry = inquiry
    }

    func collect(timeout: TimeInterval) async -> [BTDevice] {
        guard !finished else { return found }
        deadline = Date().addingTimeInterval(timeout)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[BTDevice], Never>) in
            self.listContinuation = continuation
            self.beginSearch()
        }
    }

    func stop() {
        end(found: false)
    }

    private func beginSearch() {
        guard !finished, let inquiry else {
            end(found: foundTarget)
            return
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.25 else {
            end(found: foundTarget)
            return
        }
        let quiet = Self.quietUntil.timeIntervalSinceNow
        if quiet > 0 {
            schedule(after: min(quiet, remaining)) { self.beginSearch() }
            return
        }
        inquiry.inquiryLength = UInt8(min(255, max(1, Int(ceil(remaining)))))
        let result = inquiry.start()
        AppLog.bluetooth.info("inquiry start \(IOReturnLabel.describe(result)) timeout=\(String(format: "%.1f", remaining))s")
        if result != kIOReturnSuccess {
            schedule(after: 1) { self.beginSearch() }
            return
        }
        startedAt = Date()
        schedule(after: remaining + 1) { self.end(found: self.foundTarget) }
    }

    /// `stop()` delivers `deviceInquiryComplete` before it returns, and that
    /// callback used to resume "not found" before the hit was recorded. The
    /// hit is stored first, and a stopped search is not started again.
    fileprivate func consider(address rawAddress: String, name: String) {
        guard !finished else { return }
        let address = DeviceAddress(rawAddress)
        if !found.contains(where: { $0.address == address }) {
            found.append(BTDevice(address: address, name: name))
        }
        let matched = target == address
        AppLog.bluetooth.info("inquiry saw \(name) \(address.rawValue)\(matched ? " hit" : "")")
        if matched {
            foundTarget = true
            end(found: true)
        }
    }

    fileprivate func searchEnded(error: IOReturn, aborted: Bool) {
        guard !finished else { return }
        AppLog.bluetooth.info("inquiry complete \(IOReturnLabel.describe(error)) aborted=\(aborted)")
        if foundTarget {
            end(found: true)
            return
        }
        let lived = Date().timeIntervalSince(startedAt)
        let pause = lived < 0.5 ? 1.0 : 0.4
        guard deadline.timeIntervalSinceNow > pause + 0.25 else {
            end(found: false)
            return
        }
        schedule(after: pause) { self.beginSearch() }
    }

    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !self.finished else { return }
            body()
        }
    }

    private func end(found: Bool) {
        guard !finished else { return }
        finished = true
        pending?.cancel()
        pending = nil
        Self.quietUntil = Date().addingTimeInterval(1)
        let inquiry = self.inquiry
        inquiry?.delegate = nil
        inquiry?.stop()
        self.inquiry = nil
        if let inquiry {
            Self.cooling.append(inquiry)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Self.cooling.removeAll { $0 === inquiry }
            }
        }
        continuation?.resume(returning: found)
        continuation = nil
        listContinuation?.resume(returning: self.found)
        listContinuation = nil
    }
}

extension InquirySession: IOBluetoothDeviceInquiryDelegate {
    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        let address = device?.addressString ?? ""
        let name = device?.nameOrAddress ?? address
        Task { @MainActor in
            self.consider(address: address, name: name)
        }
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        Task { @MainActor in
            self.searchEnded(error: error, aborted: aborted)
        }
    }
}

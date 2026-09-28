import Foundation
import CryptoKit
@testable import QAudionEngine

// Test doubles for the proximity-pairing state machines. No Bluetooth, no
// real time, no Keychain: everything is deterministic and in-memory.
//
// Delivery model (mirrors the BLE transport's guarantee): `send`, `close`,
// `connect` never call back synchronously. They ENQUEUE a delivery on the
// shared `ProximityTestHub`; the test drives delivery with `step()` (one
// item) or `pump()` (until quiescent). Messages are delivered in FIFO order,
// a message already queued to a peer is still delivered after the sender
// closes (like a notification in flight), and nothing is delivered to an end
// that is closed.

/// FIFO delivery queue shared by every fake of one test.
final class ProximityTestHub {

    private var queue: [() -> Void] = []

    var pendingCount: Int {
        return queue.count
    }

    func enqueue(_ delivery: @escaping () -> Void) {
        queue.append(delivery)
    }

    /// Delivers one queued item. False when the queue was empty.
    @discardableResult
    func step() -> Bool {
        if queue.isEmpty { return false }
        let delivery: () -> Void = queue.removeFirst()
        delivery()
        return true
    }

    /// Delivers queued items one at a time until quiescent (or `limit` steps).
    @discardableResult
    func pump(limit: Int = 10_000) -> Int {
        var delivered: Int = 0
        while delivered < limit, step() {
            delivered += 1
        }
        return delivered
    }
}

/// One end of an in-memory link pair.
final class ProximityFakeLink: ProximityPairingLink {

    enum Side {
        case displayerEnd
        case scannerEnd
    }

    let side: Side
    private let hub: ProximityTestHub
    /// The other end. Both ends are kept alive by the transport that made them.
    weak var peer: ProximityFakeLink?

    private(set) var isClosed: Bool = false
    /// Every message this end was asked to send, before any filter.
    private(set) var sent: [Data] = []
    private(set) var closeCount: Int = 0

    /// Applied to every outgoing message; returning nil drops it.
    var outgoingFilter: ((Data) -> Data?)?

    var onMessage: ((Data) -> Void)?
    var onClosed: ((ProximityPairingError?) -> Void)?

    init(side: Side, hub: ProximityTestHub) {
        self.side = side
        self.hub = hub
    }

    func send(_ message: Data) {
        guard !isClosed else { return }
        let copy: Data = Data(message)
        sent.append(copy)
        var outgoing: Data? = copy
        if let filter = outgoingFilter {
            outgoing = filter(copy)
        }
        guard let delivered = outgoing else { return }
        let target: ProximityFakeLink? = peer
        hub.enqueue {
            target?.receive(delivered)
        }
    }

    func close() {
        closeCount += 1
        guard !isClosed else { return }
        isClosed = true
        let target: ProximityFakeLink? = peer
        hub.enqueue {
            target?.peerDidClose()
        }
    }

    /// Queues `message` for delivery to THIS end, as if the peer had sent it,
    /// bypassing the peer's filter.
    func inject(_ message: Data) {
        let copy: Data = Data(message)
        hub.enqueue { [weak self] in
            self?.receive(copy)
        }
    }

    /// A radio drop: both ends close now and both see `onClosed` on delivery.
    func simulateDrop(_ error: ProximityPairingError?) {
        var ends: [ProximityFakeLink] = [self]
        if let other = peer {
            ends.append(other)
        }
        for end in ends where !end.isClosed {
            end.isClosed = true
            hub.enqueue {
                end.onClosed?(error)
            }
        }
    }

    fileprivate func receive(_ message: Data) {
        guard !isClosed else { return }
        onMessage?(message)
    }

    fileprivate func peerDidClose() {
        guard !isClosed else { return }
        isClosed = true
        onClosed?(nil)
    }
}

/// Fake GATT peripheral.
final class ProximityFakeDisplayerTransport: ProximityDisplayerTransport {

    private let hub: ProximityTestHub

    private(set) var startAdvertisingCalls: [Data] = []
    private(set) var stopAdvertisingCount: Int = 0
    private(set) var shutdownCount: Int = 0
    /// The service currently advertised, nil when not advertising.
    private(set) var advertisedServiceId: Data?
    /// Displayer ends of every link created, in order.
    private(set) var displayerEnds: [ProximityFakeLink] = []
    /// Scanner ends of every link created, in order.
    private(set) var scannerEnds: [ProximityFakeLink] = []

    /// Tamper hooks for displayer→scanner and scanner→displayer traffic
    /// (nil return drops the message). Consulted at send time.
    var toScannerFilter: ((Data) -> Data?)?
    var toDisplayerFilter: ((Data) -> Data?)?

    var onIncomingLink: ((ProximityPairingLink) -> Void)?
    var onUnavailable: ((ProximityPairingError) -> Void)?

    init(hub: ProximityTestHub) {
        self.hub = hub
    }

    func startAdvertising(serviceId: Data) {
        let copy: Data = Data(serviceId)
        startAdvertisingCalls.append(copy)
        advertisedServiceId = copy
    }

    func stopAdvertising() {
        stopAdvertisingCount += 1
        advertisedServiceId = nil
    }

    func shutdown() {
        shutdownCount += 1
        advertisedServiceId = nil
        for end in displayerEnds {
            end.close()
        }
    }

    /// A central connected and subscribed: hands the displayer end to the
    /// session via `onIncomingLink` and returns the scanner end.
    func connectCentral() -> ProximityFakeLink {
        let displayerEnd = ProximityFakeLink(side: .displayerEnd, hub: hub)
        let scannerEnd = ProximityFakeLink(side: .scannerEnd, hub: hub)
        displayerEnd.peer = scannerEnd
        scannerEnd.peer = displayerEnd
        displayerEnd.outgoingFilter = { [weak self] (message: Data) -> Data? in
            guard let filter = self?.toScannerFilter else { return message }
            return filter(message)
        }
        scannerEnd.outgoingFilter = { [weak self] (message: Data) -> Data? in
            guard let filter = self?.toDisplayerFilter else { return message }
            return filter(message)
        }
        displayerEnds.append(displayerEnd)
        scannerEnds.append(scannerEnd)
        onIncomingLink?(displayerEnd)
        return scannerEnd
    }
}

/// Fake GATT central. `connect` completes on the hub, never synchronously.
final class ProximityFakeScannerTransport: ProximityScannerTransport {

    private let hub: ProximityTestHub
    private let target: ProximityFakeDisplayerTransport?

    /// When true (default), connecting needs the target to advertise the service.
    var requireAdvertising: Bool = true
    /// When set, `connect` completes with this instead of reaching the target.
    var forcedResult: Result<ProximityPairingLink, ProximityPairingError>?

    private(set) var connectCalls: [Data] = []
    private(set) var connectTimeouts: [TimeInterval] = []
    private(set) var cancelCount: Int = 0
    private(set) var link: ProximityFakeLink?
    private var cancelled: Bool = false

    init(hub: ProximityTestHub, target: ProximityFakeDisplayerTransport?) {
        self.hub = hub
        self.target = target
    }

    func connect(serviceId: Data, timeout: TimeInterval,
                 completion: @escaping (Result<ProximityPairingLink, ProximityPairingError>) -> Void) {
        let wanted: Data = Data(serviceId)
        connectCalls.append(wanted)
        connectTimeouts.append(timeout)
        cancelled = false
        hub.enqueue { [weak self] in
            guard let self = self else { return }
            self.completeConnect(serviceId: wanted, completion: completion)
        }
    }

    func cancel() {
        cancelCount += 1
        cancelled = true
        link?.close()
    }

    private func completeConnect(serviceId: Data,
                                 completion: (Result<ProximityPairingLink, ProximityPairingError>) -> Void) {
        if cancelled {
            completion(.failure(.cancelled))
            return
        }
        if let forced = forcedResult {
            completion(forced)
            return
        }
        guard let displayer = target else {
            completion(.failure(.timeout("no peripheral")))
            return
        }
        if requireAdvertising {
            guard let advertised = displayer.advertisedServiceId, advertised == serviceId else {
                completion(.failure(.timeout("no peripheral")))
                return
            }
        }
        let scannerEnd: ProximityFakeLink = displayer.connectCentral()
        link = scannerEnd
        completion(.success(scannerEnd))
    }
}

final class ProximityManualCancellable: ProximityCancellable {
    private(set) var isCancelled: Bool = false

    func cancel() {
        isCancelled = true
    }
}

/// Virtual clock. `advance(by:)` fires due actions in (time, scheduling order).
@MainActor
final class ProximityManualScheduler: ProximityScheduler {

    private struct Entry {
        let sequence: Int
        let fireAt: TimeInterval
        let action: @MainActor () -> Void
        let token: ProximityManualCancellable
    }

    private var entries: [Entry] = []
    private var nextSequence: Int = 0
    private(set) var currentTime: TimeInterval

    init(startTime: TimeInterval = 1_000) {
        self.currentTime = startTime
    }

    func now() -> TimeInterval {
        return currentTime
    }

    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ProximityCancellable {
        let token = ProximityManualCancellable()
        let fireAt: TimeInterval = currentTime + max(0, delay)
        entries.append(Entry(sequence: nextSequence, fireAt: fireAt, action: action, token: token))
        nextSequence += 1
        return token
    }

    /// Scheduled actions not cancelled and not yet fired.
    var pendingCount: Int {
        var count: Int = 0
        for entry in entries where !entry.token.isCancelled {
            count += 1
        }
        return count
    }

    func advance(by delta: TimeInterval) {
        let target: TimeInterval = currentTime + delta
        while let index = nextDueIndex(until: target) {
            let entry: Entry = entries.remove(at: index)
            if entry.fireAt > currentTime {
                currentTime = entry.fireAt
            }
            entry.action()
        }
        currentTime = target
    }

    private func nextDueIndex(until target: TimeInterval) -> Int? {
        entries.removeAll { (entry: Entry) -> Bool in
            return entry.token.isCancelled
        }
        var best: Int?
        var index: Int = 0
        while index < entries.count {
            let entry: Entry = entries[index]
            if entry.fireAt <= target {
                if let current = best {
                    let other: Entry = entries[current]
                    if entry.fireAt < other.fireAt
                        || (entry.fireAt == other.fireAt && entry.sequence < other.sequence) {
                        best = index
                    }
                } else {
                    best = index
                }
            }
            index += 1
        }
        return best
    }
}

/// Fresh, valid local identities for tests.
enum ProximityTestIdentities {

    static func make(userId: String) throws -> ProximityLocalIdentity {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        return try ProximityLocalIdentity(userId: userId,
                                          signingPrivateKey: signing.rawRepresentation,
                                          encryptionPublicKey: agreement.publicKey.rawRepresentation)
    }
}

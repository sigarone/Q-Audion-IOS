import Foundation
import CryptoKit

// The state of the per-round inner audio seal of ONE call (spec B2, B12, B14). Created and owned by `LiveCallCrypto`; the engine
// gets only the narrow `InnerSealPort`.
//
// Rules of the file:
// - one `NSLock` inside the session; nothing is called out under it (no closure parameter but the injected clock, no log);
// - lock order: `LiveCallCrypto.lock` -> `InnerSealV2Session.lock` -> `ChainKeyBuffer.lock`, and `QAudionEngine.lock` ->
//   `InnerSealV2Session.lock`; the session never takes either of the other two;
// - a counter is consumed BEFORE the cipher runs (a failed seal never repeats a value), the replay window records AFTER the open
//   succeeded (a failed open records nothing), and neither the counter nor the window is ever reset inside a call;
// - the send pointer moves only at the peer's verified key confirmation of a later round, forward only;
// - no round is evicted to make room: a full table refuses, and a slot that would share its envelope byte with a live one is
//   refused, never overwritten.

// MARK: - Outcomes

/// Why an inner frame was not delivered. The raw values 1 ... 7 are the numbers of the log line.
public enum InnerDrop: Int, Equatable, Sendable {
    case unknownType = 1
    case malformed = 2
    case noSlot = 3
    case replay = 4
    case tooOld = 5
    case legacyFrame = 6
    case malformedBlock = 7
    /// The cipher refused the frame: a decrypt failure, not a plain drop.
    case aead = 8
    case closed = 9

    public var word: String {
        switch self {
        case .unknownType: return "unknown_type"
        case .malformed: return "malformed"
        case .noSlot: return "no_slot"
        case .replay: return "replay"
        case .tooOld: return "too_old"
        case .legacyFrame: return "legacy_frame"
        case .malformedBlock: return "malformed_block"
        case .aead: return "aead"
        case .closed: return "closed"
        }
    }
}

public enum InnerSealRefusal: Int, Equatable, Sendable {
    case closed = 1
    case noSendSlot = 2
    case ctrExhausted = 3
    case sealFailed = 4
}

public enum InnerSealOutcome: Equatable, Sendable {
    case sealed(wire: Data, ctr: UInt64, epochByte: UInt8)
    case refused(InnerSealRefusal)
}

public enum InnerOpenOutcome: Equatable, Sendable {
    case opened(block: Data, ctr: UInt64)
    case dropped(InnerDrop)
}

/// The send pointer moved forward from one round to another.
public struct InnerSendMove: Equatable, Sendable {
    public let from: Int32
    public let to: Int32

    public init(from: Int32, to: Int32) {
        self.from = from
        self.to = to
    }
}

/// Why a new round slot is not taken.
public enum InnerStageRefusal: Equatable, Sendable {
    case closed
    /// A slot of the same round exists.
    case duplicate
    /// A live slot has the same envelope byte and another round.
    case slotCollision
    /// Sixteen slots are waiting for the peer's confirmation.
    case pendingFull
}

/// What the engine sees: it seals and opens audio blocks and nothing else. Every call re-checks the owner, so a port that was
/// closed refuses and never falls back to anything.
public protocol InnerSealPort: AnyObject, Sendable {
    func sealAudio(block: Data) -> InnerSealOutcome
    func openAudio(wire: Data) -> InnerOpenOutcome
}

/// What the relay video layers see of the inner seal: one plain video fragment in, one envelope out, and back.
public protocol InnerVideoPort: AnyObject, Sendable {
    func sealVideo(fragment: Data) -> InnerSealOutcome
    func openVideo(wire: Data) -> InnerOpenOutcome
}

// MARK: - Slot table

/// The two audio keys of one round, one per direction. Each is a buffer of its own that is wiped when the slot is erased.
struct InnerRoundKeys {
    let offererToAcceptor: ChainKeyBuffer
    let acceptorToOfferer: ChainKeyBuffer
    /// The two video keys: derived only in a call that negotiated the outer relay layer next to the inner seal.
    var videoOffererToAcceptor: ChainKeyBuffer? = nil
    var videoAcceptorToOfferer: ChainKeyBuffer? = nil

    func wipe() {
        offererToAcceptor.wipe()
        acceptorToOfferer.wipe()
        videoOffererToAcceptor?.wipe()
        videoAcceptorToOfferer?.wipe()
    }
}

enum InnerSlotRules {
    /// A round stays receive-only this long after the round above it was confirmed.
    static let graceMs = 30_000
    /// Slots that wait for the peer's confirmation: no more than the undecided rounds of a call.
    static let maxStaged = KcMacRoundBook.maxPendingRounds
}

/// The round slots of one layer of one call. Not thread-safe: the owner holds its lock around every call.
///
/// Retention is lazy (no timer): a verified slot below another verified slot, and not the send slot, is erased once
/// `min(verifiedAtMs of the verified slots above it) + graceMs` has passed. The due set is computed on the table as it is and then
/// erased, so erasing one slot never postpones another. A staged slot, and the slot of round 0 before the peer confirmed it, have
/// no deadline.
struct RoundSlotTable<Payload> {

    struct Slot {
        let epoch: Int32
        let byte: UInt8
        /// nil while staged.
        var verifiedAtMs: Int?
        let payload: Payload
    }

    private(set) var slots: [Slot] = []
    private(set) var sendEpoch: Int32 = -1
    private(set) var currentEpoch: Int32 = -1
    private let wipe: (Payload) -> Void

    init(wipe: @escaping (Payload) -> Void) {
        self.wipe = wipe
    }

    // MARK: Reads

    func slot(forByte byte: UInt8) -> Slot? {
        slots.first(where: { $0.byte == byte })
    }

    func sendSlot() -> Slot? {
        if sendEpoch < 0 { return nil }
        return slots.first(where: { $0.epoch == sendEpoch })
    }

    /// The rounds a sweep at `nowMs` would erase.
    func dueEpochs(nowMs: Int) -> [Int32] {
        var due: [Int32] = []
        for slot in slots where slot.verifiedAtMs != nil && slot.epoch != sendEpoch {
            var earliestAbove: Int?
            for other in slots where other.epoch > slot.epoch {
                if let at = other.verifiedAtMs {
                    earliestAbove = earliestAbove.map { min($0, at) } ?? at
                }
            }
            if let earliest = earliestAbove, nowMs >= earliest + InnerSlotRules.graceMs { due.append(slot.epoch) }
        }
        return due
    }

    /// What would refuse a slot of `epoch`, judged against the slots that survive a sweep at `nowMs` (nothing is erased here).
    func refusal(forEpoch epoch: Int32, nowMs: Int) -> InnerStageRefusal? {
        let due = dueEpochs(nowMs: nowMs)
        let alive = slots.filter { !due.contains($0.epoch) }
        if alive.contains(where: { $0.epoch == epoch }) { return .duplicate }
        let byte = UInt8(truncatingIfNeeded: epoch)
        if alive.contains(where: { $0.byte == byte }) { return .slotCollision }
        if alive.filter({ $0.verifiedAtMs == nil }).count >= InnerSlotRules.maxStaged { return .pendingFull }
        return nil
    }

    // MARK: Mutations

    mutating func sweep(nowMs: Int) {
        for epoch in dueEpochs(nowMs: nowMs) { erase(epoch: epoch) }
    }

    /// Round 0: the slot is taken and the send pointer is on it from the start.
    mutating func stageSending(epoch: Int32, payload: Payload) {
        slots.append(Slot(epoch: epoch, byte: UInt8(truncatingIfNeeded: epoch), verifiedAtMs: nil, payload: payload))
        sendEpoch = epoch
    }

    /// Sweeps first, then takes the slot or says why not. On a refusal the table is unchanged and the payload stays with the caller.
    mutating func install(epoch: Int32, payload: Payload, nowMs: Int) -> InnerStageRefusal? {
        sweep(nowMs: nowMs)
        if let why = refusal(forEpoch: epoch, nowMs: nowMs) { return why }
        slots.append(Slot(epoch: epoch, byte: UInt8(truncatingIfNeeded: epoch), verifiedAtMs: nil, payload: payload))
        return nil
    }

    /// The peer's confirmation of `epoch` verified. A round without a slot is ignored. The pointer moves only forward.
    mutating func peerConfirmed(epoch: Int32, nowMs: Int) -> InnerSendMove? {
        sweep(nowMs: nowMs)
        guard let index = slots.firstIndex(where: { $0.epoch == epoch }) else { return nil }
        if slots[index].verifiedAtMs == nil { slots[index].verifiedAtMs = nowMs }
        if epoch > currentEpoch { currentEpoch = epoch }
        var move: InnerSendMove?
        if epoch > sendEpoch {
            move = InnerSendMove(from: sendEpoch, to: epoch)
            sendEpoch = epoch
        }
        sweep(nowMs: nowMs)
        return move
    }

    /// Erases a staged slot: never round 0, never a verified one, never the send slot.
    mutating func abandon(epoch: Int32) {
        guard epoch != 0, epoch != sendEpoch,
              let index = slots.firstIndex(where: { $0.epoch == epoch }), slots[index].verifiedAtMs == nil else { return }
        erase(epoch: epoch)
    }

    mutating func removeAll() {
        for slot in slots { wipe(slot.payload) }
        slots.removeAll()
    }

    private mutating func erase(epoch: Int32) {
        guard let index = slots.firstIndex(where: { $0.epoch == epoch }) else { return }
        wipe(slots[index].payload)
        slots.remove(at: index)
    }
}

// MARK: - Session

public final class InnerSealV2Session: InnerSealPort, InnerVideoPort, @unchecked Sendable {

    /// What the tests read: epochs and counters, never bytes.
    struct Snapshot: Equatable {
        let send: Int32
        let current: Int32
        let epochs: [Int32]
        let verified: [Int32]
        let txCtr: UInt64
        let closed: Bool
    }

    private let lock = NSLock()
    private let callIdL: String
    private let sendDirection: InnerSealV2.Direction
    private let receiveDirection: InnerSealV2.Direction
    private let nowMs: @Sendable () -> Int
    private var table: RoundSlotTable<InnerRoundKeys>
    /// The last counter consumed. 0 before the first seal.
    private var txCtr: UInt64 = 0
    private var window = InnerAudioReplayWindow()
    /// The same for the video kind: its own counter and its own window.
    private var txVideoCtr: UInt64 = 0
    private var videoWindow = InnerAudioReplayWindow()
    private let withVideo: Bool
    private var closed = false

    init(callIdL: String, role: LiveCallCrypto.Role, withVideo: Bool = false, nowMs: @escaping @Sendable () -> Int) {
        self.withVideo = withVideo
        self.callIdL = callIdL
        self.sendDirection = role == .offerer ? .offererToAcceptor : .acceptorToOfferer
        self.receiveDirection = role == .offerer ? .acceptorToOfferer : .offererToAcceptor
        self.nowMs = nowMs
        self.table = RoundSlotTable<InnerRoundKeys>(wipe: { $0.wipe() })
    }

    // MARK: Mutators (reached only from LiveCallCrypto)

    /// Round 0 from the round-1 session key. The send pointer is on it from install. False when the keys cannot be derived.
    func stageRound0(sessionKey: Data) -> Bool {
        guard let keys = prepare(sessionKey: sessionKey) else { return false }
        lock.lock()
        defer { lock.unlock() }
        if closed {
            keys.wipe()
            return false
        }
        table.stageSending(epoch: 0, payload: keys)
        return true
    }

    /// The two audio keys of a round, in buffers of their own. Touches no state.
    func prepare(sessionKey: Data) -> InnerRoundKeys? {
        guard let o2a = InnerSealV2.deriveKeyBuffer(
                sessionKey: sessionKey, callIdL: callIdL, kind: .audio, direction: .offererToAcceptor) else { return nil }
        guard let a2o = InnerSealV2.deriveKeyBuffer(
                sessionKey: sessionKey, callIdL: callIdL, kind: .audio, direction: .acceptorToOfferer) else {
            o2a.wipe()
            return nil
        }
        var keys = InnerRoundKeys(offererToAcceptor: o2a, acceptorToOfferer: a2o)
        if withVideo {
            guard let videoO2A = InnerSealV2.deriveKeyBuffer(
                    sessionKey: sessionKey, callIdL: callIdL, kind: .video, direction: .offererToAcceptor) else {
                keys.wipe()
                return nil
            }
            keys.videoOffererToAcceptor = videoO2A
            guard let videoA2O = InnerSealV2.deriveKeyBuffer(
                    sessionKey: sessionKey, callIdL: callIdL, kind: .video, direction: .acceptorToOfferer) else {
                keys.wipe()
                return nil
            }
            keys.videoAcceptorToOfferer = videoA2O
        }
        return keys
    }

    /// What would refuse the slot of `epoch` now. Read-only: nothing is erased or written.
    func refusal(forEpoch epoch: Int32) -> InnerStageRefusal? {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        return table.refusal(forEpoch: epoch, nowMs: nowMs())
    }

    /// Takes the prepared keys as the slot of `epoch`. On a refusal nothing changed and the prepared keys are wiped.
    func install(epoch: Int32, prepared: InnerRoundKeys) -> InnerStageRefusal? {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            prepared.wipe()
            return .closed
        }
        if let refusal = table.install(epoch: epoch, payload: prepared, nowMs: nowMs()) {
            prepared.wipe()
            return refusal
        }
        return nil
    }

    /// The peer's key confirmation of `epoch` verified: the only mover of the send pointer. Nil when nothing moved.
    func peerKcmac(epoch: Int32) -> InnerSendMove? {
        lock.lock()
        defer { lock.unlock() }
        if closed { return nil }
        return table.peerConfirmed(epoch: epoch, nowMs: nowMs())
    }

    /// Erases a staged round that failed (never round 0, never a verified round).
    func abandon(epoch: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        table.abandon(epoch: epoch)
    }

    /// Every key is wiped, the counter and the window are dropped, every later call refuses. Idempotent.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        closed = true
        table.removeAll()
        txCtr = 0
        window = InnerAudioReplayWindow()
        txVideoCtr = 0
        videoWindow = InnerAudioReplayWindow()
    }

    // MARK: Media path

    public func sealAudio(block: Data) -> InnerSealOutcome {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .refused(.closed) }
        table.sweep(nowMs: nowMs())
        guard let slot = table.sendSlot() else { return .refused(.noSendSlot) }
        let ctr = txCtr &+ 1
        guard ctr <= InnerSealV2.maxCounter else { return .refused(.ctrExhausted) }
        // Consumed before the cipher runs: a failed seal never repeats a value.
        txCtr = ctr
        let keyBuffer = sendDirection == .offererToAcceptor ? slot.payload.offererToAcceptor : slot.payload.acceptorToOfferer
        var sealed: Data?
        _ = keyBuffer.withBytes { raw in
            sealed = InnerSealV2.seal(
                key: SymmetricKey(data: raw), callIdL: callIdL, direction: sendDirection, kind: .audio, epoch: slot.epoch, ctr: ctr,
                plaintext: block)
        }
        guard let wire = sealed else { return .refused(.sealFailed) }
        return .sealed(wire: wire, ctr: ctr, epochByte: slot.byte)
    }

    public func openAudio(wire: Data) -> InnerOpenOutcome {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .dropped(.closed) }
        table.sweep(nowMs: nowMs())
        let parsed = InnerSealV2.parse(wire)
        guard case .envelope(let eByte, let ctr, let ciphertext) = parsed else {
            return .dropped(parsed == .unknownType ? .unknownType : .malformed)
        }
        guard let slot = table.slot(forByte: eByte) else { return .dropped(.noSlot) }
        switch window.check(ctr) {
        case .fresh: break
        case .duplicate: return .dropped(.replay)
        case .tooOld: return .dropped(.tooOld)
        }
        let keyBuffer = receiveDirection == .offererToAcceptor ? slot.payload.offererToAcceptor : slot.payload.acceptorToOfferer
        var opened: Data?
        _ = keyBuffer.withBytes { raw in
            opened = InnerSealV2.open(
                key: SymmetricKey(data: raw), callIdL: callIdL, direction: receiveDirection, kind: .audio, epoch: slot.epoch, ctr: ctr,
                ciphertextAndTag: ciphertext)
        }
        guard let block = opened else { return .dropped(.aead) }
        // Authenticated: recorded now, whatever the block turns out to hold.
        guard window.commit(ctr) == .fresh else { return .dropped(.replay) }
        return .opened(block: block, ctr: ctr)
    }

    public func sealVideo(fragment: Data) -> InnerSealOutcome {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .refused(.closed) }
        table.sweep(nowMs: nowMs())
        guard let slot = table.sendSlot() else { return .refused(.noSendSlot) }
        let ctr = txVideoCtr &+ 1
        guard ctr <= InnerSealV2.maxCounter else { return .refused(.ctrExhausted) }
        // Consumed before the cipher runs: a failed seal never repeats a value.
        txVideoCtr = ctr
        let keyBuffer = sendDirection == .offererToAcceptor ? slot.payload.videoOffererToAcceptor : slot.payload.videoAcceptorToOfferer
        guard let buffer = keyBuffer else { return .refused(.sealFailed) }
        var sealed: Data?
        _ = buffer.withBytes { raw in
            sealed = InnerSealV2.seal(
                key: SymmetricKey(data: raw), callIdL: callIdL, direction: sendDirection, kind: .video, epoch: slot.epoch, ctr: ctr,
                plaintext: fragment)
        }
        guard let wire = sealed else { return .refused(.sealFailed) }
        return .sealed(wire: wire, ctr: ctr, epochByte: slot.byte)
    }

    public func openVideo(wire: Data) -> InnerOpenOutcome {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .dropped(.closed) }
        table.sweep(nowMs: nowMs())
        let parsed = InnerSealV2.parse(wire)
        guard case .envelope(let eByte, let ctr, let ciphertext) = parsed else {
            return .dropped(parsed == .unknownType ? .unknownType : .malformed)
        }
        guard let slot = table.slot(forByte: eByte) else { return .dropped(.noSlot) }
        switch videoWindow.check(ctr) {
        case .fresh: break
        case .duplicate: return .dropped(.replay)
        case .tooOld: return .dropped(.tooOld)
        }
        let keyBuffer = receiveDirection == .offererToAcceptor ? slot.payload.videoOffererToAcceptor : slot.payload.videoAcceptorToOfferer
        guard let buffer = keyBuffer else { return .dropped(.noSlot) }
        var opened: Data?
        _ = buffer.withBytes { raw in
            opened = InnerSealV2.open(
                key: SymmetricKey(data: raw), callIdL: callIdL, direction: receiveDirection, kind: .video, epoch: slot.epoch, ctr: ctr,
                ciphertextAndTag: ciphertext)
        }
        guard let fragment = opened else { return .dropped(.aead) }
        guard videoWindow.commit(ctr) == .fresh else { return .dropped(.replay) }
        return .opened(block: fragment, ctr: ctr)
    }

    // MARK: Reads

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// The round the send pointer is on; nil once closed.
    var sendEpoch: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return closed || table.sendEpoch < 0 ? nil : table.sendEpoch
    }

    var slotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return table.slots.count
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            send: table.sendEpoch, current: table.currentEpoch, epochs: table.slots.map { $0.epoch }.sorted(),
            verified: table.slots.filter { $0.verifiedAtMs != nil }.map { $0.epoch }.sorted(), txCtr: txCtr, closed: closed)
    }

    // MARK: Test seams

    /// Records a counter as received (the state a frame leaves behind), without a frame.
    func commitReceivedCounterForTesting(_ ctr: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        window.commit(ctr)
    }

    /// Every key buffer of the live slots, to check the wipe.
    func keyBuffersForTesting() -> [ChainKeyBuffer] {
        lock.lock()
        defer { lock.unlock() }
        var out: [ChainKeyBuffer] = []
        for slot in table.slots {
            out.append(slot.payload.offererToAcceptor)
            out.append(slot.payload.acceptorToOfferer)
            if let buffer = slot.payload.videoOffererToAcceptor { out.append(buffer) }
            if let buffer = slot.payload.videoAcceptorToOfferer { out.append(buffer) }
        }
        return out
    }
}

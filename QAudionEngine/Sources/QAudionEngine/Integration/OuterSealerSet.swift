import Foundation
import CryptoKit

// The outer relay layer of ONE call: one set shared by both legs and by the audio and video kinds, with the epoch dimension from
// the start. Created and owned by `LiveCallCrypto`; the media paths get only the narrow `OuterSealPort`.
//
//     N     = 0x52 || u8(E mod 256) || dirTag(d) || kindTag(k) || BE64(ctr[k][d])      dirTag o2a = 1, a2o = 2; kindTag audio = 1, video = 2
//     frame = N(12) || AES-256-GCM(kOut[k][d], N, aad = empty, payload)               ciphertext || tag(16)
//
// Rules of the file:
// - one `NSLock`, a LEAF lock: nothing is called out while it is held (the clock is the only closure); the cipher runs outside it;
// - a counter is consumed BEFORE the cipher runs (a failed seal never repeats a value), the replay window records AFTER the open
//   succeeded and only if the slot that opened the frame is still the same slot (by serial), and neither is ever reset in a call;
// - byte 1 of the nonce is 0 unless `rot` (`relayRotV1`); the first frame of each (kind, direction) carries counter 0;
// - there is no timer: the trial of the caller, the retention of the slots and the hold are evaluated lazily by `tick`, which every
//   entry point runs first with the same clock reading it then uses;
// - the events of a frame (a send switch, a revert, an erase, a higher receive epoch) are handed to the sink after the lock is
//   released; every other entry point RETURNS its events and never calls the sink; `close()` returns nothing and drops the sink.

// MARK: - Outcomes and events

/// What the media paths see. The raw values are the numbers of the log line.
public enum OuterSealRefusal: Int, Equatable, Sendable {
    case closed = 1
    case noSendSlot = 2
    case ctrExhausted = 3
    case sealFailed = 4
}

public enum OuterSealOutcome: Equatable, Sendable {
    case sealed(wire: Data, epoch: Int32)
    case refused(OuterSealRefusal)
}

/// Why an outer frame was not delivered. The raw values are the numbers of the log line.
public enum OuterFailure: Int, Equatable, Sendable {
    case closed = 1
    case short = 2
    case noncePrefix = 3
    case dirTag = 4
    case kindTag = 5
    case epochByte = 6
    case noSlot = 7
    case replay = 8
    case tooOld = 9
    case aead = 10
    case malformed = 11
}

public enum OuterOpenOutcome: Equatable, Sendable {
    case opened(payload: Data, epoch: Int32)
    /// `nth` counts the drops of this reason since the set was created.
    case dropped(OuterFailure, nth: Int)
}

/// Seals and opens, and says which round it seals under. Every call re-checks the owner, so the port of a closed set refuses.
public protocol OuterSealPort: AnyObject, Sendable {
    func seal(_ kind: InnerSealV2.Kind, _ payload: Data) -> OuterSealOutcome
    func open(_ kind: InnerSealV2.Kind, _ wire: Data) -> OuterOpenOutcome
    /// The round the send pointer is on; -1 once the set is closed.
    func sendEpoch() -> Int32
}

public struct OuterSwitchEvent: Equatable, Sendable {
    public let from: Int32
    public let to: Int32
    /// The caller's 3 s trial started with this move.
    public let trial: Bool

    public init(from: Int32, to: Int32, trial: Bool) {
        self.from = from
        self.to = to
        self.trial = trial
    }
}

public struct OuterRevertEvent: Equatable, Sendable {
    public let from: Int32
    public let to: Int32

    public init(from: Int32, to: Int32) {
        self.from = from
        self.to = to
    }
}

public struct OuterEraseEvent: Equatable, Sendable {
    public enum Why: Int, Equatable, Sendable {
        case retention = 1
        case abandon = 2
        case close = 3
    }

    public let epoch: Int32
    public let why: Why

    public init(epoch: Int32, why: Why) {
        self.epoch = epoch
        self.why = why
    }
}

public struct OuterEvents: Equatable, Sendable {
    public var switched: OuterSwitchEvent?
    public var reverted: OuterRevertEvent?
    public var erased: [OuterEraseEvent]
    /// The highest epoch that authenticated a frame increased to this value.
    public var rxEpoch: Int32?

    public init() {
        switched = nil
        reverted = nil
        erased = []
        rxEpoch = nil
    }

    public var isEmpty: Bool {
        switched == nil && reverted == nil && erased.isEmpty && rxEpoch == nil
    }

    mutating func merge(_ other: OuterEvents) {
        if let value = other.switched { switched = value }
        if let value = other.reverted { reverted = value }
        erased.append(contentsOf: other.erased)
        if let value = other.rxEpoch { rxEpoch = value }
    }
}

enum OuterInstallResult: Equatable, Sendable {
    case ok
    case duplicate
    case slotCollision
    case pendingFull
    case badEpoch
    case notRotating
    case closed
}

struct OuterInstallReport: Equatable, Sendable {
    let result: OuterInstallResult
    let events: OuterEvents
}

/// What the tests read: epochs and counters, never bytes.
struct OuterSnapshot: Equatable, Sendable {
    let send: Int32
    let current: Int32
    let epochs: [Int32]
    let verified: [Int32]
    let txAudio: UInt64
    let txVideo: UInt64
    let trialEndsAt: Int?
    let closed: Bool
}

// MARK: - Slot table

/// The round slots of one call with the policies of the outer layer. Not thread-safe: the owner holds its lock around every call and
/// passes the time in.
///
/// Callee: the send pointer moves forward only, when the peer's confirmation of E > S verified AND a frame of E authenticated (in
/// either order). Caller: the pointer moves to E > S at the peer's confirmation and a 3 s trial starts; a frame of E under the trial
/// makes it permanent; the end of the trial without one puts the pointer back on the epoch of the last authenticated frame; a hold
/// of the peer pauses the trial and defers a move. A verified slot that is not S and has a verified slot above it is erased 10 s after
/// its last authenticated frame, or, if it never had one, 10 s after the later of becoming non-current and 30 s after our own
/// confirmation of its round. Nothing is erased to make room; a full table refuses.
struct OuterRoundTable {

    enum Policy {
        case caller
        case callee
    }

    struct Slot {
        let serial: UInt64
        let epoch: Int32
        let byte: UInt8
        var verified: Bool
        var verifiedAtMs: Int?
        var lastAuthMs: Int?
        var kcmacSentMs: Int?
        let keys: OuterRoundKeys
    }

    static let sendTrialMs = 3000
    static let retentionMs = 10_000
    static let kcmacWindowMs = 30_000
    static let maxStaged = KcMacRoundBook.maxPendingRounds

    let policy: Policy
    private(set) var slots: [Slot] = []
    private(set) var sendEpoch: Int32 = -1
    private(set) var currentEpoch: Int32 = -1
    private var nextSerial: UInt64 = 1
    private var lastRxEpoch: Int32?
    private var trialTarget: Int32?
    private var trialEndsAt = 0
    private var fallbackS: Int32 = -1
    private var hold = false
    private var holdRemaining: Int?
    private var pendingMove: Int32?

    init(policy: Policy) {
        self.policy = policy
    }

    // MARK: Reads

    func slot(forByte byte: UInt8) -> Slot? {
        slots.first(where: { $0.byte == byte })
    }

    func slot(forSerial serial: UInt64) -> Slot? {
        slots.first(where: { $0.serial == serial })
    }

    func sendSlot() -> Slot? {
        if sendEpoch < 0 { return nil }
        return slots.first(where: { $0.epoch == sendEpoch })
    }

    var trialEnd: Int? {
        trialTarget != nil ? trialEndsAt : nil
    }

    private func find(_ epoch: Int32) -> Int? {
        slots.firstIndex(where: { $0.epoch == epoch })
    }

    /// The rounds a sweep at `nowMs` would erase, on the table as it is.
    func dueEpochs(nowMs: Int) -> [Int32] {
        var due: [Int32] = []
        for slot in slots {
            if let deadline = deadline(of: slot), deadline <= nowMs { due.append(slot.epoch) }
        }
        return due
    }

    /// What would refuse a slot of `epoch`, judged against the slots that survive a sweep at `nowMs`. Nothing is changed.
    func refusal(forEpoch epoch: Int32, nowMs: Int) -> OuterInstallResult? {
        if epoch < 0 { return .badEpoch }
        let due = dueEpochs(nowMs: nowMs)
        let alive = slots.filter { !due.contains($0.epoch) }
        if alive.contains(where: { $0.epoch == epoch }) { return .duplicate }
        let byte = UInt8(truncatingIfNeeded: epoch)
        if alive.contains(where: { $0.byte == byte }) { return .slotCollision }
        if alive.filter({ !$0.verified }).count >= Self.maxStaged { return .pendingFull }
        return nil
    }

    private func deadline(of slot: Slot) -> Int? {
        if !slot.verified || slot.epoch == sendEpoch { return nil }
        // a running trial may still revert to these two: they are kept until it ends
        if trialTarget != nil, slot.epoch == fallbackS || slot.epoch == lastRxEpoch { return nil }
        var above: Int?
        for other in slots where other.verified && other.epoch > slot.epoch {
            if let at = other.verifiedAtMs {
                above = above.map { min($0, at) } ?? at
            }
        }
        guard let nonCurrentAt = above else { return nil }
        if let last = slot.lastAuthMs { return last + Self.retentionMs }
        let windowEnd = slot.kcmacSentMs.map { $0 + Self.kcmacWindowMs } ?? nonCurrentAt
        return max(nonCurrentAt, windowEnd) + Self.retentionMs
    }

    // MARK: Mutations

    /// Takes the slot of `epoch` (staged), sweeping first. `sendFromInstall` (round 0) puts the send pointer on it. On a refusal
    /// nothing changed and the keys stay with the caller.
    mutating func stage(epoch: Int32, keys: OuterRoundKeys, sendFromInstall: Bool, nowMs: Int) -> (result: OuterInstallResult, events: OuterEvents) {
        var events = OuterEvents()
        sweep(nowMs: nowMs, into: &events)
        if let why = refusal(forEpoch: epoch, nowMs: nowMs) { return (why, events) }
        slots.append(Slot(serial: nextSerial, epoch: epoch, byte: UInt8(truncatingIfNeeded: epoch), verified: false, verifiedAtMs: nil,
                          lastAuthMs: nil, kcmacSentMs: nil, keys: keys))
        nextSerial += 1
        if sendFromInstall { sendEpoch = epoch }
        return (.ok, events)
    }

    /// Our own confirmation of `epoch` was handed to the transport (the first time only).
    mutating func markKcmacSent(epoch: Int32, nowMs: Int) {
        guard let index = find(epoch), slots[index].kcmacSentMs == nil else { return }
        slots[index].kcmacSentMs = nowMs
    }

    /// The peer's confirmation of `epoch` verified: the slot becomes verified, `current` follows and the policy may move the pointer.
    mutating func peerKcmac(epoch: Int32, nowMs: Int) -> OuterEvents {
        var events = OuterEvents()
        guard let index = find(epoch) else {
            sweep(nowMs: nowMs, into: &events)
            return events
        }
        if !slots[index].verified {
            slots[index].verified = true
            slots[index].verifiedAtMs = nowMs
        }
        if epoch > currentEpoch { currentEpoch = epoch }
        if epoch > sendEpoch {
            switch policy {
            case .callee:
                if slots[index].lastAuthMs != nil { moveSend(to: epoch, trial: false, into: &events) }
            case .caller:
                if hold {
                    pendingMove = pendingMove.map { max($0, epoch) } ?? epoch
                } else {
                    startTrial(epoch, nowMs: nowMs, into: &events)
                }
            }
        }
        sweep(nowMs: nowMs, into: &events)
        return events
    }

    /// A frame passed the replay check, the cipher and the commit under the slot `serial`. A slot that is gone is ignored.
    mutating func authenticated(serial: UInt64, nowMs: Int) -> OuterEvents {
        var events = OuterEvents()
        guard let index = slots.firstIndex(where: { $0.serial == serial }) else { return events }
        slots[index].lastAuthMs = nowMs
        let epoch = slots[index].epoch
        let isVerified = slots[index].verified
        switch policy {
        case .callee:
            if isVerified && epoch > sendEpoch { moveSend(to: epoch, trial: false, into: &events) }
        case .caller:
            lastRxEpoch = epoch
            if let target = trialTarget {
                // the callee answered under the trial epoch: the move is for good
                if epoch == target { trialTarget = nil }
            } else if isVerified && epoch > sendEpoch {
                moveSend(to: epoch, trial: false, into: &events)
            }
        }
        sweep(nowMs: nowMs, into: &events)
        return events
    }

    /// The caller's CALL_HOLD: the peer sends no media. The trial pauses and a move waits until media resumes.
    mutating func setHold(_ on: Bool, nowMs: Int) -> OuterEvents {
        var events = OuterEvents()
        guard policy == .caller, on != hold else { return events }
        hold = on
        if on {
            if trialTarget != nil { holdRemaining = max(0, trialEndsAt - nowMs) }
            return events
        }
        if let remaining = holdRemaining {
            trialEndsAt = nowMs + remaining
            holdRemaining = nil
        }
        if let target = pendingMove {
            pendingMove = nil
            if let index = find(target), slots[index].verified, target > sendEpoch {
                startTrial(target, nowMs: nowMs, into: &events)
            }
        }
        sweep(nowMs: nowMs, into: &events)
        return events
    }

    /// Erases a STAGED slot (its round failed): never a verified slot, never the send slot.
    mutating func abandon(epoch: Int32) -> OuterEvents {
        var events = OuterEvents()
        guard let index = find(epoch), !slots[index].verified, epoch != sendEpoch else { return events }
        slots[index].keys.wipe()
        slots.remove(at: index)
        events.erased.append(OuterEraseEvent(epoch: epoch, why: .abandon))
        return events
    }

    /// Time passes: the end of the caller's trial, then the retention pass.
    mutating func tick(nowMs: Int) -> OuterEvents {
        var events = OuterEvents()
        if trialTarget != nil && !hold && nowMs >= trialEndsAt {
            // no frame of the trial epoch: back to the epoch of the last authenticated frame (or the one left)
            let want = lastRxEpoch ?? fallbackS
            let to: Int32
            if find(want) != nil {
                to = want
            } else if find(fallbackS) != nil {
                to = fallbackS
            } else {
                to = sendEpoch
            }
            let from = sendEpoch
            trialTarget = nil
            sendEpoch = to
            events.reverted = OuterRevertEvent(from: from, to: to)
        }
        sweep(nowMs: nowMs, into: &events)
        return events
    }

    /// Every key is wiped and every slot dropped.
    mutating func removeAll() {
        for slot in slots { slot.keys.wipe() }
        slots.removeAll()
    }

    // MARK: Internals

    private mutating func moveSend(to epoch: Int32, trial: Bool, into events: inout OuterEvents) {
        events.switched = OuterSwitchEvent(from: sendEpoch, to: epoch, trial: trial)
        sendEpoch = epoch
    }

    private mutating func startTrial(_ epoch: Int32, nowMs: Int, into events: inout OuterEvents) {
        if trialTarget == nil { fallbackS = sendEpoch }
        moveSend(to: epoch, trial: true, into: &events)
        trialTarget = epoch
        trialEndsAt = nowMs + Self.sendTrialMs
    }

    /// The due set is computed on the table as it is and then erased, so erasing one slot never postpones another.
    private mutating func sweep(nowMs: Int, into events: inout OuterEvents) {
        let due = dueEpochs(nowMs: nowMs)
        if due.isEmpty { return }
        for epoch in due.sorted() {
            guard let index = find(epoch) else { continue }
            slots[index].keys.wipe()
            slots.remove(at: index)
            events.erased.append(OuterEraseEvent(epoch: epoch, why: .retention))
        }
    }
}

// MARK: - The set

final class OuterSealerSet: @unchecked Sendable {

    static let noncePrefix: UInt8 = 0x52
    static let nonceBytes = 12
    static let tagBytes = 16

    private let lock = NSLock()
    private let role: LiveCallCrypto.Role
    private let rot: Bool
    private let sendDirection: InnerSealV2.Direction
    private let receiveDirection: InnerSealV2.Direction
    private let nowMs: @Sendable () -> Int
    private var table: OuterRoundTable
    /// The NEXT counter per kind, our direction. The first frame of each kind carries 0.
    private var txAudio: UInt64 = 0
    private var txVideo: UInt64 = 0
    private var rxAudio = InnerAudioReplayWindow()
    private var rxVideo = InnerAudioReplayWindow()
    private var drops = [Int](repeating: 0, count: 12)
    private var rxHighEpoch: Int32 = -1
    private var closed = false
    private var sink: (@Sendable (OuterEvents) -> Void)?

    init(role: LiveCallCrypto.Role, rot: Bool, nowMs: @escaping @Sendable () -> Int) {
        self.role = role
        self.rot = rot
        // The caller (offerer) seals with o2a, whatever the user ids say.
        self.sendDirection = role == .offerer ? .offererToAcceptor : .acceptorToOfferer
        self.receiveDirection = role == .offerer ? .acceptorToOfferer : .offererToAcceptor
        self.nowMs = nowMs
        self.table = OuterRoundTable(policy: role == .offerer ? .caller : .callee)
    }

    // MARK: Install and the policy mutators (reached only from LiveCallCrypto)

    /// Round 1: the slot of `epoch` (0 except in the known-answer scripts), sealing from install. On a refusal the keys are wiped.
    func installRound0(_ keys: OuterRoundKeys, epoch: Int32 = 0) -> OuterInstallReport {
        lock.lock()
        defer { lock.unlock() }
        if closed {
            keys.wipe()
            return OuterInstallReport(result: .closed, events: OuterEvents())
        }
        let now = nowMs()
        var events = table.tick(nowMs: now)
        let staged = table.stage(epoch: epoch, keys: keys, sendFromInstall: true, nowMs: now)
        events.merge(staged.events)
        if staged.result != .ok { keys.wipe() }
        return OuterInstallReport(result: staged.result, events: events)
    }

    /// A rekey round (only with `rot`), before our own confirmation of the round leaves. On a refusal nothing changed and the
    /// keys are wiped.
    func install(epoch: Int32, keys: OuterRoundKeys) -> OuterInstallReport {
        lock.lock()
        defer { lock.unlock() }
        if closed || !rot {
            keys.wipe()
            return OuterInstallReport(result: closed ? .closed : .notRotating, events: OuterEvents())
        }
        let now = nowMs()
        var events = table.tick(nowMs: now)
        let staged = table.stage(epoch: epoch, keys: keys, sendFromInstall: false, nowMs: now)
        events.merge(staged.events)
        if staged.result != .ok { keys.wipe() }
        return OuterInstallReport(result: staged.result, events: events)
    }

    /// What would refuse a slot of `epoch` now. Read-only: nothing is erased or written.
    func refusal(epoch: Int32) -> OuterInstallResult? {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        if !rot && epoch != 0 { return .notRotating }
        return table.refusal(forEpoch: epoch, nowMs: nowMs())
    }

    func markKcmacSent(epoch: Int32) -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        if closed { return OuterEvents() }
        let now = nowMs()
        let events = table.tick(nowMs: now)
        table.markKcmacSent(epoch: epoch, nowMs: now)
        return events
    }

    func peerKcmac(epoch: Int32) -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        if closed { return OuterEvents() }
        let now = nowMs()
        var events = table.tick(nowMs: now)
        events.merge(table.peerKcmac(epoch: epoch, nowMs: now))
        return events
    }

    /// Erases a staged slot of ours (never round 0, never the send slot).
    func abandon(epoch: Int32) -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        if closed { return OuterEvents() }
        var events = table.tick(nowMs: nowMs())
        if epoch != 0 { events.merge(table.abandon(epoch: epoch)) }
        return events
    }

    func setHold(_ on: Bool) -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        if closed { return OuterEvents() }
        let now = nowMs()
        var events = table.tick(nowMs: now)
        events.merge(table.setHold(on, nowMs: now))
        return events
    }

    func tick() -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        if closed { return OuterEvents() }
        return table.tick(nowMs: nowMs())
    }

    /// The owner's receiver of the events born inside `seal` and `open`. Called with no lock held.
    func setEventSink(_ newSink: (@Sendable (OuterEvents) -> Void)?) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    /// Every key is wiped, the counters and windows are dropped, every later call refuses. Idempotent. Returns nothing, calls nothing.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        closed = true
        sink = nil
        table.removeAll()
        txAudio = 0
        txVideo = 0
        rxAudio = InnerAudioReplayWindow()
        rxVideo = InnerAudioReplayWindow()
    }

    /// A port for the media paths. The caller keeps it (one per set): the set does not hold its port.
    func makePort() -> OuterSealPort {
        OuterSetPort(set: self)
    }

    // MARK: Media path

    func seal(_ kind: InnerSealV2.Kind, _ payload: Data) -> OuterSealOutcome {
        sealInternal(kind, payload, fixedCtr: nil)
    }

    private struct SealPrep {
        let outcome: OuterSealOutcome?
        let events: OuterEvents
        let key: SymmetricKey?
        let nonce: Data
        let epoch: Int32
    }

    private func prepareSeal(_ kind: InnerSealV2.Kind, fixedCtr: UInt64?) -> SealPrep {
        lock.lock()
        defer { lock.unlock() }
        if closed { return SealPrep(outcome: .refused(.closed), events: OuterEvents(), key: nil, nonce: Data(), epoch: -1) }
        let events = table.tick(nowMs: nowMs())
        guard let slot = table.sendSlot() else {
            return SealPrep(outcome: .refused(.noSendSlot), events: events, key: nil, nonce: Data(), epoch: -1)
        }
        let ctr: UInt64
        if let fixed = fixedCtr {
            ctr = fixed
        } else {
            ctr = kind == .audio ? txAudio : txVideo
            guard ctr <= InnerSealV2.maxCounter else {
                return SealPrep(outcome: .refused(.ctrExhausted), events: events, key: nil, nonce: Data(), epoch: slot.epoch)
            }
            // consumed before the cipher runs: a failed seal never repeats a value
            if kind == .audio { txAudio = ctr &+ 1 } else { txVideo = ctr &+ 1 }
        }
        let buffer = slot.keys.key(kind: kind, direction: sendDirection)
        guard let key = buffer.withBytes({ SymmetricKey(data: $0) }) else {
            return SealPrep(outcome: .refused(.sealFailed), events: events, key: nil, nonce: Data(), epoch: slot.epoch)
        }
        let nonce = Self.nonce(epochByte: slot.byte, rot: rot, direction: sendDirection, kind: kind, ctr: ctr)
        return SealPrep(outcome: nil, events: events, key: key, nonce: nonce, epoch: slot.epoch)
    }

    private func sealInternal(_ kind: InnerSealV2.Kind, _ payload: Data, fixedCtr: UInt64?) -> OuterSealOutcome {
        let prep = prepareSeal(kind, fixedCtr: fixedCtr)
        deliver(prep.events)
        if let outcome = prep.outcome { return outcome }
        guard let key = prep.key,
              let gcmNonce = try? AES.GCM.Nonce(data: prep.nonce),
              let box = try? AES.GCM.seal(payload, using: key, nonce: gcmNonce) else { return .refused(.sealFailed) }
        var wire = prep.nonce
        wire.append(box.ciphertext)
        wire.append(box.tag)
        return .sealed(wire: wire, epoch: prep.epoch)
    }

    private enum OpenPrep {
        case done(OuterOpenOutcome, OuterEvents)
        case work(serial: UInt64, epoch: Int32, key: SymmetricKey, ctr: UInt64, events: OuterEvents)
    }

    private func drop(_ reason: OuterFailure) -> Int {
        drops[reason.rawValue] += 1
        return drops[reason.rawValue]
    }

    private func prepareOpen(_ kind: InnerSealV2.Kind, _ wire: Data) -> OpenPrep {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .done(.dropped(.closed, nth: drop(.closed)), OuterEvents()) }
        let events = table.tick(nowMs: nowMs())
        let base = wire.startIndex
        guard wire.count >= Self.nonceBytes + Self.tagBytes else { return .done(.dropped(.short, nth: drop(.short)), events) }
        guard wire[base] == Self.noncePrefix else { return .done(.dropped(.noncePrefix, nth: drop(.noncePrefix)), events) }
        guard wire[base + 2] == receiveDirection.tag else { return .done(.dropped(.dirTag, nth: drop(.dirTag)), events) }
        guard wire[base + 3] == kind.tag else { return .done(.dropped(.kindTag, nth: drop(.kindTag)), events) }
        if !rot && wire[base + 1] != 0 { return .done(.dropped(.epochByte, nth: drop(.epochByte)), events) }
        guard let slot = table.slot(forByte: wire[base + 1]) else { return .done(.dropped(.noSlot, nth: drop(.noSlot)), events) }
        var ctr: UInt64 = 0
        for offset in 4 ..< 12 { ctr = (ctr << 8) | UInt64(wire[base + offset]) }
        guard ctr <= InnerSealV2.maxCounter else { return .done(.dropped(.malformed, nth: drop(.malformed)), events) }
        switch (kind == .audio ? rxAudio : rxVideo).check(ctr) {
        case .fresh: break
        case .duplicate: return .done(.dropped(.replay, nth: drop(.replay)), events)
        case .tooOld: return .done(.dropped(.tooOld, nth: drop(.tooOld)), events)
        }
        let buffer = slot.keys.key(kind: kind, direction: receiveDirection)
        guard let key = buffer.withBytes({ SymmetricKey(data: $0) }) else {
            return .done(.dropped(.noSlot, nth: drop(.noSlot)), events)
        }
        return .work(serial: slot.serial, epoch: slot.epoch, key: key, ctr: ctr, events: events)
    }

    private func commitOpen(_ kind: InnerSealV2.Kind, serial: UInt64, epoch: Int32, ctr: UInt64, payload: Data) -> (OuterOpenOutcome, OuterEvents) {
        lock.lock()
        defer { lock.unlock() }
        if closed { return (.dropped(.closed, nth: drop(.closed)), OuterEvents()) }
        // a slot erased while the cipher ran: nothing is recorded
        guard table.slot(forSerial: serial) != nil else { return (.dropped(.noSlot, nth: drop(.noSlot)), OuterEvents()) }
        let verdict: InnerAudioReplayWindow.Verdict
        if kind == .audio { verdict = rxAudio.commit(ctr) } else { verdict = rxVideo.commit(ctr) }
        guard verdict == .fresh else { return (.dropped(.replay, nth: drop(.replay)), OuterEvents()) }
        var events = table.authenticated(serial: serial, nowMs: nowMs())
        if epoch > rxHighEpoch {
            rxHighEpoch = epoch
            events.rxEpoch = epoch
        }
        return (.opened(payload: payload, epoch: epoch), events)
    }

    func open(_ kind: InnerSealV2.Kind, _ wire: Data) -> OuterOpenOutcome {
        switch prepareOpen(kind, wire) {
        case .done(let outcome, let events):
            deliver(events)
            return outcome
        case .work(let serial, let epoch, let key, let ctr, let tickEvents):
            deliver(tickEvents)
            let base = wire.startIndex
            let nonceData = Data(wire[base ..< base + Self.nonceBytes])
            let ciphertext = Data(wire[base + Self.nonceBytes ..< wire.endIndex - Self.tagBytes])
            let tag = Data(wire[wire.endIndex - Self.tagBytes ..< wire.endIndex])
            var opened: Data?
            if let gcmNonce = try? AES.GCM.Nonce(data: nonceData),
               let box = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag) {
                opened = try? AES.GCM.open(box, using: key)
            }
            guard let payload = opened else {
                lock.lock()
                let nth = drop(.aead)
                lock.unlock()
                return .dropped(.aead, nth: nth)
            }
            let committed = commitOpen(kind, serial: serial, epoch: epoch, ctr: ctr, payload: payload)
            deliver(committed.1)
            return committed.0
        }
    }

    private func deliver(_ events: OuterEvents) {
        if events.isEmpty { return }
        lock.lock()
        let receiver = sink
        lock.unlock()
        receiver?(events)
    }

    // MARK: Reads

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// The round the send pointer is on; -1 once closed.
    func sendEpoch() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return closed ? -1 : table.sendEpoch
    }

    func snapshot() -> OuterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return OuterSnapshot(
            send: table.sendEpoch, current: table.currentEpoch, epochs: table.slots.map { $0.epoch }.sorted(),
            verified: table.slots.filter { $0.verified }.map { $0.epoch }.sorted(), txAudio: txAudio, txVideo: txVideo,
            trialEndsAt: table.trialEnd, closed: closed)
    }

    /// The number of drops of one reason (a test reads it).
    func dropCount(_ reason: OuterFailure) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return drops[reason.rawValue]
    }

    /// The key buffers of the live slots, to check the wipe.
    func keyBuffersForTesting() -> [ChainKeyBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return table.slots.flatMap { $0.keys.allBuffers }
    }

    /// Seals with a fixed counter, consuming none (the frame vectors fix the counter).
    func sealWithCounterForTesting(_ kind: InnerSealV2.Kind, _ payload: Data, ctr: UInt64) -> OuterSealOutcome {
        sealInternal(kind, payload, fixedCtr: ctr)
    }

    /// Records a counter as received, without a frame.
    func commitReceivedCounterForTesting(_ kind: InnerSealV2.Kind, ctr: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if kind == .audio { rxAudio.commit(ctr) } else { rxVideo.commit(ctr) }
    }

    // MARK: Wire

    static func nonce(epochByte: UInt8, rot: Bool, direction: InnerSealV2.Direction, kind: InnerSealV2.Kind, ctr: UInt64) -> Data {
        var out = Data([noncePrefix, rot ? epochByte : 0, direction.tag, kind.tag])
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: ctr >> UInt64(shift)))
        }
        return out
    }
}

/// The port of one set. It holds the set strongly (the set does not hold it) and refuses once the set is closed.
final class OuterSetPort: OuterSealPort, @unchecked Sendable {
    private let set: OuterSealerSet

    init(set: OuterSealerSet) {
        self.set = set
    }

    func seal(_ kind: InnerSealV2.Kind, _ payload: Data) -> OuterSealOutcome {
        set.seal(kind, payload)
    }

    func open(_ kind: InnerSealV2.Kind, _ wire: Data) -> OuterOpenOutcome {
        set.open(kind, wire)
    }

    func sendEpoch() -> Int32 {
        set.sendEpoch()
    }
}

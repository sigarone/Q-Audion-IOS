import Foundation

// The sender of ONE live share on the device that started it (WIRE_SPEC section 14.6.1). Pure logic: it never writes to a socket, to
// the outbox or to a store by itself; it calls the closures the app gives it and reports what it did.
//
// The rules it keeps (the vectors are `sender_sequences` of `location-kat.json`):
//  - The share key `k` and the counter of the next frame live ONLY in the memory of this object, inside its `LocationFrameSealer`, the
//    one sealer of the share (rule 9). The copy of the start body in the outbox is never used to seal a frame.
//  - No frame and no stop before the `msg_sent` echo of the start (rule 2): a stop is deferred until the echo, a start that never left
//    the device is withdrawn from the outbox. A start counts as left from the moment the app hands its bytes to the socket
//    (`startLeftDevice`, called BEFORE the hand-over): a stop that arrives while the send is in flight is held for the echo, it never
//    withdraws a start that then leaves anyway. If the hand-over fails before any byte is written, `startNotSent` takes the start back.
//  - One frame per tick, never closer than `TX_MIN_GAP` seconds, built only while the socket is up (rules 3 and 5). A frame that was
//    sealed has used its counter whatever happens to its write: the counter is never given back and the frame is never sealed again
//    (the write closure may throw: the error is ignored on purpose).
//  - On an end it can act on, the stop goes out at once and the final frame on the next tick, or at once when the sender cannot wait,
//    and only while the socket is up (rule 8). Then `k` is deleted.
//  - A process that starts again builds NO frame for a share that was live when the previous one died, position or final: it sends the
//    stop only (rule 10, `recoverAfterRestart`). The share is never resumed.

/// The progress of the start message of a share on the sender.
public struct LocationShareJournalEntry: Equatable, Sendable, Codable {
    public enum Phase: String, Equatable, Sendable, Codable {
        /// Waiting in the outbox: it never left the device.
        case queued
        /// Left the device, no `msg_sent` echo yet.
        case sent
        /// The server acknowledged it.
        case echoed
    }

    public let startClientMsgId: String
    public var phase: Phase
    /// The `loc_stop` already went out.
    public var stopSent: Bool

    public init(startClientMsgId: String, phase: Phase, stopSent: Bool) {
        self.startClientMsgId = startClientMsgId
        self.phase = phase
        self.stopSent = stopSent
    }
}

/// The durable note a process leaves for the next one about a share that is live: which start, how far it got and whether its stop
/// went out. NOTHING secret and nothing positional: no `k`, no counter, no `sid`, no coordinates. It exists only so that a process that
/// starts again can end the share of the one that died (rule 10).
public protocol LocationShareJournal: AnyObject {
    func write(_ entry: LocationShareJournalEntry)
    func clear(startClientMsgId: String)
    func entries() -> [LocationShareJournalEntry]
}

public final class InMemoryLocationShareJournal: LocationShareJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: LocationShareJournalEntry] = [:]

    public init() {}

    public func write(_ entry: LocationShareJournalEntry) {
        lock.lock()
        stored[entry.startClientMsgId] = entry
        lock.unlock()
    }

    public func clear(startClientMsgId: String) {
        lock.lock()
        stored[startClientMsgId] = nil
        lock.unlock()
    }

    public func entries() -> [LocationShareJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return stored.values.sorted { $0.startClientMsgId < $1.startClientMsgId }
    }
}

/// What the sender asks the app to do: hand a stop to the durable CONTROL path, or withdraw an unsent start from the outbox.
public struct LocationShareSenderEffects: Sendable {
    public var sendStop: @Sendable (_ startClientMsgId: String, _ ts: Int64) -> Void
    public var withdrawStart: @Sendable (_ startClientMsgId: String) -> Void

    public init(sendStop: @escaping @Sendable (_ startClientMsgId: String, _ ts: Int64) -> Void,
                withdrawStart: @escaping @Sendable (_ startClientMsgId: String) -> Void) {
        self.sendStop = sendStop
        self.withdrawStart = withdrawStart
    }
}

/// The newest fix the sender holds, already converted (section 14.4). `capturedAt` is on the same clock as the `now` the caller passes
/// (unix seconds), so that the frame carries `age = now - capturedAt`, clamped.
public struct LocationSenderFix: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let latE7: Int32
    public let lonE7: Int32
    public let accuracy: UInt16
    public let approximate: Bool
    public let capturedAt: Int64

    public init(latE7: Int32, lonE7: Int32, accuracy: UInt16, approximate: Bool, capturedAt: Int64) {
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.accuracy = accuracy
        self.approximate = approximate
        self.capturedAt = capturedAt
    }

    public var description: String { "LocationSenderFix(redacted)" }
    public var debugDescription: String { description }
}

/// Why a tick built no frame (the closed set `SENDER_REFUSALS` of the vector file).
public enum LocationSenderRefusal: String, CaseIterable, Equatable, Sendable {
    /// The share is over (or stopping and waiting for its final frame is not the case): nothing is built.
    case ended
    /// The socket is down: the tick is skipped and the counter does not move.
    case offline
    /// The start was not acknowledged yet.
    case noEcho = "no_echo"
    /// Less than `TX_MIN_GAP` seconds since the last position frame.
    case tooFast = "too_fast"
}

/// Where the `loc_stop` of an event went.
public enum LocationStopDelivery: String, Equatable, Sendable {
    /// Handed to the durable path now.
    case sent
    /// Held until the echo of the start.
    case deferred
}

/// How a user stop treats the final frame (section 14.6.1 rule 8).
public enum LocationFinalFrameMode: String, Equatable, Sendable {
    /// On the next regular tick, so that the cadence is not disturbed.
    case onTick = "tick"
    /// At once: the process is going away or the socket is about to be closed.
    case now
}

/// What one event of the sender did.
public struct LocationSenderOutcome: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public let counter: UInt32
        public let isFinal: Bool
        public var kind: String { isFinal ? "final" : "position" }
    }

    /// The frame that was sealed during this event, its counter spent whatever happened to the write.
    public var frame: Frame?
    public var refusal: LocationSenderRefusal?
    public var stop: LocationStopDelivery?
    /// The start was withdrawn from the outbox.
    public var outboxWithdrawn: Bool = false
    /// Whether the share key is still held after the event.
    public var keyHeld: Bool = false
    /// The counter the next frame will carry; `nil` when the key is gone.
    public var nextCounter: UInt32?

    public init() {}
}

/// The share ids that this process has already built a sender for. A `sid` is claimed ONCE and never released: a second sender for the
/// same share in the same process (a second window or scene with its own copy of the share, a retry that builds a sender beside the first,
/// a start body read back from the outbox) would seal the same counters again under the same key (section 14.6.1 rule 9), so its
/// constructor refuses.
private final class LocationShareClaims: @unchecked Sendable {
    static let shared = LocationShareClaims()
    private let lock = NSLock()
    private var sids = Set<Data>()

    func claim(_ sid: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sids.insert(sid).inserted
    }
}

public final class LocationShareSender: @unchecked Sendable {

    private let lock = NSRecursiveLock()
    private let startClientMsgId: String
    private let startedAt: Int64
    private let duration: Int64
    private let effects: LocationShareSenderEffects
    private let journal: LocationShareJournal
    private var sealer: LocationFrameSealer?
    private var phase: LocationShareJournalEntry.Phase = .queued
    /// A stop was requested and its final frame waits for the next tick.
    private var finalPending = false
    private var stopSent = false
    private var stopDeferred = false
    /// The start is being handed to the socket by THIS process and the hand-over is not settled yet (no echo, not taken back).
    private var attemptInFlight = false
    private var ended = false
    private var socketUp = true
    private var lowPower = false
    private var lastFrameAt: Int64?
    private var fix: LocationSenderFix

    /// `selfId` and `peerId` are the user id strings EXACTLY as the server sends them (36-character lowercase UUID text): they go into the
    /// additional data of every frame as their UTF-8 bytes, so an id re-serialised through a platform UUID type (upper case) would make
    /// every frame fail to authenticate on the receiver (section 14.6.3).
    /// A share the user just confirmed (section 14.6.1 rule 1): the start waits in the outbox, `k` is held here and nowhere else, and the
    /// counter of the first frame is 1. `nil` when `sid` or `shareKey` has the wrong length, or when this process already built a sender
    /// for the same `sid` (one sealer per share, section 14.6.1 rule 9).
    public init?(startClientMsgId: String, selfId: String, peerId: String, sid: Data, shareKey: Data, startedAt: Int64,
                 duration: Int64, fix: LocationSenderFix, effects: LocationShareSenderEffects, journal: LocationShareJournal) {
        guard let sealer = LocationFrameSealer(sid: sid, shareKey: shareKey, senderId: selfId, recipientId: peerId) else { return nil }
        // One sealer per share inside the process: a share id that already has a sender here cannot get a second one.
        guard LocationShareClaims.shared.claim(sid) else { return nil }
        self.startClientMsgId = startClientMsgId
        self.startedAt = startedAt
        self.duration = duration
        self.effects = effects
        self.journal = journal
        self.sealer = sealer
        self.fix = fix
        journal.write(LocationShareJournalEntry(startClientMsgId: startClientMsgId, phase: .queued, stopSent: false))
    }

    /// The sender of a share that a previous process left, with no key and no counter (private: see `recoverAfterRestart`).
    private init(entry: LocationShareJournalEntry, effects: LocationShareSenderEffects, journal: LocationShareJournal) {
        self.startClientMsgId = entry.startClientMsgId
        self.startedAt = 0
        self.duration = 0
        self.effects = effects
        self.journal = journal
        self.sealer = nil
        self.phase = entry.phase
        self.stopSent = entry.stopSent
        self.ended = true
        self.fix = LocationSenderFix(latE7: 0, lonE7: 0, accuracy: 1, approximate: false, capturedAt: 0)
    }

    // MARK: Observation

    /// Whether the share key is still held.
    public var keyHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sealer?.holdsKey ?? false
    }

    /// The counter of the next frame, or `nil` once the key was deleted.
    public var nextCounter: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return sealer?.nextCounter
    }

    /// Whether the share is over (no position frame will ever be built again).
    public var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    // MARK: Inputs that are not events of the share

    /// A newer fix. How often the platform is asked for one is a local matter (section 14.6.1 rule 4). A share that ended keeps none.
    public func update(fix newFix: LocationSenderFix) {
        lock.lock()
        if !ended { fix = newFix }
        lock.unlock()
    }

    /// The platform is (or is no longer) in a low-power mode: the tick is 60 seconds instead of 30 and `iv` follows.
    public func setLowPower(_ enabled: Bool) {
        lock.lock()
        lowPower = enabled
        lock.unlock()
    }

    public func socketWentDown() -> LocationSenderOutcome {
        lock.lock()
        defer { lock.unlock() }
        socketUp = false
        // A final frame that waits for its tick is built only while the socket is up: it is dropped and `k` goes at once.
        if finalPending {
            finalPending = false
            finish()
        }
        return snapshot(LocationSenderOutcome())
    }

    public func socketCameUp() -> LocationSenderOutcome {
        lock.lock()
        defer { lock.unlock() }
        socketUp = true
        return snapshot(LocationSenderOutcome())
    }

    // MARK: Events of the share

    /// The bytes of the start message are about to be handed to the socket. Called BEFORE the hand-over and never after it: from this
    /// moment the start may have left the device, so a stop that comes next is held until the echo (rule 2) instead of withdrawing a
    /// start that then leaves anyway, and the note a restart reads says "sent" even if the process dies right after the hand-over.
    public func startLeftDevice() -> LocationSenderOutcome {
        lock.lock()
        defer { lock.unlock() }
        if phase == .queued && !ended {
            phase = .sent
            attemptInFlight = true
            journal.write(LocationShareJournalEntry(startClientMsgId: startClientMsgId, phase: .sent, stopSent: stopSent))
        }
        return snapshot(LocationSenderOutcome())
    }

    /// The hand-over announced by `startLeftDevice` failed before any byte was written (the socket was not there in time): the start did
    /// not leave. A share that is still running goes back to "not left", so that a later stop withdraws the start. A share that ended
    /// while the attempt was in flight, and holds its stop for an echo that cannot come, withdraws the start instead and sends nothing.
    /// It acts only on an attempt of THIS process: a share that a previous process left (`recoverAfterRestart`) may have left in that
    /// process, and is never taken back.
    public func startNotSent() -> LocationSenderOutcome {
        lock.lock()
        defer { lock.unlock() }
        var outcome = LocationSenderOutcome()
        guard attemptInFlight, phase == .sent else { return snapshot(outcome) }
        attemptInFlight = false
        if ended {
            guard stopDeferred else { return snapshot(outcome) }
            stopDeferred = false
            effects.withdrawStart(startClientMsgId)
            journal.clear(startClientMsgId: startClientMsgId)
            outcome.outboxWithdrawn = true
        } else {
            phase = .queued
            journal.write(LocationShareJournalEntry(startClientMsgId: startClientMsgId, phase: .queued, stopSent: stopSent))
        }
        return snapshot(outcome)
    }

    /// The `msg_sent` echo of the start: frames may be built, and a stop that waited for it goes out now.
    public func startAcknowledged(now: Int64) -> LocationSenderOutcome {
        lock.lock()
        defer { lock.unlock() }
        var outcome = LocationSenderOutcome()
        phase = .echoed
        attemptInFlight = false
        if stopDeferred {
            stopDeferred = false
            stopSent = true
            effects.sendStop(startClientMsgId, now)
            journal.clear(startClientMsgId: startClientMsgId)
            outcome.stop = .sent
        } else if !ended {
            journal.write(LocationShareJournalEntry(startClientMsgId: startClientMsgId, phase: .echoed, stopSent: stopSent))
        }
        return snapshot(outcome)
    }

    /// One tick of the share (30 seconds, or 60 in a low-power mode). Builds at most one frame: a position frame, or the final frame of
    /// a stop that waited for it. `write` hands the sealed frame to the transport; whether it throws makes no difference to the counter.
    public func tick(now: Int64, write: (LocationFrameCodec.Sealed) throws -> Void) -> LocationSenderOutcome {
        lock.lock()
        defer { lock.unlock() }
        var outcome = LocationSenderOutcome()
        // A stop already went out and its final frame waits for this tick.
        if finalPending {
            finalPending = false
            outcome.frame = sealAndWrite(LocationFramePlaintext.finalFrame, write: write)
            finish()
            return snapshot(outcome)
        }
        if ended || sealer == nil {
            outcome.refusal = .ended
            return snapshot(outcome)
        }
        // `st + du` reached: the share ends by itself, with the stop at once and the final frame now.
        if now >= startedAt + duration {
            return endLocked(now: now, final: .now, write: write)
        }
        if !socketUp {
            outcome.refusal = .offline
            return snapshot(outcome)
        }
        if phase != .echoed {
            outcome.refusal = .noEcho
            return snapshot(outcome)
        }
        if let last = lastFrameAt, now - last < LocationWire.txMinGap {
            outcome.refusal = .tooFast
            return snapshot(outcome)
        }
        let interval = lowPower ? LocationWire.txIntervalLowPower : LocationWire.txInterval
        let age = UInt16(min(max(now - fix.capturedAt, 0), LocationWire.frameAgeMax))
        let plaintext = LocationFramePlaintext.position(latE7: fix.latE7, lonE7: fix.lonE7, accuracy: fix.accuracy, age: age,
                                                        approximate: fix.approximate, interval: UInt16(interval))
        outcome.frame = sealAndWrite(plaintext, write: write)
        lastFrameAt = now
        return snapshot(outcome)
    }

    /// The share ends on a trigger the sender can act on (the user's stop, a block, a changed identity key, a revoked permission, the
    /// remote switch, a logout, a wipe): the stop goes out, the final frame follows on the next tick or at once, and `k` is deleted.
    public func stop(now: Int64, final: LocationFinalFrameMode,
                     write: (LocationFrameCodec.Sealed) throws -> Void) -> LocationSenderOutcome {
        lock.lock()
        defer { lock.unlock() }
        return endLocked(now: now, final: final, write: write)
    }

    // MARK: Internals

    private func endLocked(now: Int64, final: LocationFinalFrameMode,
                           write: (LocationFrameCodec.Sealed) throws -> Void) -> LocationSenderOutcome {
        var outcome = LocationSenderOutcome()
        if ended || finalPending || sealer == nil {
            outcome.refusal = .ended
            return snapshot(outcome)
        }
        switch phase {
        case .queued:
            // The start never left the device: nothing was announced, so nothing is stopped. It is withdrawn from the outbox.
            effects.withdrawStart(startClientMsgId)
            journal.clear(startClientMsgId: startClientMsgId)
            outcome.outboxWithdrawn = true
            finish()
        case .sent:
            // A stop never overtakes its start: it waits for the echo. No frame is built for a start that was not acknowledged.
            stopDeferred = true
            outcome.stop = .deferred
            finish()
        case .echoed:
            stopSent = true
            effects.sendStop(startClientMsgId, now)
            outcome.stop = .sent
            if socketUp {
                switch final {
                case .now:
                    // Exempt from the minimum interval.
                    outcome.frame = sealAndWrite(LocationFramePlaintext.finalFrame, write: write)
                    finish()
                    journal.clear(startClientMsgId: startClientMsgId)
                case .onTick:
                    finalPending = true
                    ended = true
                    // The final frame carries no position: the last fix goes now, not at the tick.
                    wipeFix()
                    journal.write(LocationShareJournalEntry(startClientMsgId: startClientMsgId, phase: .echoed, stopSent: true))
                }
            } else {
                // The socket is down: no final frame is built, the stop is the end and `k` goes at once.
                finish()
                journal.clear(startClientMsgId: startClientMsgId)
            }
        }
        return snapshot(outcome)
    }

    /// Seals one frame (the counter is taken and advanced in one step inside the sealer) and hands it to the transport. A failed write
    /// does not matter: the counter is spent and the frame is never sealed again.
    private func sealAndWrite(_ plaintext: LocationFramePlaintext,
                              write: (LocationFrameCodec.Sealed) throws -> Void) -> LocationSenderOutcome.Frame? {
        guard let sealed = sealer?.seal(plaintext) else { return nil }
        try? write(sealed)
        return LocationSenderOutcome.Frame(counter: sealed.counter, isFinal: sealed.isFinal)
    }

    /// The share is over: no position frame again, `k`, the counter and the last fix deleted (rule 8).
    private func finish() {
        ended = true
        finalPending = false
        sealer?.wipe()
        sealer = nil
        wipeFix()
        if phase == .echoed && stopSent {
            journal.clear(startClientMsgId: startClientMsgId)
        }
    }

    /// Overwrites the last fix with a zero value (it is a value type: the old coordinates are not kept by any other copy of this object).
    private func wipeFix() {
        fix = LocationSenderFix(latE7: 0, lonE7: 0, accuracy: 1, approximate: false, capturedAt: 0)
    }

    /// The last fix this sender holds, for the tests that pin its deletion: a zero value once the share ended.
    var heldFixIsWiped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fix.latE7 == 0 && fix.lonE7 == 0 && fix.capturedAt == 0
    }

    private func snapshot(_ base: LocationSenderOutcome) -> LocationSenderOutcome {
        var outcome = base
        outcome.keyHeld = sealer?.holdsKey ?? false
        outcome.nextCounter = sealer?.nextCounter
        return outcome
    }

    // MARK: Restart (section 14.6.1 rule 10)

    /// A process that starts and finds a share that was live when the previous process died builds NO frame for it, position or final:
    /// the key and the counter died with the process that held them. It sends the stop (held until the echo if that never arrived; an
    /// unsent start is withdrawn), deletes every trace of the share and tells the user. The share is never resumed.
    ///
    /// Returns the sender of the share in its ended state, which still reacts to `startAcknowledged` for a stop that is deferred, and
    /// what was done.
    public static func recoverAfterRestart(entry: LocationShareJournalEntry, now: Int64, effects: LocationShareSenderEffects,
                                           journal: LocationShareJournal) -> (sender: LocationShareSender, outcome: LocationSenderOutcome) {
        let sender = LocationShareSender(entry: entry, effects: effects, journal: journal)
        var outcome = LocationSenderOutcome()
        switch entry.phase {
        case .queued:
            effects.withdrawStart(entry.startClientMsgId)
            journal.clear(startClientMsgId: entry.startClientMsgId)
            outcome.outboxWithdrawn = true
        case .sent:
            // Held until the echo of the start, like any stop; the note stays until then.
            sender.stopDeferred = true
            outcome.stop = .deferred
        case .echoed:
            if !entry.stopSent {
                effects.sendStop(entry.startClientMsgId, now)
                outcome.stop = .sent
            }
            journal.clear(startClientMsgId: entry.startClientMsgId)
        }
        return (sender, sender.snapshot(outcome))
    }
}

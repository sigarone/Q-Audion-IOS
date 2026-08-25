import Foundation

/// W-PLPFEEDBACK (2026-08-25) — count the audio frames that never arrived.
///
/// Port of Android's `FrameLossMeter` (`com.bcrypto.qaudion.feature.call.domain
/// .FrameLossMeter`), kept algorithmically identical so the two platforms'
/// notion of "loss %" for a given wire sequence stream agrees exactly.
///
/// ## The measurement this exists to make
///
/// `AudioAutoTuner`'s pre-existing `rxDecryptErrors / framesReceived` answers
/// "of the frames we RECEIVED, how many failed to decrypt or decode". A frame
/// that never arrived is in neither the numerator nor the denominator, so
/// that figure cannot express transit loss at all. Every sealed audio frame
/// already carries the sender's monotonic per-call sequence number (bound
/// into the AEAD AAD and already used for replay/reorder handling — see
/// `QAudionEngine.processIncomingAudio`), so gaps in it ARE the loss, and the
/// receiver can measure it from what it is already given, with no wire
/// change.
///
/// ## What it has to survive
///
/// A naive `max - min + 1 - received` breaks on three real things:
///
///  - REORDERING. A frame arriving late must not count as lost and then
///    un-count. Anchoring on the highest seq seen handles this: the span only
///    ever grows, and a late arrival simply increments `received`.
///  - DUPLICATES. A replayed frame must not make the count go negative. Loss
///    is therefore floored at zero, and duplicates are counted separately.
///  - RESETS. The sender's counter restarts at zero on every re-key
///    (`QAudionEngine.initSession`'s `txSeqAdaptive = 0` / fresh
///    `SessionManager`). Treating that as a huge backward jump would produce
///    nonsense, so a large regression closes the current span into an
///    accumulator and re-anchors — see `onFrame`.
///
/// Pure and total: no clock, no I/O, no thread-safety of its own (the caller,
/// `QAudionEngine`, already serializes every access under its own lock).
public final class FrameLossMeter {

    /// A frame is read as a counter RESTART rather than a late arrival when
    /// it sits more than this far below the highest seq seen. One second of
    /// audio is 50 frames at 20 ms and ~17 at 60 ms; a real reorder never
    /// arrives that late — a frame that stale is useless to the jitter
    /// buffer anyway. Mirrors Android's `resetGap` verbatim (50, not
    /// re-derived per profile): the sender's sequence counter increments once
    /// per frame regardless of frame duration, so the counter-domain gap a
    /// re-key produces does not scale with the audio profile either.
    private let resetGap: Int64 = 50

    private var anchorSeq: Int64 = -1
    private var maxSeq: Int64 = -1
    private var receivedInSpan: Int64 = 0

    /// Spans closed by a counter reset, folded in so the totals stay whole.
    private var closedExpected: Int64 = 0
    private var closedReceived: Int64 = 0

    public private(set) var duplicates: Int64 = 0
    public private(set) var resets: Int64 = 0

    /// Frames the sender must have emitted, across every span.
    public var expected: Int64 {
        closedExpected + (anchorSeq < 0 ? 0 : (maxSeq - anchorSeq + 1))
    }

    /// Frames actually delivered to us.
    public var received: Int64 { closedReceived + receivedInSpan }

    /// Frames that never arrived. Floored at zero: duplicates can push
    /// `received` above the span, and a negative "loss" would be worse than
    /// useless.
    public var lost: Int64 { max(expected - received, 0) }

    /// Loss as a percentage of what the sender emitted.
    public var lossPct: Double {
        expected > 0 ? Double(lost) * 100.0 / Double(expected) : 0.0
    }

    public init() {}

    /// Record one received frame, identified by its wire sequence number.
    public func onFrame(seq: Int64) {
        guard seq >= 0 else { return }
        if anchorSeq < 0 {
            anchorSeq = seq
            maxSeq = seq
            receivedInSpan = 1
            return
        }
        if seq + resetGap < maxSeq {
            // The sender restarted its counter: close this span and re-anchor.
            closedExpected += maxSeq - anchorSeq + 1
            closedReceived += receivedInSpan
            resets += 1
            anchorSeq = seq
            maxSeq = seq
            receivedInSpan = 1
            return
        }
        if seq > maxSeq { maxSeq = seq }
        // A frame below the anchor is still part of THIS span — it simply
        // means we joined mid-stream and a lower one has now shown up. The
        // anchor has to follow it down, or the span stays too narrow and
        // honest frames get booked as duplicates.
        if seq < anchorSeq { anchorSeq = seq }
        receivedInSpan += 1
        // A span can only hold as many frames as its width; anything beyond
        // that arrived twice.
        let width = maxSeq - anchorSeq + 1
        if receivedInSpan > width {
            duplicates += receivedInSpan - width
            receivedInSpan = width
        }
    }

    public func reset() {
        anchorSeq = -1
        maxSeq = -1
        receivedInSpan = 0
        closedExpected = 0
        closedReceived = 0
        duplicates = 0
        resets = 0
    }
}

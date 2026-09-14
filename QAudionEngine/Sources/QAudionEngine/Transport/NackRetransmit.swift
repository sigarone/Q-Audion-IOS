import Foundation

/// W-AUDIONACK (2026-09-10) — loss repair for the custom sealed-audio wire
/// (the path used whenever `audio-srtp-v1` is not the active media path:
/// earbud calls, a legacy peer, or a peer with the native path disabled).
/// That path never had loss REPAIR beyond Opus's own in-band FEC — no
/// equivalent of RTP's NACK/RTX. This pair adds it, riding the existing
/// control-frame channel (`WireRelayFrameCodec.muxControl`, the same one
/// `dc-hangup-v1` already uses) rather than any new crypto. Byte-for-byte
/// port of Android's `com.bcrypto.qaudion.feature.call.domain
/// .NackRetransmitRing` / `.NackRxTracker` — see that file's kdoc for the
/// full design rationale and the `nim.ps1 -Mode security` review this went
/// through before implementation (replaying the exact already-sent bytes a
/// second time is not a new encryption, so there is no AEAD nonce-reuse
/// class of risk — only an ordinary duplicate-delivery question, which
/// `NackRxTracker` answers directly).
///
/// One difference from the Android twin, forced by this platform's wire
/// shape: iOS re-wraps every outbound frame in an OUTER seal
/// (`relaySealerSend`/M-15, see `CallService.processAndSendEncryptedFrame`)
/// on top of the inner sealed-audio bytes, and that outer seal is not
/// guaranteed idempotent to call twice on the same input. So this ring
/// caches the FINAL, fully-sealed `Data` that actually went on the wire —
/// never re-derived, never re-sealed — and a resend simply re-transmits
/// those exact bytes through the same DataChannel/WS leg. The safety
/// argument is identical to Android's: nothing is re-encrypted, so nothing
/// new is exposed.
public final class NackRetransmitRing {
    public static let defaultCapacity = 32

    private let capacity: Int
    private var slots: [Data?]
    private var slotSeq: [Int64]

    public init(capacity: Int = NackRetransmitRing.defaultCapacity) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.slots = Array(repeating: nil, count: capacity)
        self.slotSeq = Array(repeating: -1, count: capacity)
    }

    private func index(for seq: Int64) -> Int {
        let idx = Int(seq % Int64(capacity))
        return idx < 0 ? idx + capacity : idx
    }

    /// Record the exact wire bytes just transmitted for `seq`. Overwrites
    /// (and zero-fills) whatever previously occupied that slot.
    public func record(seq: Int64, envelope: Data) {
        let idx = index(for: seq)
        if var previous = slots[idx] {
            previous.resetBytes(in: 0..<previous.count)
        }
        slots[idx] = envelope
        slotSeq[idx] = seq
    }

    /// Look up previously-sent wire bytes by sequence number. `nil` means
    /// "no longer repairable" (never recorded, or evicted) — always a
    /// best-effort miss, never an error.
    public func lookup(seq: Int64) -> Data? {
        let idx = index(for: seq)
        return slotSeq[idx] == seq ? slots[idx] : nil
    }

    /// Zero-fill and forget every entry. Call on every re-key.
    public func clear() {
        for i in 0..<capacity {
            if var existing = slots[i] {
                existing.resetBytes(in: 0..<existing.count)
            }
            slots[i] = nil
            slotSeq[i] = -1
        }
    }
}

/// RX side: tracks arriving wire sequence numbers for two purposes at once
/// (they share the same "have I seen this seq" bookkeeping) — see the
/// Android twin's kdoc for the full rationale:
///
///  1. **Duplicate delivery** — `accept` returns `false` for a sequence
///     number already delivered, so a retransmit crossing in flight with a
///     merely-late original never reaches playback twice.
///  2. **Gap aging** — a missing sequence number sits unresolved for
///     `nackAgeThresholdMs` before `gapsReadyToNack` offers it up, and even
///     then only once, so ordinary reordering (already tolerated by Opus
///     FEC and jitter buffering) never fires a spurious request.
///
/// Clock is always passed in (`nowMs`), never read internally, matching
/// this codebase's own `SrtpFallbackDecisions`/`CaptureLiveDecisions`
/// discipline for deterministic testability.
public final class NackRxTracker {
    public static let defaultNackAgeThresholdMs: Int64 = 120

    private let lookbackWindow: Int
    private let nackAgeThresholdMs: Int64

    private var highestSeq: Int64 = -1
    private var seenWindow: [Int64]

    private final class PendingGap {
        let firstNoticedAtMs: Int64
        var nacked: Bool = false
        init(firstNoticedAtMs: Int64) { self.firstNoticedAtMs = firstNoticedAtMs }
    }
    private var pendingGaps: [Int64: PendingGap] = [:]
    private var pendingOrder: [Int64] = []

    public init(
        lookbackWindow: Int = NackRetransmitRing.defaultCapacity,
        nackAgeThresholdMs: Int64 = NackRxTracker.defaultNackAgeThresholdMs
    ) {
        precondition(lookbackWindow > 0, "lookbackWindow must be positive")
        self.lookbackWindow = lookbackWindow
        self.nackAgeThresholdMs = nackAgeThresholdMs
        self.seenWindow = Array(repeating: -1, count: lookbackWindow)
    }

    private func slot(for seq: Int64) -> Int {
        let idx = Int(seq % Int64(lookbackWindow))
        return idx < 0 ? idx + lookbackWindow : idx
    }

    /// Record one arriving frame's sequence number.
    ///
    /// - Returns: `true` if this is the first delivery of `seq` — proceed
    ///   to decode/play it. `false` for a duplicate (already delivered, or
    ///   so far behind `highestSeq` it fell out of the lookback window
    ///   entirely) — drop it silently.
    @discardableResult
    public func accept(_ seq: Int64, nowMs: Int64) -> Bool {
        if seq < 0 { return false }
        if highestSeq >= 0 && seq <= highestSeq - Int64(lookbackWindow) { return false }
        let idx = slot(for: seq)
        if seenWindow[idx] == seq { return false }
        seenWindow[idx] = seq

        if highestSeq < 0 || seq > highestSeq {
            if highestSeq >= 0 && seq - highestSeq <= Int64(lookbackWindow) {
                var missing = highestSeq + 1
                while missing < seq {
                    pendingGaps[missing] = PendingGap(firstNoticedAtMs: nowMs)
                    pendingOrder.append(missing)
                    missing += 1
                }
            }
            highestSeq = seq
        } else {
            // A frame at or below highestSeq that was not already in the
            // window: a genuinely late (but still in-window) arrival.
            // Clears its own pending gap, if any.
            pendingGaps.removeValue(forKey: seq)
        }
        return true
    }

    /// Gaps that have aged past `nackAgeThresholdMs` and have not been
    /// requested yet — each is marked requested (never asked for twice),
    /// and a gap `lookbackWindow` or more behind `highestSeq` is dropped
    /// outright (no longer useful to repair).
    public func gapsReadyToNack(nowMs: Int64) -> [Int64] {
        var ready: [Int64] = []
        var stillPending: [Int64] = []
        for seq in pendingOrder {
            guard let gap = pendingGaps[seq] else { continue } // already cleared by accept()
            if highestSeq - seq >= Int64(lookbackWindow) {
                pendingGaps.removeValue(forKey: seq)
                continue
            }
            if !gap.nacked && nowMs - gap.firstNoticedAtMs >= nackAgeThresholdMs {
                gap.nacked = true
                ready.append(seq)
            }
            stillPending.append(seq)
        }
        pendingOrder = stillPending
        return ready
    }

    /// Forget everything. Call on every re-key.
    public func reset() {
        highestSeq = -1
        pendingGaps.removeAll()
        pendingOrder.removeAll()
        seenWindow = Array(repeating: -1, count: lookbackWindow)
    }
}

/// W-AUDIONACK — bounds how many retransmit REQUESTS this side will honor
/// per second, regardless of how many arrive. The control channel is
/// authenticated end-to-end (an off-path attacker cannot forge a request,
/// an on-path attacker cannot inject one without the session key), so this
/// is not an auth gate — it is a ceiling on how much bandwidth a single
/// misbehaving or bugged PEER can make this side spend re-sending frames it
/// already sent once. Mirrors Android `NackResendRateLimiter`.
public final class NackResendRateLimiter {
    public static let defaultMaxPerSecond = 20

    private let maxPerWindow: Int
    private let windowMs: Int64
    private var recentMs: [Int64] = []

    public init(maxPerWindow: Int = NackResendRateLimiter.defaultMaxPerSecond, windowMs: Int64 = 1_000) {
        precondition(maxPerWindow > 0, "maxPerWindow must be positive")
        self.maxPerWindow = maxPerWindow
        self.windowMs = windowMs
    }

    /// Returns `true` if a resend may proceed now, and records it if so.
    @discardableResult
    public func tryAcquire(nowMs: Int64) -> Bool {
        while let first = recentMs.first, nowMs - first >= windowMs {
            recentMs.removeFirst()
        }
        if recentMs.count >= maxPerWindow { return false }
        recentMs.append(nowMs)
        return true
    }
}

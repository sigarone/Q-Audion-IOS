import Foundation

/// W-AUDIOAEADREKEY (2026-09-02) — B3: pure decision logic for "this call's
/// audio AEAD is failing badly enough to ask for a key realignment", the
/// audio mirror of `VideoStallSelfHeal.isPeerKeyframeStorm`'s pure-predicate
/// shape (same repo, `WebRTC/VideoStallSelfHeal.swift`). Feeds both audio
/// decrypt-failure sources this app has today:
///   - the legacy sealed-relay path (`QAudionCallIntegration.
///     processIncomingAudio`'s AEAD open, counted into `CallService.
///     rxDecryptErrorCount` but — before this file — never acted on);
///   - the native SRTP audio path (`NativeAudioFrameCryptor`'s
///     `RTCFrameCryptorDelegate` callback, `.decryptionFailed`/
///     `.missingKey`/`.internalError` — see that file's own doc, which
///     called the hook "reserved for future rekey-skew diagnostics").
///
/// One AEAD failure is NOT actionable on its own: a single corrupt, mis-
/// routed, or wrong-epoch frame is expected background noise on any real
/// call (see `CallService`'s own RX catch-block comments) and must not by
/// itself tear a re-handshake loose. Several failures close together IS a
/// real signal — the two sides' session key has drifted (a missed rekey
/// round, an epoch/slot mismatch — see W-KEYSLOTROTATE in
/// `NativeAudioFrameCryptor.swift`) — the exact "isolated vs. burst"
/// distinction `VideoStallSelfHeal.isPeerKeyframeStorm` already draws for
/// video's own peer-keyframe-request storm rule.
///
/// The trigger this feeds is not new: `ReKeyScheduler.forceReKey` is the
/// same confidence-driven mid-call PQC re-handshake mechanism already wired
/// for `ContactVoiceVerifier`'s suspicion signal (`AppState.
/// onContactVoiceScoreUpdated` → `reKeyScheduler.observeConfidence`) — see
/// that scheduler's own doc for the caller-only glare-avoidance guard
/// already inside `QAudionCallIntegration.performPqcReKey`, which this
/// reuses unchanged: on a responder device the resulting tick is a cheap,
/// safe no-op, exactly like every other `ReKeyScheduler` trigger today.
public enum AudioAeadFailureRekeyPolicy {

    /// This many AEAD failures...
    public static let failureBurstCount: Int = 5

    /// ...inside this window count as one burst rather than N unrelated
    /// isolated bad frames. 4 s comfortably covers several consecutive
    /// 20-60 ms audio frames (a genuinely stuck/misaligned key fails
    /// EVERY frame, so 5 failures land within a few hundred ms), while
    /// still being far too short for coincidental, unrelated one-off
    /// drops spread across a call to accumulate to the threshold.
    public static let failureBurstWindowMs: Int64 = 4000

    /// Minimum spacing between two fired triggers. A key that stays
    /// broken for a while should ask `ReKeyScheduler` once and then WAIT
    /// for that round (bounded by `QAudionCallIntegration.
    /// performPqcReKey`'s own 8 s timeout) rather than hammering
    /// `forceReKey` on every subsequent failing frame while the round is
    /// still in flight.
    public static let retriggerCooldownMs: Int64 = 10_000

    /// Whether this policy's decision (`isFailureBurst`/
    /// `AudioAeadFailureRekeyMeter`) is actually allowed to fire an audio
    /// re-key request (gated in `CallService.noteAudioAeadDecryptFailure`).
    /// The decision logic itself is pure and unit-tested
    /// (`AudioAeadFailureRekeyPolicyTests`) and safe to always run, but the
    /// trigger it feeds — coupling a decrypt-failure signal to
    /// `ReKeyScheduler.forceReKey`, a real crypto re-handshake — has never
    /// been exercised against a real call: no Mac/device this session (see
    /// this item's report). Default OFF, same discipline
    /// `CallKitWorkOffloadPolicy.audioEngineBackgroundQueueEnabled`
    /// documents for its own never-verified-live mechanism: `false`
    /// preserves EXACTLY today's behavior (AEAD failures keep counting
    /// into `CallService.rxDecryptErrorCount`/telemetry; nothing acts on
    /// them). Flip only after confirming on a device that a genuine
    /// mid-call audio key mismatch actually recovers AND that ordinary
    /// transient decrypt noise on a healthy call never spuriously crosses
    /// the burst threshold.
    public static let triggerEnabled: Bool = false

    /// True when the last `failureBurstCount` entries of `failureTimesMs`
    /// (oldest first) all landed inside `failureBurstWindowMs` of `nowMs`.
    /// Mirrors `VideoStallSelfHeal.isPeerKeyframeStorm`'s exact shape.
    public static func isFailureBurst(failureTimesMs: [Int64], nowMs: Int64) -> Bool {
        guard failureTimesMs.count >= failureBurstCount else { return false }
        let oldest = failureTimesMs[failureTimesMs.count - failureBurstCount]
        return nowMs - oldest <= failureBurstWindowMs
    }
}

/// Per-call mutable ring of recent audio-AEAD-failure timestamps + the
/// last-trigger cooldown clock. Pure and clock-agnostic (the caller
/// supplies monotonic `nowMs`, same contract as `VideoStallEscalationEngine`
/// in `WebRTC/VideoStallSelfHeal.swift`); NOT thread-safe by itself — see
/// `CallService.noteAudioAeadDecryptFailure` for the lock that serializes
/// the two real call sites (the RX audio-decode thread and the WebRTC
/// signalling thread) that feed one shared instance of this meter.
public final class AudioAeadFailureRekeyMeter {

    private var recentFailureTimesMs: [Int64] = []
    private var lastTriggerMs: Int64 = -1

    public init() {}

    /// Record one AEAD failure at `nowMs`. Returns `true` exactly when
    /// this failure completed a burst AND the retrigger cooldown has
    /// elapsed since the last trigger — the caller should fire its rekey
    /// request on `true` and do nothing on `false`. A firing trigger
    /// clears the ring, so the NEXT trigger needs a fresh burst rather
    /// than the same old entries re-qualifying under a still-open window.
    @discardableResult
    public func noteFailure(nowMs: Int64) -> Bool {
        recentFailureTimesMs.append(nowMs)
        if recentFailureTimesMs.count > AudioAeadFailureRekeyPolicy.failureBurstCount {
            recentFailureTimesMs.removeFirst(
                recentFailureTimesMs.count - AudioAeadFailureRekeyPolicy.failureBurstCount)
        }
        guard AudioAeadFailureRekeyPolicy.isFailureBurst(
            failureTimesMs: recentFailureTimesMs, nowMs: nowMs) else { return false }
        guard lastTriggerMs < 0
            || nowMs - lastTriggerMs >= AudioAeadFailureRekeyPolicy.retriggerCooldownMs
        else { return false }
        lastTriggerMs = nowMs
        recentFailureTimesMs.removeAll()
        return true
    }

    /// Full per-call reset (hangup) — a fresh call must not inherit the
    /// previous call's failure history or cooldown clock, same discipline
    /// `VideoStallEscalationEngine.reset()` documents for its own state.
    public func reset() {
        recentFailureTimesMs.removeAll()
        lastTriggerMs = -1
    }
}

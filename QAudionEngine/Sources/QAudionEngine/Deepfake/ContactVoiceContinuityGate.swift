import Foundation

/// "Voce remota" (Tier 2 / Feature B) hysteresis gate — the RX-side
/// counterpart to `OwnerContinuityMonitor` ("voce storica", TX-side). Turns
/// the raw, per-tick `SpeakerVerifier.computeVerificationScore` V-score
/// stream (see that method's kdoc — `[0, 1]`, NOT raw cosine) into a stable
/// tri-state for the "voce remota" shield.
///
/// 2026-08-01 direct port of Android's `analysis/ContactVoiceContinuityGate.kt`
/// — this is that class's SECOND design, not a tuning tweak. The original
/// version compared the RAW per-tick score against `verifiedThreshold` and
/// required N STRICTLY CONSECUTIVE good ticks, resetting the streak to zero
/// on ANY single tick that fell in the neutral band. Confirmed on a real
/// Android device: CAM++'s live verification score (computed over a short
/// ~1s/50-frame window — much shorter than typical speaker-verification test
/// utterances) is genuinely noisy even for the SAME matching speaker,
/// oscillating roughly 0.45-0.75 tick to tick. The streak-based gate DID
/// reach 3 consecutive good ticks during a real call and flip to `.verified`
/// — then a single subsequent neutral-band tick instantly reset it back to
/// `.uncertain`, where it stayed for the rest of a 2-minute call despite the
/// underlying voice genuinely matching throughout. Same failure class this
/// codebase already solved once (`ConfidenceIndex`'s EMA-smoothed level):
/// exponential-moving-average the noisy per-tick score FIRST, then threshold
/// the smoothed value directly — no separate streak counter needed, the EMA
/// itself is the memory. This class mirrors that exact, already-proven
/// pattern instead of the brittle raw-streak design.
///
/// `verifiedThreshold` (0.62) and `emaAlpha` (0.35) are carried over
/// UNCHANGED from Android's real-device-tuned values — same algorithm
/// (CAM++), same window size (~1s/50 frames), same V-score scale, so the
/// Android calibration should transfer; not yet independently re-validated
/// against a real iOS device call.
public final class ContactVoiceContinuityGate: @unchecked Sendable {
    public enum Level: String { case unknown, verified, uncertain, mismatch }

    private static let verifiedThreshold: Float = 0.62
    private static let mismatchThreshold: Float = 0.35
    private static let emaAlpha: Float = 0.35

    private let lock = NSLock()
    private var ema: Float?
    private var _level: Level = .unknown

    public init() {}

    /// Call when learning/verification (re)starts for a new contact, or the
    /// call ends.
    public func reset() {
        lock.lock()
        ema = nil
        _level = .unknown
        lock.unlock()
    }

    /// Feed the latest V-score tick (`[0, 1]`, from
    /// `SpeakerVerifier.computeVerificationScore()`). `nil` (no template
    /// loaded yet / window not full / window too quiet to trust) is a
    /// genuine no-op — it must NOT be coerced into a number (neither 0 nor 1
    /// is a safe "no data" sentinel: a caller feeding a real 0.0 or 1.0
    /// score is legitimate and must still count), and it must NOT feed the
    /// EMA either (a skipped tick has no information, unlike a real bad
    /// score — smoothing a missing value in would silently bias the
    /// average).
    public func feed(_ score: Float?) {
        guard let score else { return }
        lock.lock()
        let smoothed = ema.map { Self.emaAlpha * score + (1 - Self.emaAlpha) * $0 } ?? score
        ema = smoothed
        if smoothed >= Self.verifiedThreshold {
            _level = .verified
        } else if smoothed <= Self.mismatchThreshold {
            _level = .mismatch
        } else {
            _level = .uncertain
        }
        lock.unlock()
    }

    public var level: Level {
        lock.lock(); defer { lock.unlock() }
        return _level
    }
}

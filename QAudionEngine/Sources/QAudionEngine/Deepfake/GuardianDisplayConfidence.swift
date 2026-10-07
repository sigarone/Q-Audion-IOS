import Foundation

/// The value behind the in-call "C=" badge (`AppState.confidenceScore` / `confidenceLevel`).
///
/// It is an EMA of Tier 2's 3-signal combine (`ContactVoiceVerifier.onScoreBreakdown`'s `combined`, i.e.
/// 0.4 deepfake + 0.3 liveness + 0.3 voiceprint, each calibrated) and nothing else. Same display path as
/// Android: `DeepfakeMonitor.smoothedValue` (alpha 0.15, seeded at 1.0 at every call start, clamped to
/// [0, 1]) with the bands of Android's `InCallScreen` CONFIDENCE colour (green >= 0.72, amber >= 0.40,
/// red below).
///
/// W-CONFBADGE1SRC (2026-10-07). Tier 1 (`GuardianMode` -> `ConfidenceIndex`) is a DIFFERENT quantity: a
/// single AASIST score whose own EMA is seeded at 0.5 and only moves once its ~4 s window has filled.
/// The 5 Hz wave sampler in `AppState` used to copy that Tier 1 EMA into the badge every 200 ms, so it
/// overwrote this value about fifteen times for each Tier 2 tick. On the native SRTP path Tier 1 is fed
/// one 10 ms chunk per 100 ms and never reaches its first inference in an ordinary call, so the badge
/// read its 0.50 seed, in amber, for whole calls (logs of 2026-10-07: `conf_poll scorex100=50` for the
/// entire call while `guardian3sig ... combined=0.99` every 3 s). Tier 1 keeps the sustained-red alarm
/// and the confidence wave; the badge has this one source, as on Android.
public enum GuardianDisplayConfidence {

    /// Android `DeepfakeMonitor.EMA_ALPHA`.
    public static let emaAlpha: Float = 0.15
    /// Android `DeepfakeMonitor.start()` resets its EMA to 1.0: no reading yet is not a bad reading.
    public static let seed: Float = 1
    /// Android `InCallScreen` CONFIDENCE colour: `confidence >= 0.72f -> success`.
    public static let greenFloor: Float = 0.72
    /// Android `InCallScreen` CONFIDENCE colour: `confidence >= 0.40f -> warning`, red below.
    public static let amberFloor: Float = 0.40

    /// The EMA after folding in one Tier 2 combine. A non-finite combine is not a reading: the EMA is
    /// returned unchanged rather than dragged to an end of the range.
    public static func next(ema: Float, combined: Float) -> Float {
        guard combined.isFinite, ema.isFinite else { return ema.isFinite ? ema : seed }
        let c = min(1, max(0, combined))
        return min(1, max(0, emaAlpha * c + (1 - emaAlpha) * ema))
    }

    /// "green" / "yellow" / "red", the strings `AppState.confidenceLevel` carries.
    public static func level(of value: Float) -> String {
        if value >= greenFloor { return "green" }
        if value >= amberFloor { return "yellow" }
        return "red"
    }
}

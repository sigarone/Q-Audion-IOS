import Foundation
import QAudionEngine

/// Persistent Opus codec preferences. Bitrate is FIXED, not tuned — see
/// `bitrateKbps` below. FEC/PLP are still adjusted post-call by AudioAutoTuner.
///
/// Plain UserDefaults — these are quality knobs, not security flags, so Keychain
/// is not needed (contrast with CallsGate security flags which use Keychain).
///
/// W523 (2026-08-13) — `bitrateKbps` used to be a persisted preference AudioAutoTuner
/// moved between 24 and 40 kbps per call based on measured loss. That is exactly the
/// bug Android's AudioCodecPreferences.kt already fixed once (see its kdoc): a
/// per-device drifting network bitrate produces a per-device varying packet size,
/// which defeats the entire point of a constant-size CBR wire format
/// (`AudioConstants.opusBitrate` — "the whole ecosystem ships frames of the same
/// on-wire size for traffic-analysis resistance... bumping iOS to 64 kbps would have
/// broken that property, different frame sizes ⇒ device fingerprintable"). Android
/// keeps its network encoder's `opusBitrateKbps` fixed at 32 and only lets its
/// auto-tuner move a SEPARATE, BLE-earbud-hop-only field. iOS has no such second
/// hop for this value to legitimately target, so it stays fixed, full stop — see
/// `AudioAutoTuner.tunePostCall`, which still computes and reports what the old
/// loss-driven bitrate would have been (for visibility) but no longer persists it.
public enum AudioCodecPrefs {

    private static let keyPlp         = "qaudion.audio.opus_plp"
    private static let keyAutoTune    = "qaudion.audio.auto_tune_enabled"

    /// Always the fixed CBR bitrate from the wire spec. Never persisted, never
    /// tuned — see the type doc above for why a per-device drifting value here
    /// broke the traffic-analysis-resistance property the constant block size
    /// exists for.
    public static var bitrateKbps: Int {
        AudioConstants.opusBitrate / 1000
    }
    public static var plp: Int {
        UserDefaults.standard.object(forKey: keyPlp) as? Int ?? 30
    }
    public static var autoTuneEnabled: Bool {
        UserDefaults.standard.object(forKey: keyAutoTune) as? Bool ?? true
    }
    public static func setPlp(_ v: Int) {
        UserDefaults.standard.set(min(max(v, 0), 100), forKey: keyPlp)
    }
    public static func setAutoTuneEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: keyAutoTune)
    }
}

import Foundation

/// Persistent Opus codec preferences tuned by AudioAutoTuner after each call.
///
/// Plain UserDefaults — these are quality knobs, not security flags, so Keychain
/// is not needed (contrast with CallsGate security flags which use Keychain).
///
/// Defaults match OpusCodec.Config.secure(): 32 kbps CBR, FEC on, PLR 30%.
/// Wire-format hard cap: 40 kbps (sealed frame payload ≤ 119 B at 20 ms).
public enum AudioCodecPrefs {

    private static let keyBitrateKbps = "qaudion.audio.opus_bitrate_kbps"
    private static let keyPlp         = "qaudion.audio.opus_plp"
    private static let keyAutoTune    = "qaudion.audio.auto_tune_enabled"

    public static var bitrateKbps: Int {
        UserDefaults.standard.object(forKey: keyBitrateKbps) as? Int ?? 32
    }
    public static var plp: Int {
        UserDefaults.standard.object(forKey: keyPlp) as? Int ?? 30
    }
    public static var autoTuneEnabled: Bool {
        UserDefaults.standard.object(forKey: keyAutoTune) as? Bool ?? true
    }

    public static func setBitrateKbps(_ v: Int) {
        UserDefaults.standard.set(min(max(v, 8), 40), forKey: keyBitrateKbps)
    }
    public static func setPlp(_ v: Int) {
        UserDefaults.standard.set(min(max(v, 0), 100), forKey: keyPlp)
    }
    public static func setAutoTuneEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: keyAutoTune)
    }
}

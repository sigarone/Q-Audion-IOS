import Foundation
import QAudionEngine

/// Persistent Opus codec preferences tuned by AudioAutoTuner after each call.
///
/// Plain UserDefaults — these are quality knobs, not security flags, so Keychain
/// is not needed (contrast with CallsGate security flags which use Keychain).
///
/// Defaults match OpusCodec.Config.secure(): 32 kbps CBR, FEC on, PLR 30%.
/// Product cap: 40 kbps. The wire ceiling under it is derived, not written
/// here — `AudioConstants.clampToBlock` (120-byte block − 2-byte length header
/// − 14-byte reserve ⇒ 41 kbps at 20 ms).
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
        // W-BLOCKSIZE — the persisted preference is one of the sources of a
        // bitrate, so it passes the block-derived ceiling like the others. 40
        // stays as the product cap; `clampToBlock` is the wire gate underneath
        // it (41 kbps at a 120-byte block / 20 ms today, so no change now) and
        // keeps the two from drifting if the cap is ever raised here alone.
        UserDefaults.standard.set(AudioConstants.clampToBlock(min(max(v, 8), 40)),
                                  forKey: keyBitrateKbps)
    }
    public static func setPlp(_ v: Int) {
        UserDefaults.standard.set(min(max(v, 0), 100), forKey: keyPlp)
    }
    public static func setAutoTuneEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: keyAutoTune)
    }
}

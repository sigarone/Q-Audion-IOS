import Foundation

/// W406 — single source of truth for VoIP audio DSP gates.
///
/// Before W406, CallsSettingsScreen toggle "Echo Cancellation /
/// Noise Suppression / Auto Gain Control" persisted booleans in
/// SettingsStore that no production path read. The
/// `AudioProcessingPipeline.enableVoiceProcessing` always called
/// `setVoiceProcessingEnabled(true)` on the input node — the toggles
/// did nothing.
///
/// W406 wires the toggles to UserDefaults keys that
/// `CallService.startCall` reads before calling enableVoiceProcessing.
/// When ALL three (AEC + NS + AGC) are off, the pipeline skips
/// enableVoiceProcessing entirely (Apple's VP I/O unit is the bundle
/// — there's no per-effect toggle in iOS, so individual flags collapse
/// to "any of three on → VP enabled").
public enum CallsGate {

    public static let keyAec = "qaudion.calls.aec_enabled"
    public static let keyNs  = "qaudion.calls.ns_enabled"
    public static let keyAgc = "qaudion.calls.agc_enabled"

    public static var aecEnabled: Bool { readBool(keyAec, default: true) }
    public static var nsEnabled: Bool  { readBool(keyNs,  default: true) }
    public static var agcEnabled: Bool { readBool(keyAgc, default: true) }

    /// Apple's `AVAudioInputNode.setVoiceProcessingEnabled(true)` is
    /// the single switch for AEC + NS + AGC bundled. We expose the
    /// 3 individual flags in the UI for parity with Android's
    /// `WebRtcAudioConfig.kt`, but at the iOS HW layer it's all-or-
    /// nothing. This computed flag matches that reality.
    public static var anyVoiceProcessingEnabled: Bool {
        return aecEnabled || nsEnabled || agcEnabled
    }

    public static func setAec(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyAec) }
    public static func setNs(_ value: Bool)  { UserDefaults.standard.set(value, forKey: keyNs) }
    public static func setAgc(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyAgc) }

    private static func readBool(_ key: String, default fallback: Bool) -> Bool {
        if let raw = UserDefaults.standard.object(forKey: key) as? Bool { return raw }
        return fallback
    }
}

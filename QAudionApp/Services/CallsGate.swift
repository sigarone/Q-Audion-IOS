import Foundation
import Security
import QAudionEngine  // vkey-v1: CallCapabilities.vkeyV1 for filterAdvertisedCapabilities

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

    // MARK: - Audio DSP keys

    public static let keyAec = "qaudion.calls.aec_enabled"
    public static let keyNs  = "qaudion.calls.ns_enabled"
    public static let keyAgc = "qaudion.calls.agc_enabled"

    // W556: AEC default flipped to `false`.
    //
    // Background — Apple's VP-IO unit is all-or-nothing: one call to
    // `setVoiceProcessingEnabled(true)` enables AEC + NS + AGC as a
    // bundle (AGC was already disabled post-W537 via the property knob,
    // but NS has no equivalent per-component knob in the public API).
    //
    // The NS component is a Wiener-filter spectral suppressor tuned
    // for phone calls in noisy environments. In quiet indoor rooms
    // (the typical Q-Audion use case) it over-suppresses speech
    // formants and generates "musical noise" artefacts — exactly the
    // "metallica" quality the user reported on 2026-05-27.
    //
    // Apple's audio CODEC (not VP-IO) provides hardware-level AEC at
    // the HAL layer even when `setVoiceProcessingEnabled(false)`.
    // That HW AEC is sufficient for earpiece and most headphone use.
    // For speakerphone at high volume, the SW AEC in VP-IO is a
    // bonus — but the Q-Audion call path is relay-only (no direct
    // peer path), so AEC is less critical than audio fidelity.
    //
    // New defaults: AEC=false, NS=false, AGC=false → anyVoiceProcessingEnabled
    // = false → `setVoiceProcessingEnabled(false)` → VP-IO fully bypassed.
    // HW AEC remains active at the codec level.
    //
    // Users who are in loud environments / on speakerphone can still
    // enable AEC in Settings → Chiamate → Echo Cancellation.
    public static var aecEnabled: Bool { readBool(keyAec, default: true) }  // default ON — prevents acoustic echo between nearby devices
    public static var nsEnabled: Bool  { readBool(keyNs,  default: false) }
    public static var agcEnabled: Bool { readBool(keyAgc, default: false) }

    /// Apple's `AVAudioInputNode.setVoiceProcessingEnabled(true)` is
    /// the single switch for AEC + NS + AGC bundled. We expose the
    /// 3 individual flags in the UI for parity with Android's
    /// `WebRtcAudioConfig.kt`, but at the iOS HW layer it's all-or-
    /// nothing. This computed flag matches that reality.
    ///
    /// W556: defaults now all-false → VP-IO off by default.
    /// The hardware AEC at the codec level is always active.
    public static var anyVoiceProcessingEnabled: Bool {
        return aecEnabled || nsEnabled || agcEnabled
    }

    public static func setAec(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyAec) }
    public static func setNs(_ value: Bool)  { UserDefaults.standard.set(value, forKey: keyNs) }
    public static func setAgc(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyAgc) }

    // MARK: - W443 call session security (parity with Android SettingsViewModel)

    /// Controls AASIST live deepfake detection during calls.
    /// Default ON — mirrors Android `deepfakeGuard = true`.
    public static let keyDeepfakeGuard    = "qaudion.calls.deepfake_guard_enabled"
    /// Controls adaptive re-keying frequency scaled by Confidence Index.
    /// Default ON — mirrors Android `adaptiveRekeying = true`.
    public static let keyAdaptiveRekeying = "qaudion.calls.adaptive_rekeying_enabled"
    /// Controls constant bitrate padding to resist traffic analysis.
    /// Default ON — mirrors Android `adaptivePadding = true`.
    public static let keyAdaptivePadding  = "qaudion.calls.adaptive_padding_enabled"

    // SECURITY M-8: these three are call-session security flags
    // (deepfake detection, adaptive re-keying, traffic-analysis
    // padding). They are now backed by the Keychain instead of
    // UserDefaults so they cannot be silently downgraded by anything
    // with plist/backup access. Default-true semantics are preserved
    // when the key is absent; public API is unchanged.
    public static var deepfakeGuardEnabled:    Bool { readSecureBool(keyDeepfakeGuard,    default: true) }
    public static var adaptiveRekeyingEnabled: Bool { readSecureBool(keyAdaptiveRekeying, default: true) }
    public static var adaptivePaddingEnabled:  Bool { readSecureBool(keyAdaptivePadding,  default: true) }

    public static func setDeepfakeGuard(_ value: Bool) {
        writeSecureBool(keyDeepfakeGuard, value)
    }
    public static func setAdaptiveRekeying(_ value: Bool) {
        writeSecureBool(keyAdaptiveRekeying, value)
    }
    public static func setAdaptivePadding(_ value: Bool) {
        writeSecureBool(keyAdaptivePadding, value)
    }

    // MARK: - R-4 (vkey-v1) sovereign-only video policy

    /// Sovereign-only video policy. When ON the client MUST NOT advertise
    /// `vkey-v1` (so it never offers phone-level video E2EE) and MUST
    /// reject any incoming video. Rationale: a "sovereign" user only
    /// accepts video protected by sovereign-grade keys; the phone-derived
    /// K_video does not meet that bar, so video is refused outright rather
    /// than downgraded to phone-level trust. Default OFF (phone-level
    /// video allowed). Keychain-backed (SECURITY M-8) so it cannot be
    /// silently downgraded via plist/backup. Mirrors Android
    /// `qaudion.calls.sovereign_only`.
    public static let keySovereignOnly = "qaudion.calls.sovereign_only"

    /// True when the sovereign-only video policy is active. Default false.
    public static var sovereignOnlyEnabled: Bool { readSecureBool(keySovereignOnly, default: false) }

    public static func setSovereignOnly(_ value: Bool) {
        writeSecureBool(keySovereignOnly, value)
    }

    /// Apply the sovereign-only policy to an outgoing capability list:
    /// strips `vkey-v1` when the policy is on, leaves the list untouched
    /// otherwise. The app layer MUST route its advertised `capabilities`
    /// array through this before sending `call_offer` / `call_answer`.
    /// Pure function — safe to unit-test. Uses `CallCapabilities.vkeyV1`
    /// as the source of truth for the tag string.
    public static func filterAdvertisedCapabilities(_ caps: [String]) -> [String] {
        guard sovereignOnlyEnabled else { return caps }
        return caps.filter { $0 != CallCapabilities.vkeyV1 }
    }

    /// True iff incoming video must be rejected under this policy (i.e.
    /// sovereign-only is on). The app layer consults this when an inbound
    /// `m=video` / remote video track arrives and tears it down instead
    /// of rendering. Pure read — no side effects.
    public static var shouldRejectIncomingVideo: Bool { sovereignOnlyEnabled }

    // MARK: - Helpers

    private static func readBool(_ key: String, default fallback: Bool) -> Bool {
        if let raw = UserDefaults.standard.object(forKey: key) as? Bool { return raw }
        return fallback
    }

    // MARK: - SECURITY M-8 Keychain-backed security flags

    private static let keychainService = "com.qaudion.calls"

    /// Read a security flag from the Keychain. On first access, performs
    /// a one-time migration of any pre-existing UserDefaults value so
    /// users who previously toggled the flag keep their choice. When no
    /// value exists in either store, returns `fallback` (default true).
    private static func readSecureBool(_ key: String, default fallback: Bool) -> Bool {
        if let v = keychainGetBool(key) { return v }
        // One-time migration from legacy UserDefaults.
        if let legacy = UserDefaults.standard.object(forKey: key) as? Bool {
            keychainSetBool(key, legacy)
            UserDefaults.standard.removeObject(forKey: key)
            return legacy
        }
        return fallback
    }

    private static func writeSecureBool(_ key: String, _ value: Bool) {
        keychainSetBool(key, value)
        // Drop any stale legacy value so it can't shadow the secure one.
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// SECURITY F-2: atomic write. The old `SecItemDelete` then
    /// `SecItemAdd` (status ignored) could lose the
    /// `AfterFirstUnlockThisDeviceOnly` accessibility class if the add
    /// silently failed (e.g. `errSecInteractionNotAllowed` while the
    /// device is locked), which would silently downgrade these
    /// call-session security flags. Mirrors `TokenVault.save`:
    /// update-first, add when absent, delete+add as a last resort, and
    /// the terminal OSStatus is checked + logged, never swallowed.
    /// Default-true semantics on absence are unchanged (a failed write
    /// just means the key stays absent → `readSecureBool` default).
    private static func keychainSetBool(_ account: String, _ value: Bool) {
        let data = Data([value ? 1 : 0])
        let base: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(base as CFDictionary,
                                         attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = base
            for (k, v) in attributes { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            logIfFailed("add", account: account, status: addStatus)
            return
        }
        SecItemDelete(base as CFDictionary)
        var add = base
        for (k, v) in attributes { add[k] = v }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        logIfFailed("reset", account: account, status: addStatus)
    }

    /// SECURITY F-2: surface a failed keychain write instead of
    /// swallowing it. Log string built into a single `let line: String`
    /// outside any closure (CLAUDE.md Swift-6 type-checker trap).
    private static func logIfFailed(_ op: String,
                                    account: String,
                                    status: OSStatus) {
        if status == errSecSuccess { return }
        let statusText: String = String(describing: status)
        let line: String = "CallsGate keychain "
            + op + " failed status=" + statusText
        RTLog.error("security", line)
    }

    private static func keychainGetBool(_ account: String) -> Bool? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let first = data.first else {
            return nil
        }
        return first != 0
    }
}

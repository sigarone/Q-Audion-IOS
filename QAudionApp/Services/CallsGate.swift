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

    // W-CANONICAL (2026-07-12) — key BUMP (.v2) + defaults flipped to TRUE.
    //
    // VP-IO (Apple's AEC+NS+AGC bundle) is back ON by default — the canonical
    // stack every production VoIP app ships (libwebrtc runs VP-IO always and
    // force-enables Apple's AGC; Signal/Telegram same). The W556 conviction
    // ("metallica e scattosa" → VP-IO NS blamed, defaults flipped false) was
    // CONFOUNDED: commit a6c971e changed two variables at once, and the
    // artifact matches the A2DP/SCO 16k-vs-48k rate mismatch its own message
    // describes — a class now made impossible by the AVAudioConverter in
    // AudioCapture (the TX chain previously had NO resampler at all). The
    // W574b iPad "1 frame then TX dead" starve is handled by the W-AEC-FIX
    // input-pull sink + starve watchdog (auto-fallback to raw-mic, per call).
    //
    // Key bump rationale: the old keys may hold stale user/dev values from the
    // W556 era; in dev (no-legacy) everyone restarts from the new default.
    // Toggling ALL THREE off in Settings → Chiamate remains the user
    // killswitch (next call runs the raw-mic fallback stack).
    public static let keyAec = "qaudion.calls.aec_enabled.v2"
    public static let keyNs  = "qaudion.calls.ns_enabled.v2"
    public static let keyAgc = "qaudion.calls.agc_enabled.v2"

    public static var aecEnabled: Bool { readBool(keyAec, default: true) }
    public static var nsEnabled: Bool  { readBool(keyNs,  default: true) }
    public static var agcEnabled: Bool { readBool(keyAgc, default: true) }

    /// Apple's `AVAudioInputNode.setVoiceProcessingEnabled(true)` is
    /// the single switch for AEC + NS + AGC bundled. We expose the
    /// 3 individual flags in the UI for parity with Android's
    /// `WebRtcAudioConfig.kt`, but at the iOS HW layer it's all-or-
    /// nothing. This computed flag matches that reality.
    ///
    /// W-CANONICAL: defaults all-true → VP-IO on by default; all three
    /// toggled off = the raw-mic fallback stack (user killswitch).
    public static var anyVoiceProcessingEnabled: Bool {
        return aecEnabled || nsEnabled || agcEnabled
    }

    public static func setAec(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyAec) }
    public static func setNs(_ value: Bool)  { UserDefaults.standard.set(value, forKey: keyNs) }
    public static func setAgc(_ value: Bool) { UserDefaults.standard.set(value, forKey: keyAgc) }

    // MARK: - W-NOCALLKIT — CallKit-free incoming-call mode (revertible)

    /// When true, iOS abandons CallKit + PushKit and handles the incoming-call
    /// ring + answer with a fully custom in-app UI:
    ///   • app alive  → the WebSocket-delivered `call_incoming` shows the custom
    ///                  ring UI immediately (no push, no CallKit);
    ///   • app killed → a standard APNs ALERT notification (category
    ///                  `INCOMING_CALL`, time-sensitive, Answer/Decline actions)
    ///                  rings; tap Answer opens the app → custom UI.
    ///
    /// Default FALSE = the proven CallKit + PushKit path, so this is a clean
    /// REVERT switch (flip to false and the old behaviour returns). Apple
    /// constraint (verified): PushKit REQUIRES CallKit (iOS 13+), so the two are
    /// disabled together; the cost of `true` is no full-screen auto-ring on the
    /// lock screen and no CarPlay/system-call integration on iOS.
    public static let keyCallKitFree = "qaudion.calls.callkit_free_mode"
    public static var callKitFreeMode: Bool { readBool(keyCallKitFree, default: false) }
    public static func setCallKitFreeMode(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: keyCallKitFree)
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

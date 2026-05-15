import Foundation

/// Canonical HKDF info / salt labels for cross-platform key derivation.
///
/// Source of truth: `docs/progress/INVARIANTS_VERIFIED.md` §5.3 (verified
/// byte-identical between iOS / Android / Desktop where each label is
/// implemented). Use these constants instead of inlining magic strings,
/// so a future cross-platform change can be applied via a single edit.
///
/// **Status reminders (per INVARIANTS_VERIFIED.md Open Discrepancies):**
/// - Device-link PSK: ❌ not implemented on iOS yet (Phase B.6).
/// - Recovery seed: ❌ not implemented on iOS yet (Phase B.8). Salt label
///   below is the SPEC value `"recovery-auth-v1"`; Android source uses
///   `"bcrypto-recov-v1"` as the actual salt with `"recovery-auth-v1"`
///   as info. Spec table needs reconciliation — see Open Discrepancy §6.
public enum HkdfLabels {

    // MARK: - Info strings (UTF-8)

    /// Per-pair message conversation key. Used by `MessageCrypto`.
    public static let messageKey: Data = "q-audion-msg-key".data(using: .utf8)!

    /// Hybrid PQC session key (post ML-KEM-1024 + X25519 combined KDF).
    public static let hybridPqcSessionKey: Data = "q-audion-session-key".data(using: .utf8)!

    /// NFC collaborative pairing PSK info (§5.5). Used by `NfcPskDerivation`.
    public static let nfcCollaborativePsk: Data = "Q-Audion NFC Collaborative PSK v1".data(using: .utf8)!

    /// Device-link PSK info (§5.3 row "Device-link PSK"). NOT YET IMPLEMENTED on iOS.
    public static let deviceLinkPsk: Data = "qaudion-device-link-v1".data(using: .utf8)!

    /// Frame chain (audio) — per-frame key derivation in active calls.
    public static let frameChainAudio: Data = "q-audion-frame-key".data(using: .utf8)!

    /// Frame chain (video) — per-frame key for video uplift (Track B.5).
    public static let frameChainVideo: Data = "q-audion-video-frame-key".data(using: .utf8)!

    /// Attachment encryption — per-file key derivation.
    public static let fileKey: Data = "q-audion-file-key".data(using: .utf8)!

    /// Recovery seed → secret (BIP-39 mnemonic-derived).
    ///
    /// **KNOWN DISCREPANCY (Phase B.8, not yet implemented on either platform):**
    /// Android uses `"bcrypto-recov-v1"` as the HKDF *salt* and
    /// `"recovery-auth-v1"` as the *info*. This constant is the *info* label
    /// and is correct. The *salt* (`"bcrypto-recov-v1"`) must be supplied by
    /// the call site when this label is first used — do NOT use `nil` as salt.
    /// Verified against Android `RecoveryKeyDerivation.kt` before shipping
    /// Phase B.8 implementation. Do NOT use this constant until then.
    public static let recoveryAuth: Data = "recovery-auth-v1".data(using: .utf8)!

    /// Recovery HKDF salt — counterpart to `recoveryAuth` info.
    /// Mirrors Android `RecoveryKeyDerivation.kt` `SALT = "bcrypto-recov-v1"`.
    public static let recoverySalt: Data = "bcrypto-recov-v1".data(using: .utf8)!

    // MARK: - Salts (UTF-8)

    /// Hybrid PQC session key salt.
    public static let hybridPqcSaltV1: Data = "q-audion-hybrid-pqc-v1".data(using: .utf8)!

    /// Device-link PSK salt (counterpart to `deviceLinkPsk` info).
    public static let deviceLinkSalt: Data = "qaudion-link-salt".data(using: .utf8)!

    // MARK: - Output sizes (bytes)

    /// HKDF-SHA256 default output size for symmetric keys.
    public static let symmetricKeyBytes = 32

    // MARK: - Verification

    /// Asserts that every label round-trips through UTF-8 cleanly. Useful
    /// as a canary in CI to catch non-ASCII drift introduced by IDE-level
    /// encoding bugs.
    public static func verifyAllUtf8RoundTrip() -> Bool {
        let labels: [Data] = [
            messageKey, hybridPqcSessionKey, nfcCollaborativePsk,
            deviceLinkPsk, frameChainAudio, frameChainVideo, fileKey,
            recoveryAuth, recoverySalt, hybridPqcSaltV1, deviceLinkSalt
        ]
        for label in labels {
            guard let s = String(data: label, encoding: .utf8),
                  s.data(using: .utf8) == label else {
                return false
            }
        }
        return true
    }
}

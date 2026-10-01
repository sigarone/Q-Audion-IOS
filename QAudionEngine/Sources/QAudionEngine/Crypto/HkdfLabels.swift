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
    public static let messageKey: Data = Data("q-audion-msg-key".utf8)

    /// Hybrid PQC session key (post ML-KEM-1024 + X25519 combined KDF).
    public static let hybridPqcSessionKey: Data = Data("q-audion-session-key".utf8)

    /// NFC collaborative pairing PSK info (§5.5). Used by `NfcPskDerivation`.
    public static let nfcCollaborativePsk: Data = Data("Q-Audion NFC Collaborative PSK v1".utf8)

    /// Device-link PSK info (§5.3 row "Device-link PSK"). NOT YET IMPLEMENTED on iOS.
    public static let deviceLinkPsk: Data = Data("qaudion-device-link-v1".utf8)

    /// Frame chain (audio) — per-frame key derivation in active calls.
    public static let frameChainAudio: Data = Data("q-audion-frame-key".utf8)

    /// Frame chain (video) — per-frame key for video uplift (Track B.5).
    public static let frameChainVideo: Data = Data("q-audion-video-frame-key".utf8)

    /// Attachment encryption — per-file key derivation.
    public static let fileKey: Data = Data("q-audion-file-key".utf8)

    /// Recovery seed → secret (BIP-39 mnemonic-derived).
    ///
    /// **KNOWN DISCREPANCY (Phase B.8, not yet implemented on either platform):**
    /// Android uses `"bcrypto-recov-v1"` as the HKDF *salt* and
    /// `"recovery-auth-v1"` as the *info*. This constant is the *info* label
    /// and is correct. The *salt* (`"bcrypto-recov-v1"`) must be supplied by
    /// the call site when this label is first used — do NOT use `nil` as salt.
    /// Verified against Android `RecoveryKeyDerivation.kt` before shipping
    /// Phase B.8 implementation. Do NOT use this constant until then.
    public static let recoveryAuth: Data = Data("recovery-auth-v1".utf8)

    /// Recovery HKDF salt — counterpart to `recoveryAuth` info.
    /// Mirrors Android `RecoveryKeyDerivation.kt` `SALT = "bcrypto-recov-v1"`.
    public static let recoverySalt: Data = Data("bcrypto-recov-v1".utf8)

    /// HMAC-SHA256 key (domain-separation label) used to bind the ML-KEM
    /// ciphertext into the hybrid session-key HKDF `info`. The corrected
    /// construction folds `HMAC-SHA256(this, pqcCiphertext)` into `info`
    /// so a MITM cannot substitute a re-encapsulating ciphertext (the
    /// prior 2-leg combine had NO ciphertext binding — schema :1, now
    /// superseded). MUST be byte-identical to firmware `LABEL_CT_BIND`,
    /// Android `HYBRID_CT_BIND_LABEL`, Desktop `HYBRID_CT_BIND`.
    /// Spec: apps/qaudion-firmware/docs/CROSS_PLATFORM_HYBRID_KDF.md.
    public static let hybridCtBindV1: Data = Data("q-audion-ct-bind-v1".utf8)

    /// CALL-4/HSID-002 — SAS `info` REPLACEMENT (not appended) used by
    /// `ComputeSasUseCase.invoke` in place of `SasConstants.infoWordsBytes`
    /// when the caller supplies a non-nil `transcriptHash`. A DISTINCT label
    /// from the session-key KDF's own `info` prefix (`hybridPqcSessionKey`
    /// above) is required even though both fold in the SAME transcript hash
    /// — an independent security review confirmed
    /// reusing one domain-separated hash across two HKDF derivations is safe
    /// only when each derivation carries its own label; reusing the hash
    /// WITHOUT distinct prefixes is not. 23 bytes, NOT null-terminated.
    ///
    /// ITEM 2/3 FOLLOW-UP (2026-09-02) — reconciled to Android's canonical
    /// value `"q-audion-sas-transcript"` (`SasConstants
    /// .INFO_WORDS_TRANSCRIPT_BOUND_PREFIX`, `HybridPqcKeyExchange.kt`
    /// sibling `PgpSasWords.kt`), NO trailing `-v1` version suffix. This
    /// label previously carried a `-v1` suffix (27 bytes) that Android never
    /// had — the two platforms' independent implementations diverged on a
    /// detail neither this fix's own kdoc above nor the original security
    /// review actually required (a distinct label is what matters, not its
    /// exact spelling), so the shorter Android string is the shared cross-platform value.
    /// Under transcript v5 the SAS is always bound to `SHA-256(ACCEPT_v5)` (WIRE_SPEC §4).
    public static let sasTranscriptBindV1: Data = Data("q-audion-sas-transcript".utf8)

    /// 1:1 directional frame keys (transcript v5, owner decision O1): HKDF `info` prefix. The full
    /// info is `frameKeyInfoPrefixV5 || callId || ":o2a"` or `":a2o"` (ASCII, no NUL, `callId`
    /// exactly as in the transcript). See `OneToOneFrameKeys`. 22 bytes, NOT null-terminated.
    public static let frameKeyInfoPrefixV5: Data = Data("q-audion-frame-key-v5:".utf8)

    // MARK: - Salts (UTF-8)

    /// 1:1 directional frame keys (transcript v5): HKDF salt. 21 bytes.
    public static let frameKeySaltV5: Data = Data("qaudion-frame-salt-v5".utf8)

    /// Hybrid PQC session key salt (used as the HKDF Extract salt when no
    /// PSK is present; the PSK replaces it when one is negotiated).
    public static let hybridPqcSaltV1: Data = Data("q-audion-hybrid-pqc-v1".utf8)

    /// Device-link PSK salt (counterpart to `deviceLinkPsk` info).
    public static let deviceLinkSalt: Data = Data("qaudion-link-salt".utf8)

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
            recoveryAuth, recoverySalt, hybridPqcSaltV1, hybridCtBindV1,
            deviceLinkSalt, frameKeyInfoPrefixV5, frameKeySaltV5,
            sasTranscriptBindV1
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

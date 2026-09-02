import Foundation

/// Loads the DEDICATED remote-wipe signing public key that `WipeCommandVerifier`
/// pins, from an SPKI PEM committed as a build asset — TRUST-2
/// (`docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md`).
///
/// ## Why a NEW key, not the OTA/entitlement key
/// TRUST-2 is explicit: the server must sign the wipe command with a NEW,
/// DEDICATED Ed25519 keypair, never the OTA/entitlement signing key —
/// different purpose, different blast radius if the private half is ever
/// compromised. Reusing `bcrypto_entitlement_pubkey.pem` (or an OTA key) here
/// would mean a compromise of either channel doubles as a wipe primitive.
///
/// ## Packaging convention mirrored, not invented
/// This file is `EntitlementPublicKey.swift` with the nouns swapped — SAME
/// SPM `.copy()` resource in `Sources/QAudionEngine/Resources/`, read back
/// through `Bundle.module`, SAME last-32-bytes-of-the-44-byte-SPKI-DER
/// extraction, SAME "compare decoded key bytes, not PEM text" ship-guard
/// discipline (this repo has `core.autocrlf=true` and no `.gitattributes`
/// pinning `.pem`, so the committed file is CRLF on a Windows checkout and LF
/// on the macOS CI runner — see `EntitlementPublicKey`'s own kdoc for the
/// prior incident that made this the rule, not a stylistic choice).
/// `BCryptoOtaModelClient` was checked as an alternative template and
/// rejected for the identical reason `EntitlementPublicKey.swift` already
/// documents: its trust anchors are an injected, runtime-fetched map, not a
/// pinned build asset — the opposite of what TRUST-2 asks for ("Client
/// embeds the PUBLIC key only ... as a packaged asset, mirroring exactly how
/// bcrypto_ota_pubkey.pem is already embedded" — iOS has no
/// `bcrypto_ota_pubkey.pem`; `bcrypto_entitlement_pubkey.pem` /
/// `EntitlementPublicKey.swift` is the actual closest precedent on this
/// platform and the one this mirrors).
///
/// ## ⚠️ The committed asset is a PLACEHOLDER
/// `Resources/wipe_signing_pubkey.pem` currently holds a throwaway keypair
/// generated for this task (`openssl genpkey -algorithm ed25519`) — the
/// PRIVATE half was never persisted anywhere, only the public half is
/// committed. It is **not** a production key; bcrypto-server had not issued
/// one at the time this file was written (verified: no
/// `wipe_signing_pubkey.pem` in the sibling `bcrypto-server` repo). Every
/// real `remote_wipe` command signed by the eventual production key will
/// FAIL verification against this placeholder — fail-closed (refuses to
/// wipe), not fail-open — until the real public key is substituted in.
/// Swapping the asset's content is the only change needed when it lands;
/// nothing in this file or in `WipeCommandVerifier` has to change.
///
/// `WipeSigningPublicKeyTests.testCommittedAssetIsNotStillThePlaceholderKey`
/// is the ship-guard for that swap, deliberately skipped today for the same
/// reason `EntitlementPublicKeyTests`' equivalent guard was skipped before
/// its real key landed.
public enum WipeSigningPublicKey {

    /// Basename of the SPM `.copy()` resource declared in `Package.swift`.
    static let assetName = "wipe_signing_pubkey"
    static let assetExtension = "pem"

    /// The 32 raw bytes of the throwaway placeholder key, as base64. The
    /// ship-guard compares against THIS — the decoded key material — never
    /// the PEM file's text (see the CRLF/LF note above).
    static let placeholderRawKeyBase64 = "aF2vnjOZUNwivLypax55VnzgUejm8oGiEoa9A+aTFcY="

    /// Errors are not modelled: every failure here means the app was built
    /// wrong (asset missing from the bundle, or unparseable), which no
    /// runtime branch can recover from. `nil` keeps the fail-closed contract
    /// `WipeCommandVerifier` has — a caller that gets `nil` must treat EVERY
    /// remote_wipe command as unverifiable and refuse to act, never as
    /// "unrestricted" or "verification not required".
    public static func makeVerifier() -> WipeCommandVerifier? {
        guard let raw = loadPinnedRawKey() else { return nil }
        return WipeCommandVerifier(pinnedPublicKeyRaw: raw)
    }

    /// Reads the committed asset out of `Bundle.module` and returns the raw
    /// 32-byte Ed25519 key. Internal rather than private so the ship-guard
    /// test can assert against the REAL bundled asset instead of an
    /// in-memory copy of what the asset is supposed to contain.
    static func loadPinnedRawKey() -> Data? {
        guard let url = Bundle.module.url(forResource: assetName, withExtension: assetExtension),
              let pem = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return rawKey(fromSpkiPem: pem)
    }

    /// Extracts the raw 32-byte Ed25519 public key from an SPKI PEM. Same
    /// extraction as `EntitlementPublicKey.rawKey(fromSpkiPem:)` — an Ed25519
    /// SPKI DER is always 44 bytes (fixed 12-byte header + the 32-byte key),
    /// so the key is simply the last 32 bytes.
    static func rawKey(fromSpkiPem pem: String) -> Data? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        guard let der = Data(base64Encoded: body), der.count >= 32 else { return nil }
        return Data(der.suffix(32))
    }
}

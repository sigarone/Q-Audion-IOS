import Foundation

/// Loads the entitlement signing public key that `EgtVerifier` pins, from
/// the SPKI PEM committed as a build asset (design doc §3.5: the key is
/// "pinned in the app as a build asset", not fetched).
///
/// ## Why this file exists instead of copying an existing iOS pattern
/// Android's equivalent (`EgtVerifier.loadPinnedPublicKey`) could mirror
/// `OtaSignatureVerifier`, which already pinned a PEM in `assets/`. iOS has
/// no such precedent to copy: the closest-looking candidate,
/// `BCryptoOtaModelClient`, takes its `Curve25519.Signing.PublicKey` trust
/// anchors as an injected map whose real values are **fetched at runtime**
/// from `/api/v1/updates/publickey` (see `OtaUpdateScreen.swift`) — the
/// opposite of pinning, and unusable as a template here. So the mechanism
/// below is built rather than borrowed, on the one bundled-non-fetched-asset
/// pattern this package does already have: an SPM `.copy()` resource in
/// `Sources/QAudionEngine/Resources/` read back through `Bundle.module`,
/// exactly as `CamPlusSpeakerEmbedder` and `DeepfakeClassifier` load their
/// pinned ONNX models.
///
/// ## ⚠️ The committed asset is a PLACEHOLDER
/// `Resources/bcrypto_entitlement_pubkey.pem` currently holds a throwaway
/// test keypair — byte-identical to the one Android committed, and the same
/// key that signs `EgtVerifierTests`' KAT vectors. It is **not** the
/// production `ent-v1` key, which the server has not issued yet. Swapping
/// the asset's content is the only change needed when it does; nothing in
/// this file or in `EgtVerifier` has to change, because the key format
/// (SPKI PEM in, raw 32 bytes out) is fixed.
///
/// `EntitlementPublicKeyTests.testCommittedAssetIsNotStillThePlaceholderKey`
/// is the ship-guard for that swap. It is deliberately skipped today (the
/// real key does not exist), and re-arming it is a hard prerequisite of
/// Task 3 (`CapabilityGate`), the first task that puts this key on a path
/// real users depend on.
public enum EntitlementPublicKey {

    /// Basename of the SPM `.copy()` resource declared in `Package.swift`.
    /// Same filename Android uses for the same bytes, so the two platforms'
    /// assets are greppable as one thing.
    static let assetName = "bcrypto_entitlement_pubkey"
    static let assetExtension = "pem"

    /// The 32 raw bytes of the throwaway placeholder key, as base64. The
    /// ship-guard compares against THIS — the decoded key material — and
    /// not against the PEM file's text.
    ///
    /// That distinction is load-bearing, not stylistic. This repo has
    /// `core.autocrlf=true` and no `.gitattributes` pinning `.pem`, so the
    /// same committed file is CRLF in a Windows checkout and LF on the
    /// macOS CI runner. Android's equivalent guard compared PEM *text*,
    /// silently never fired because of exactly that mismatch, and had to be
    /// fixed with a `replace("\r\n", "\n")` after the fact. Comparing
    /// decoded key bytes is immune to line endings, whitespace, and PEM
    /// re-wrapping, so this guard cannot fail open the same way.
    static let placeholderRawKeyBase64 = "ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="

    /// Errors are not modelled: every failure here means the app was built
    /// wrong (asset missing from the bundle, or unparseable), which no
    /// runtime branch can recover from. `nil` keeps the same fail-closed
    /// contract `EgtVerifier` has — a caller that gets `nil` must treat the
    /// user as having no verifiable entitlement, never as unrestricted.
    public static func makeVerifier() -> EgtVerifier? {
        guard let raw = loadPinnedRawKey() else { return nil }
        return EgtVerifier(pinnedPublicKeyRaw: raw)
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

    /// Extracts the raw 32-byte Ed25519 public key from an SPKI PEM.
    ///
    /// An Ed25519 SPKI DER is 44 bytes: a fixed 12-byte header
    /// (SEQUENCE / AlgorithmIdentifier `1.3.101.112` / BIT STRING) followed
    /// by the 32-byte key, so the key is simply the last 32 bytes — the
    /// same extraction `EgtVerifierTests` documents for its KAT pubkey and
    /// the same one Android's `loadPinnedPublicKey` performs.
    ///
    /// Pure and separately testable on purpose: it is the one part of this
    /// file that can be exercised without a bundle.
    static func rawKey(fromSpkiPem pem: String) -> Data? {
        let body = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        // Reject rather than truncate a too-short DER: a 44-byte SPKI is
        // the only shape this is ever handed, and silently taking the
        // "last 32 bytes" of something shorter would hand EgtVerifier
        // garbage that its own length check might not catch.
        guard let der = Data(base64Encoded: body), der.count >= 32 else { return nil }
        // Re-wrap the slice: `suffix` returns a Data whose indices start at
        // der.count-32, not 0. CryptoKit and `==` both handle that fine,
        // but any later `raw[0]` on the returned value would not.
        return Data(der.suffix(32))
    }
}

import Foundation
import CryptoKit

/// Verifies a compact EGT (`header.payload.sig`, base64url, design doc §3.1)
/// against the entitlement public key pinned as a build asset, and decodes
/// its claims. This is the ONE place in the entitlements rollout where a
/// forged or tampered token could be silently trusted if verification is
/// wrong, so every failure mode below is fail-closed: `nil`, never a thrown
/// error.
///
/// ## Algorithm pinning — the core security property
/// The algorithm is fixed to `EdDSA`. There is no algorithm negotiation and
/// no allowlist to bypass: `verify` checks `header.alg == "EdDSA"` and
/// `header.typ == "BEGT"` and returns `nil` immediately if either check
/// fails — **before** the signature bytes are even decoded, let alone
/// checked against the pinned key. A token whose header says
/// `"alg":"none"`, `"alg":"HS256"`, or anything else is rejected at that
/// gate, not at a signature-verify failure. This closes the classic JWT
/// algorithm-confusion class of attack (this repo's cybersecurity skill
/// `exploiting-jwt-algorithm-confusion-attack`). See
/// `EgtVerifierTests.testAlgPinningHappensBeforeAnySignatureVerifyCall` for
/// the mechanical proof that the ordering genuinely holds, not just that
/// bad tokens happen to also fail signature verification.
///
/// `kid` is checked to be present as a non-empty JSON string, but is
/// **never** used to select a different verification key — there is
/// exactly one pinned key. Treating an attacker-controlled `kid` as a
/// lookup index into key material is exactly the embedded-key-trust bug
/// this design avoids (design doc §3.5 describes a *future* cross-signed
/// rotation scheme; this task deliberately does not build that — `kid`
/// today is informational only), matching Android's `EgtVerifier.kt`
/// exactly (design doc §13 cross-platform parity).
///
/// ## Where does the actual Ed25519 verify come from?
/// `CryptoKit.Curve25519.Signing.PublicKey.isValidSignature(_:for:)` —
/// Ed25519 verification, built into the platform since iOS 13, no new
/// dependency. Confirmed already the load-bearing primitive for exactly
/// this class of check elsewhere in this codebase:
/// `BCryptoOtaModelClient.fetchManifest` (`Backend/BCrypto/`) verifies
/// AASIST model-update manifests the same way — pinned
/// `Curve25519.Signing.PublicKey` trust anchors, `isValidSignature` over
/// canonical signed bytes. `ComputeSasUseCase.swift`'s
/// `CryptoKit.HKDF<SHA256>` usage additionally confirms CryptoKit itself is
/// already a live dependency of this module, not a new import — unlike
/// Android, which needed an investigation sub-step to find a usable
/// Ed25519 primitive (its obvious candidate, `RatchetNative`'s JNI
/// binding, exposes no raw signature-verify primitive at all), iOS has
/// this natively and needs no equivalent detour.
public final class EgtVerifier {
    /// The Ed25519 signature-verify primitive, bound to the pinned key.
    /// Kept as an injectable closure (rather than calling
    /// `pinnedPublicKey.isValidSignature` inline) purely so tests can prove
    /// the alg-pinning-before-signature-verify ordering mechanically by
    /// spying on invocation count — see the internal test initializer
    /// below. Production code only ever goes through the public
    /// initializer, which always binds this to the real CryptoKit call.
    private let verifySignature: (_ signature: Data, _ signedBytes: Data) -> Bool

    /// - Parameter pinnedPublicKeyRaw: the 32-byte raw Ed25519 public key
    ///   (not SPKI-wrapped — see `EgtVerifierTests` for how to extract the
    ///   raw key from an SPKI PEM). Returns `nil` if the bytes are not a
    ///   valid Curve25519 signing key (e.g. wrong length), matching this
    ///   class's fail-closed contract even at construction time.
    public init?(pinnedPublicKeyRaw: Data) {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pinnedPublicKeyRaw) else {
            return nil
        }
        self.verifySignature = { signature, signedBytes in
            key.isValidSignature(signature, for: signedBytes)
        }
    }

    /// Test-only seam (internal, reachable via `@testable import` from
    /// `QAudionEngineTests`): lets a test spy on the signature-verify
    /// primitive without needing to mock a CryptoKit struct (CryptoKit's
    /// types are concrete, not protocol-based, so they cannot be mocked
    /// the way Android's `EgtVerifierTest` spies on `HandshakeTranscript`
    /// via `mockkObject`). Never used outside tests.
    init(verifySignatureOverride: @escaping (_ signature: Data, _ signedBytes: Data) -> Bool) {
        self.verifySignature = verifySignatureOverride
    }

    /// Verifies `compactToken` and returns its decoded claims, or `nil` on
    /// ANY failure (malformed structure, wrong algorithm, bad signature,
    /// unparseable payload). Never throws.
    ///
    /// Deliberately does NOT reject on `exp` (envelope expiry) or on any
    /// `fea[key]` per-feature expiry being in the past — design doc §3.2 is
    /// explicit that `exp` is "a REFRESH TARGET, not a kill switch": on
    /// expiry the client tries to renew and on failure keeps using the
    /// token it has, and per-feature expiry is evaluated at USE time by
    /// `CapabilityGate.has` (Task 3), not at cache-load/verify time. Gating
    /// here on either would silently reintroduce the "connectivity outage
    /// looks like a downgrade" failure design doc §3.2 explicitly rules
    /// out — an expired-but-still-signed token must decode successfully so
    /// the caller can decide what to do with it.
    public func verify(_ compactToken: String) -> EgtClaims? {
        let parts = compactToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        guard let headerData = Self.base64UrlDecode(String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return nil
        }

        // Algorithm/type/kid-presence gate. This MUST run — and MUST
        // return, on failure — before any signature bytes are decoded or
        // checked. Do not reorder this above the signature-verify call
        // below without re-reading the kdoc above.
        guard header["alg"] as? String == "EdDSA",
              header["typ"] as? String == "BEGT",
              let kid = header["kid"] as? String, !kid.isEmpty else {
            return nil
        }

        guard let signature = Self.base64UrlDecode(String(parts[2])) else { return nil }
        let signedPart = "\(parts[0]).\(parts[1])"
        guard verifySignature(signature, Data(signedPart.utf8)) else { return nil }

        guard let payloadData = Self.base64UrlDecode(String(parts[1])) else { return nil }
        return try? JSONDecoder().decode(EgtClaims.self, from: payloadData)
    }

    // MARK: - base64url (RFC 7515 JWS compact serialization, no padding)

    private static func base64UrlDecode(_ s: String) -> Data? {
        var padded = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch padded.count % 4 {
        case 2: padded += "=="
        case 3: padded += "="
        case 1: return nil // not a valid base64 length under any padding
        default: break
        }
        return Data(base64Encoded: padded)
    }
}

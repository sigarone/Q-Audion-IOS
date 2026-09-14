import XCTest
import CryptoKit
@testable import QAudionEngine

/// W-SASPIN (2026-09-08) — pins the first-verified-contact pin rule of
/// `HandshakeSigningPolicy.evaluate`.
///
/// Live incident: two iOS devices (1.0.1108, calls bba2aeca / 1cd640d6) verified
/// every handshake cleanly and still logged 20 × `sasConfirm noop=1 reason=3`
/// — the in-call SAS confirm needs the peer's pinned identity key to bind the
/// record, and the policy never returned a pin candidate when the trust anchor
/// was the server-published key (it only did on bundle-key TOFU). No test ever
/// exercised `evaluate` with `serverFetchedKey != nil`; these do.
final class HandshakeSigningPolicyPinTests: XCTestCase {

    private func makeSigner() -> (priv: Curve25519.Signing.PrivateKey, pubRaw: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv, priv.publicKey.rawRepresentation)
    }

    private func transcript(_ seed: UInt8) -> Data {
        Data((0..<64).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) })
    }

    /// The regression: no pin yet, server key present and equal to the signer →
    /// the verdict MUST carry the server key as the pin candidate.
    func testServerAnchoredFirstContactReturnsPinCandidate() throws {
        let (priv, pubRaw) = makeSigner()
        let t = transcript(3)
        let sig = try priv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: pubRaw,
            requireSigned: false, advertisedV4: false
        )
        XCTAssertEqual(
            verdict,
            .authenticated(tofuPinKey: pubRaw, v4Capable: false, srtpDirKeyV1Capable: false),
            "a verified handshake with the server-published key as anchor must hand the key back to be pinned"
        )
    }

    /// Unchanged: genuine first contact (no pin, no server key) still pins the
    /// bundle key.
    func testBundleTofuFirstContactStillReturnsPinCandidate() throws {
        let (priv, pubRaw) = makeSigner()
        let t = transcript(5)
        let sig = try priv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: true
        )
        XCTAssertEqual(
            verdict,
            .authenticated(tofuPinKey: pubRaw, v4Capable: true, srtpDirKeyV1Capable: false)
        )
    }

    /// Unchanged: an existing pin is never re-pinned from the `.authenticated`
    /// path (write-once stays write-once; only a set-proven rotation may
    /// overwrite, via `.authenticatedRepinFromPublished`).
    func testExistingPinReturnsNoPinCandidate() throws {
        let (priv, pubRaw) = makeSigner()
        let t = transcript(9)
        let sig = try priv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: t,
            pinnedKey: pubRaw, serverFetchedKey: pubRaw,
            requireSigned: false, advertisedV4: false
        )
        XCTAssertEqual(
            verdict,
            .authenticated(tofuPinKey: nil, v4Capable: false, srtpDirKeyV1Capable: false)
        )
    }

    /// Unchanged: a server key that does NOT match the bundle key (and no
    /// published set proving the bundle key) is still the unauthenticated
    /// key-change verdict — the fix must not turn that into a pin.
    func testServerKeyMismatchIsStillIdentityKeyMismatch() throws {
        let (priv, pubRaw) = makeSigner()
        let (_, otherPub) = makeSigner()
        let t = transcript(11)
        let sig = try priv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: otherPub,
            requireSigned: false, advertisedV4: false
        )
        XCTAssertEqual(verdict, .abort(code: "identity_key_mismatch"))
    }

    /// Unchanged: a present-but-wrong signature under the server key is fatal
    /// and pins nothing.
    func testInvalidSignatureUnderServerKeyPinsNothing() throws {
        let (_, pubRaw) = makeSigner()
        let (otherPriv, _) = makeSigner()
        let t = transcript(13)
        let wrongSig = try otherPriv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: wrongSig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: pubRaw,
            requireSigned: false, advertisedV4: false
        )
        XCTAssertEqual(verdict, .abort(code: "sig_invalid"))
    }
}

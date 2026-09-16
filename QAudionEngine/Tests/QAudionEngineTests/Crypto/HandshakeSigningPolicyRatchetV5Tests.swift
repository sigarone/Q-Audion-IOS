import XCTest
import CryptoKit
@testable import QAudionEngine

/// Q-Audion Dual-Channel Ratchet v5, MUST-FIX #1 (security review 2026-09-16) — the STICKY
/// half of the anti-downgrade invariant inside `HandshakeSigningPolicy.evaluate`: a peer that
/// has ever proven `ratchetV5`-capable and later presents a validly-signed bundle honestly
/// claiming `ratchetV5=false` is flagged (`.abort(code: "ratchet_v5_downgrade")`) rather than
/// silently accepted as a normal fallback. Mirrors Android
/// `HandshakeSigner.verifyBundle`'s / Desktop `decideSignatureVerdict`'s equivalent tests
/// (`HandshakeSigningTest.kt` / `handshakeTranscriptV4.spec.ts`).
final class HandshakeSigningPolicyRatchetV5Tests: XCTestCase {

    private func makeSigner() -> (priv: Curve25519.Signing.PrivateKey, pubRaw: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv, priv.publicKey.rawRepresentation)
    }

    private func transcript(_ seed: UInt8) -> Data {
        Data((0..<64).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) })
    }

    /// A previously-pinned peer presenting a validly-signed bundle that now claims
    /// `ratchetV5=false` must be ABORTED with `ratchet_v5_downgrade`, not silently accepted —
    /// regardless of which sigVN tier actually verifies (this test uses the v1 `transcript`
    /// param directly, exactly as a legacy/v1-only-signed fallback bundle would).
    func testPreviouslyPinnedPeerClaimingFalseIsFlaggedAsDowngrade() throws {
        let (priv, pubRaw) = makeSigner()
        let t = transcript(21)
        let sig = try priv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            advertisedRatchetV5: false,
            ratchetV5CapablePinned: true
        )
        XCTAssertEqual(verdict, .abort(code: "ratchet_v5_downgrade"))
    }

    /// A peer with NO prior pin claiming `ratchetV5=false` verifies normally — nothing to
    /// downgrade FROM, so this must NOT be flagged.
    func testUnpinnedPeerClaimingFalseVerifiesNormally() throws {
        let (priv, pubRaw) = makeSigner()
        let t = transcript(22)
        let sig = try priv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            advertisedRatchetV5: false,
            ratchetV5CapablePinned: false
        )
        XCTAssertEqual(
            verdict,
            .authenticated(tofuPinKey: pubRaw, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: false)
        )
    }

    /// A previously-pinned peer that STILL claims `ratchetV5=true` (honest, no downgrade)
    /// verifies normally and the verdict carries `ratchetV5Capable: true` (re-pins the same
    /// write-once-true fact, a no-op for the caller's storage layer).
    func testPreviouslyPinnedPeerStillClaimingTrueVerifiesNormally() throws {
        let (priv, pubRaw) = makeSigner()
        let t = transcript(23)
        let sig = try priv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            advertisedRatchetV5: true,
            ratchetV5CapablePinned: true
        )
        XCTAssertEqual(
            verdict,
            .authenticated(tofuPinKey: pubRaw, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: true)
        )
    }

    /// The downgrade check must fire BEFORE the sig-invalid check would even matter for a
    /// PRESENT-but-wrong signature — i.e. it is a post-verification gate, not a
    /// pre-verification one: a bad signature is still `sig_invalid`, never masked by the
    /// downgrade code.
    func testInvalidSignatureStaysSigInvalidRegardlessOfPin() throws {
        let (_, pubRaw) = makeSigner()
        let (otherPriv, _) = makeSigner()
        let t = transcript(24)
        let wrongSig = try otherPriv.signature(for: t)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: wrongSig.base64EncodedString(),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            advertisedRatchetV5: false,
            ratchetV5CapablePinned: true
        )
        XCTAssertEqual(verdict, .abort(code: "sig_invalid"))
    }
}

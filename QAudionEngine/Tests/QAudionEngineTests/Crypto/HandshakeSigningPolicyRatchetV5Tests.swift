import XCTest
import CryptoKit
@testable import QAudionEngine

/// Sticky half of the ratchetV5 anti-downgrade invariant inside `HandshakeSigningPolicy.evaluate`:
/// a peer that has ever proven `ratchetV5`-capable and later presents a validly-signed bundle
/// honestly claiming `ratchetV5=false` is flagged (`.abort("ratchet_v5_downgrade")`).
final class HandshakeSigningPolicyRatchetV5Tests: XCTestCase {

    private typealias F = V5TestFixtures

    private func evaluate(
        seed: UInt8, signWith: UInt8? = nil, advertisedRatchetV5: Bool, pinnedCapable: Bool
    ) throws -> (HandshakeSigningPolicy.Verdict, Data) {
        let (priv, pubRaw) = F.signer(seed: seed)
        let t = F.offerTranscript(signerKey: pubRaw)
        let signer = signWith.map { F.signer(seed: $0).priv } ?? priv
        let sig = try signer.signature(for: t)
        let v = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            sigV5B64: sig.base64EncodedString(),
            dtlsFingerprintText: F.fingerprintText("offerer"),
            transcript: t,
            pinnedKey: nil, serverFetchedKey: pubRaw,
            advertisedV4: false,
            advertisedRatchetV5: advertisedRatchetV5,
            ratchetV5CapablePinned: pinnedCapable)
        return (v, pubRaw)
    }

    func testPreviouslyPinnedPeerClaimingFalseIsFlaggedAsDowngrade() throws {
        let (v, _) = try evaluate(seed: 31, advertisedRatchetV5: false, pinnedCapable: true)
        XCTAssertEqual(v, .abort(code: "ratchet_v5_downgrade"))
    }

    func testUnpinnedPeerClaimingFalseVerifiesNormally() throws {
        let (v, pub) = try evaluate(seed: 32, advertisedRatchetV5: false, pinnedCapable: false)
        XCTAssertEqual(
            v, .authenticated(tofuPinKey: pub, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: false))
    }

    func testPreviouslyPinnedPeerStillClaimingTrueVerifiesNormally() throws {
        let (v, pub) = try evaluate(seed: 33, advertisedRatchetV5: true, pinnedCapable: true)
        XCTAssertEqual(
            v, .authenticated(tofuPinKey: pub, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: true))
    }

    /// The downgrade check is a post-verification gate: a bad signature stays `sig_invalid`.
    func testInvalidSignatureStaysSigInvalidRegardlessOfPin() throws {
        let (v, _) = try evaluate(seed: 34, signWith: 35, advertisedRatchetV5: false, pinnedCapable: true)
        XCTAssertEqual(v, .abort(code: "sig_invalid"))
    }
}

import XCTest
import CryptoKit
@testable import QAudionEngine

/// W-SASPIN pin rule of `HandshakeSigningPolicy.evaluate` under transcript v5: the first
/// verified contact hands back the trusted key as the pin candidate; an existing pin is never
/// re-pinned from `.authenticated`; a key that disagrees with the trusted one is a mismatch; an
/// invalid signature pins nothing; F8: missing/malformed signing material is `.malformed`.
final class HandshakeSigningPolicyPinTests: XCTestCase {

    private typealias F = V5TestFixtures

    private struct Case {
        let pubRaw: Data
        let transcript: Data
        let sigB64: String
        let fpText: String
    }

    private func makeCase(seed: UInt8, signWith: UInt8? = nil) throws -> Case {
        let (priv, pubRaw) = F.signer(seed: seed)
        let t = F.offerTranscript(signerKey: pubRaw)
        let signingKey = signWith.map { F.signer(seed: $0).priv } ?? priv
        let sig = try signingKey.signature(for: t)
        return Case(pubRaw: pubRaw, transcript: t, sigB64: sig.base64EncodedString(), fpText: F.fingerprintText("offerer"))
    }

    private func evaluate(
        _ c: Case,
        sigB64: String? = nil, dropSig: Bool = false,
        fpText: String? = nil, dropFp: Bool = false,
        transcript: Data? = nil, dropTranscript: Bool = false,
        pinned: Data? = nil, server: Data? = nil, v4: Bool = false
    ) -> HandshakeSigningPolicy.Verdict {
        HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: c.pubRaw.base64EncodedString(),
            sigV5B64: dropSig ? nil : (sigB64 ?? c.sigB64),
            dtlsFingerprintText: dropFp ? nil : (fpText ?? c.fpText),
            transcript: dropTranscript ? nil : (transcript ?? c.transcript),
            pinnedKey: pinned, serverFetchedKey: server,
            advertisedV4: v4)
    }

    /// No pin yet, server key present and equal to the signer: the verdict carries the server key
    /// as the pin candidate.
    func testServerAnchoredFirstContactReturnsPinCandidate() throws {
        let c = try makeCase(seed: 3)
        XCTAssertEqual(
            evaluate(c, server: c.pubRaw),
            .authenticated(tofuPinKey: c.pubRaw, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: false))
    }

    /// No pin and no server key (the identity fetch failed or has not landed): the bundle key is
    /// never trusted blindly and never pinned. The call is not dropped (W-NOBRICK) but media is
    /// held pending the SAS: `.abort("identity_unresolved")`, like Android.
    func testNoPinAndNoServerKeyHoldsMediaAndNeverPinsTheBundleKey() throws {
        let c = try makeCase(seed: 5)
        XCTAssertEqual(evaluate(c, v4: true), .abort(code: "identity_unresolved"))
        // Even a perfectly valid signature under the bundle's own key changes nothing.
        let v = evaluate(c)
        if case .authenticated = v { XCTFail("an unresolved identity must never be authenticated") }
        if case .authenticatedRepinFromPublished = v { XCTFail("an unresolved identity must never be re-pinned") }
    }

    /// The server-published per-device set is a server source: a member bundle key is accepted
    /// (and is the pin candidate), a non-member is an unauthenticated change.
    func testPublishedSetWithoutPinOrServerKey() throws {
        let c = try makeCase(seed: 6)
        let other = F.signer(seed: 7).pubRaw
        let member = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: c.pubRaw.base64EncodedString(), sigV5B64: c.sigB64,
            dtlsFingerprintText: c.fpText, transcript: c.transcript,
            pinnedKey: nil, serverFetchedKey: nil, publishedKeySet: [c.pubRaw, other], advertisedV4: false)
        XCTAssertEqual(
            member,
            .authenticated(tofuPinKey: c.pubRaw, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: false))
        let nonMember = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: c.pubRaw.base64EncodedString(), sigV5B64: c.sigB64,
            dtlsFingerprintText: c.fpText, transcript: c.transcript,
            pinnedKey: nil, serverFetchedKey: nil, publishedKeySet: [other], advertisedV4: false)
        XCTAssertEqual(nonMember, .abort(code: "identity_key_mismatch"))
    }

    /// A pin keeps working when the server fetch failed (the offline local-pin path).
    func testPinAloneStillAuthenticatesWhenTheServerFetchFailed() throws {
        let c = try makeCase(seed: 8)
        XCTAssertEqual(
            evaluate(c, pinned: c.pubRaw),
            .authenticated(tofuPinKey: nil, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: false))
    }

    /// An existing pin is never re-pinned from `.authenticated` (write-once).
    func testExistingPinReturnsNoPinCandidate() throws {
        let c = try makeCase(seed: 9)
        XCTAssertEqual(
            evaluate(c, pinned: c.pubRaw, server: c.pubRaw),
            .authenticated(tofuPinKey: nil, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: false))
    }

    /// A server key that does not match the bundle key (and no published set) is the
    /// unauthenticated key-change verdict, never a pin.
    func testServerKeyMismatchIsIdentityKeyMismatch() throws {
        let c = try makeCase(seed: 11)
        let other = F.signer(seed: 12).pubRaw
        XCTAssertEqual(evaluate(c, server: other), .abort(code: "identity_key_mismatch"))
    }

    /// A present-but-wrong signature is `sig_invalid` and pins nothing.
    func testInvalidSignatureUnderServerKeyPinsNothing() throws {
        let c = try makeCase(seed: 13, signWith: 14)
        XCTAssertEqual(evaluate(c, server: c.pubRaw), .abort(code: "sig_invalid"))
    }

    /// A signature over a DIFFERENT transcript (another DTLS fingerprint) does not verify.
    func testSignatureOverOtherDtlsFingerprintIsInvalid() throws {
        let c = try makeCase(seed: 15)
        let swapped = F.offerTranscript(signerKey: c.pubRaw, dtls: F.fingerprint("intruder"))
        XCTAssertEqual(evaluate(c, transcript: swapped, server: c.pubRaw), .abort(code: "sig_invalid"))
    }

    // MARK: - F8 malformed

    func testMissingSigIsMalformed() throws {
        let c = try makeCase(seed: 16)
        XCTAssertEqual(evaluate(c, dropSig: true), .malformed(code: "sig_missing"))
        XCTAssertEqual(evaluate(c, sigB64: ""), .malformed(code: "sig_missing"))
    }

    func testShortSigIsMalformed() throws {
        let c = try makeCase(seed: 17)
        XCTAssertEqual(evaluate(c, sigB64: Data(count: 63).base64EncodedString()), .malformed(code: "sig_malformed"))
    }

    func testMissingFingerprintIsMalformed() throws {
        let c = try makeCase(seed: 18)
        XCTAssertEqual(evaluate(c, dropFp: true), .malformed(code: "dtlsfp_missing"))
    }

    func testNonCanonicalFingerprintIsMalformed() throws {
        let c = try makeCase(seed: 19)
        XCTAssertEqual(evaluate(c, fpText: c.fpText.lowercased()), .malformed(code: "dtlsfp_malformed"))
        XCTAssertEqual(evaluate(c, fpText: "sha-1 AB:CD"), .malformed(code: "dtlsfp_malformed"))
    }

    func testUnbuildableTranscriptIsMalformed() throws {
        let c = try makeCase(seed: 20)
        XCTAssertEqual(evaluate(c, dropTranscript: true), .malformed(code: "transcript_unbuildable"))
    }

    func testMissingSignerKeyIsMalformed() throws {
        let c = try makeCase(seed: 21)
        let v = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: nil, sigV5B64: c.sigB64, dtlsFingerprintText: c.fpText,
            transcript: c.transcript, pinnedKey: nil, serverFetchedKey: nil, advertisedV4: false)
        XCTAssertEqual(v, .malformed(code: "sig_missing"))
    }

    // MARK: - D11 published set

    func testPublishedSetProvesRotation() throws {
        let c = try makeCase(seed: 22)
        let oldKey = F.signer(seed: 23).pubRaw
        let v = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: c.pubRaw.base64EncodedString(), sigV5B64: c.sigB64,
            dtlsFingerprintText: c.fpText, transcript: c.transcript,
            pinnedKey: oldKey, serverFetchedKey: nil, publishedKeySet: [c.pubRaw, oldKey],
            advertisedV4: false)
        XCTAssertEqual(
            v,
            .authenticatedRepinFromPublished(
                deviceKey: c.pubRaw, v4Capable: false, srtpDirKeyV1Capable: false, ratchetV5Capable: false))
    }
}

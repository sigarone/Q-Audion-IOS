import XCTest
import CryptoKit
@testable import QAudionEngine

/// Q-Audion Dual-Channel Ratchet v5, MUST-FIX #1 (security review 2026-09-16) —
/// independent, first-principles reconstruction tests for the v4 transcript
/// additions (`domainV4`, the 9th CAPS byte `ratchetV5`, `offerV4`, `acceptV4`).
///
/// This file does NOT touch, re-derive, or re-run `offer`/`accept` (v1),
/// `offerV2`/`acceptV2`, or `offerV3`/`acceptV3` — those functions are
/// byte-for-byte UNCHANGED by this addition (v4 is a fourth, purely additive
/// transcript domain, mirroring how `domainV3` did not touch `domain`/`domainV2`).
/// `HandshakeTranscriptV3Tests.swift` remains the proof those stayed
/// byte-identical: this fix never edited any of their bodies.
final class HandshakeTranscriptV4Tests: XCTestCase {

    // MARK: - Fixtures (mirrors HandshakeTranscriptV3Tests' own helpers)

    private func fixedBytes(_ n: Int, seed: UInt8) -> Data {
        Data((0..<n).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
    }

    private func fp(_ i: UInt8) -> String {
        String(repeating: String(format: "%02x", i), count: 32)
    }

    private func lp(_ b: Data?) -> Data {
        let d = b ?? Data()
        var out = Data()
        out.append(UInt8((d.count >> 8) & 0xFF))
        out.append(UInt8(d.count & 0xFF))
        out.append(d)
        return out
    }

    private func u32be(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private func domainV4Bytes() -> Data { Data("qaudion-handshake-sig-v4".utf8) }

    private func expectedAdvEnc(_ fps: [String], _ roles: [Int]) -> Data {
        var out = Data()
        out.append(UInt8(fps.count))
        for (i, f) in fps.enumerated() {
            let role = i < roles.count ? roles[i] : 0
            out.append(UInt8(truncatingIfNeeded: role))
            out.append(hexToRaw32(f))
        }
        return out
    }

    private func hexToRaw32(_ hex: String) -> Data {
        guard hex.count == 64 else { return Data(count: 32) }
        var out = Data(capacity: 32)
        var idx = hex.startIndex
        for _ in 0..<32 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return Data(count: 32) }
            out.append(b)
            idx = next
        }
        return out
    }

    private let eightByteNonce = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])

    private func offerV4Fixture(
        rekeyNonce: Data,
        rekeyRound: UInt32,
        ratchetV5: Bool = true,
        pskFingerprints: [String]? = nil,
        pskRoles: [Int]? = nil
    ) -> Data? {
        HandshakeTranscript.offerV4(
            callId: "call-fixture",
            signerIdentityKey: fixedBytes(32, seed: 0x10),
            epochId: fixedBytes(16, seed: 0x20),
            pqcPublicKey: fixedBytes(24, seed: 0x30),
            x25519PublicKey: fixedBytes(32, seed: 0x40),
            strongBoxPublicKey: nil,
            dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: false,
            ratchetV4: true, srtpDirKeyV1: false, pskMixV1: true, hsTranscriptBindV1: true,
            ratchetV5: ratchetV5,
            ratchetV: 0x04, suiteId: 0x01,
            pskFingerprints: pskFingerprints, pskRoles: pskRoles,
            rekeyNonce: rekeyNonce, rekeyRound: rekeyRound
        )
    }

    // MARK: - domainV4

    func testDomainV4SameLengthAsDomainV1V2V3DifferentBytes() {
        let v1 = HandshakeTranscript.offer(
            callId: "c", signerIdentityKey: fixedBytes(32, seed: 1), epochId: fixedBytes(16, seed: 2),
            pqcPublicKey: fixedBytes(8, seed: 3), x25519PublicKey: fixedBytes(32, seed: 4),
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true, ratchetV4: true, srtpDirKeyV1: true,
            ratchetV: 0x04, suiteId: 0x01, pskFingerprints: nil
        )
        let v3 = HandshakeTranscript.offerV3(
            callId: "c", signerIdentityKey: fixedBytes(32, seed: 1), epochId: fixedBytes(16, seed: 2),
            pqcPublicKey: fixedBytes(8, seed: 3), x25519PublicKey: fixedBytes(32, seed: 4),
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true, ratchetV4: true, srtpDirKeyV1: true,
            pskMixV1: false, hsTranscriptBindV1: true,
            ratchetV: 0x04, suiteId: 0x01, pskFingerprints: nil, pskRoles: nil,
            rekeyNonce: eightByteNonce, rekeyRound: 1
        )
        guard let v4 = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1) else {
            XCTFail("offerV4 returned nil"); return
        }
        XCTAssertEqual(v1.prefix(24).count, 24)
        XCTAssertEqual(v3?.prefix(24).count, 24)
        XCTAssertEqual(v4.prefix(24).count, 24)
        XCTAssertNotEqual(v1.prefix(24), v4.prefix(24), "domainV4 must differ from domain (v1)")
        XCTAssertNotEqual(v3?.prefix(24), v4.prefix(24), "domainV4 must differ from domainV3")
        XCTAssertEqual(String(data: v4.prefix(22), encoding: .utf8), "qaudion-handshake-sig-")
        XCTAssertEqual(String(data: v4.subdata(in: 22..<24), encoding: .utf8), "v4")
    }

    // MARK: - caps9 widens caps8 by exactly one signed byte

    func testCaps9AddsExactlyOneSignedByte_ratchetV5_v1v2v3StayCompletelyBlind() {
        let withV5 = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, ratchetV5: true)
        let withoutV5 = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, ratchetV5: false)
        guard let a = withV5, let b = withoutV5 else {
            XCTFail("offerV4 returned nil"); return
        }
        XCTAssertEqual(a.count, b.count)
        var diffCount = 0
        for i in 0..<a.count where a[i] != b[i] { diffCount += 1 }
        XCTAssertEqual(diffCount, 1, "flipping ratchetV5 must change EXACTLY one byte of the v4 transcript")

        // v1/v2/v3 never read caps.ratchetV5 at all — confirmed by construction (their
        // functions take no ratchetV5 parameter), so no runtime check is needed here beyond
        // the byte-layout proof above.
    }

    // MARK: - Byte-layout: OFFER v4

    func testOfferV4ByteLayoutMatchesFirstPrinciplesReconstruction() {
        let callId = "call-42"
        let sik = fixedBytes(32, seed: 0x10)
        let epoch = fixedBytes(16, seed: 0x20)
        let pqc = fixedBytes(24, seed: 0x30)
        let x25 = fixedBytes(32, seed: 0x40)
        let fps = [fp(0xAA), fp(0xBB)]
        let roles = [0, 1]

        guard let actual = HandshakeTranscript.offerV4(
            callId: callId, signerIdentityKey: sik, epochId: epoch,
            pqcPublicKey: pqc, x25519PublicKey: x25,
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: false, vkeyV1: true, sessionKdfV3: false, ratchetV4: true, srtpDirKeyV1: false,
            pskMixV1: true, hsTranscriptBindV1: true, ratchetV5: true,
            ratchetV: 0x04, suiteId: 0x01,
            pskFingerprints: fps, pskRoles: roles,
            rekeyNonce: eightByteNonce, rekeyRound: 1
        ) else {
            XCTFail("offerV4 returned nil"); return
        }

        var expected = Data()
        expected.append(domainV4Bytes())
        expected.append(0x01)  // ROLE_OFFER
        expected.append(lp(Data(callId.utf8)))
        expected.append(lp(sik))
        expected.append(lp(epoch))
        expected.append(lp(pqc))
        expected.append(lp(x25))
        expected.append(lp(nil))
        expected.append(lp(nil))
        // caps9: ratchetV3,sframeV1,vkeyV1,sessionKdfV3,ratchetV4,srtpDirKeyV1,pskMixV1,hsTranscriptBindV1,ratchetV5
        expected.append(contentsOf: [UInt8(1), 0, 1, 0, 1, 0, 1, 1, 1])
        expected.append(0x04)
        expected.append(0x01)
        expected.append(lp(expectedAdvEnc(fps, roles)))
        expected.append(eightByteNonce)
        expected.append(u32be(1))

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, expected.count)
    }

    // MARK: - Byte-layout: ACCEPT v4 — offerBinding is ALWAYS empty (scope note)

    func testAcceptV4ByteLayoutMatchesFirstPrinciplesReconstruction_offerBindingAlwaysEmpty() {
        let callId = "call-99"
        let sik = fixedBytes(32, seed: 0x50)
        let epoch = fixedBytes(16, seed: 0x60)
        let ctPqc = fixedBytes(24, seed: 0x70)
        let ctX25 = fixedBytes(32, seed: 0x80)
        let responderFps = [fp(0x01)]
        let responderRoles = [0]

        // Callers always pass Data() here (see acceptTranscriptV4's own doc) — but the
        // builder itself does not special-case it; this test proves the field IS still
        // wired into the layout (a non-empty binding would change the transcript), while
        // QAudionCallIntegration's actual call sites always supply Data().
        guard let actual = HandshakeTranscript.acceptV4(
            callId: callId, signerIdentityKey: sik, epochId: epoch,
            ctPqc: ctPqc, ctX25519: ctX25,
            ctStrongBox: nil, ctDualCurve: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: false, sessionKdfV3: true, ratchetV4: false, srtpDirKeyV1: true,
            pskMixV1: false, hsTranscriptBindV1: true, ratchetV5: true,
            ratchetV: 0x04, suiteId: 0x01,
            selectedPskFingerprint: "abc",
            offerBinding: Data(),
            responderPskFingerprints: responderFps, responderPskRoles: responderRoles,
            rekeyNonce: eightByteNonce,
            rekeyRound: 3
        ) else {
            XCTFail("acceptV4 returned nil"); return
        }

        var expected = Data()
        expected.append(domainV4Bytes())
        expected.append(0x02)  // ROLE_ACCEPT
        expected.append(lp(Data(callId.utf8)))
        expected.append(lp(sik))
        expected.append(lp(epoch))
        expected.append(lp(ctPqc))
        expected.append(lp(ctX25))
        expected.append(lp(nil))
        expected.append(lp(nil))
        expected.append(contentsOf: [UInt8(1), 1, 0, 1, 0, 1, 0, 1, 1])
        expected.append(0x04)
        expected.append(0x01)
        expected.append(lp(Data("abc".utf8)))
        expected.append(lp(Data()))  // offerBinding — ALWAYS empty for v4
        expected.append(lp(expectedAdvEnc(responderFps, responderRoles)))
        expected.append(eightByteNonce)
        expected.append(u32be(3))

        XCTAssertEqual(actual, expected)
    }

    func testAcceptV4NonEmptyOfferBindingStillChangesTranscript() {
        func fixture(binding: Data) -> Data? {
            HandshakeTranscript.acceptV4(
                callId: "call-99", signerIdentityKey: fixedBytes(32, seed: 0x50), epochId: fixedBytes(16, seed: 0x60),
                ctPqc: fixedBytes(24, seed: 0x70), ctX25519: fixedBytes(32, seed: 0x80),
                ctStrongBox: nil, ctDualCurve: nil,
                ratchetV3: true, sframeV1: true, vkeyV1: false, sessionKdfV3: true, ratchetV4: false, srtpDirKeyV1: true,
                pskMixV1: false, hsTranscriptBindV1: true, ratchetV5: true,
                ratchetV: 0x04, suiteId: 0x01,
                selectedPskFingerprint: "abc",
                offerBinding: binding,
                responderPskFingerprints: nil, responderPskRoles: nil,
                rekeyNonce: eightByteNonce, rekeyRound: 3
            )
        }
        let empty = fixture(binding: Data())
        let nonEmpty = fixture(binding: fixedBytes(32, seed: 0x90))
        XCTAssertNotEqual(empty, nonEmpty, "the offerBinding field is still genuinely wired into the layout — real callers just always pass Data()")
    }

    // MARK: - ratchetV5 is signed (closes the "strip the capability bit" gap for THIS bit itself)

    func testOfferV4RatchetV5FlipChangesTranscript() {
        let a = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, ratchetV5: false)
        let b = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, ratchetV5: true)
        XCTAssertNotEqual(a, b, "the 9th CAPS byte (ratchetV5) must itself be signed into the v4 transcript")
    }

    // MARK: - v4 reuses v3's freshness fields verbatim (round/nonce still change the transcript)

    func testOfferV4DifferentRoundsProduceDifferentTranscripts() {
        let r1 = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1)
        let r2 = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 2)
        XCTAssertNotEqual(r1, r2)
    }

    func testOfferV4DifferentNoncesProduceDifferentTranscripts() {
        let a = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1)
        let b = offerV4Fixture(rekeyNonce: Data([0, 0, 0, 0, 0, 0, 0, 1]), rekeyRound: 1)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Precondition safety / never-throw on malformed peer PSK input

    func testOfferV4AcceptsExactly8ByteNonce() {
        XCTAssertNotNil(offerV4Fixture(rekeyNonce: Data(count: 8), rekeyRound: 1))
    }

    func testOfferV4ReturnsNilForOversizedPskList() {
        let many = (0..<256).map { _ in fp(0x11) }
        let result = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, pskFingerprints: many)
        XCTAssertNil(result, "a >255-entry advertised list must fail gracefully (nil), never trap the process")
    }

    // MARK: - Sign/verify round trip

    func testOfferV4SignVerifyRoundTrip() throws {
        let priv = Curve25519.Signing.PrivateKey()
        guard let transcript = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1) else {
            XCTFail("offerV4 returned nil"); return
        }
        let sig = try HandshakeTranscript.sign(transcript: transcript, signingPrivateKeyRaw: priv.rawRepresentation)
        XCTAssertTrue(HandshakeTranscript.verify(transcript: transcript, signature: sig, signerIdentityKey: priv.publicKey.rawRepresentation))
    }

    func testOfferV4SignatureInvalidatedByRatchetV5Tampering() throws {
        let priv = Curve25519.Signing.PrivateKey()
        guard let claimsTrue = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, ratchetV5: true),
              let claimsFalse = offerV4Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, ratchetV5: false) else {
            XCTFail("offerV4 returned nil"); return
        }
        let sig = try HandshakeTranscript.sign(transcript: claimsTrue, signingPrivateKeyRaw: priv.rawRepresentation)
        // A signature over the ratchetV5=true transcript must NOT verify against the
        // ratchetV5=false transcript — this is the actual anti-strip mechanism MUST-FIX #1
        // relies on: a relay flipping the JSON bit invalidates the v4 signature outright.
        XCTAssertFalse(HandshakeTranscript.verify(transcript: claimsFalse, signature: sig, signerIdentityKey: priv.publicKey.rawRepresentation))
    }

    // MARK: - Cross-platform KAT

    /// Fixed inputs, cross-checked against Desktop's own REAL, unit-tested
    /// `buildOfferTranscriptV4`/`buildAcceptTranscriptV4` (`HandshakeTranscript.ts`,
    /// `qaudion-desktop`, commit `22aa0d6`) — these exact hex values were produced by
    /// running the identical fixture through Desktop's live TypeScript implementation
    /// via `vitest` (not hand-derived), so this is a genuine independent-runtime
    /// cross-check, not merely a source-level read-through. THIS platform's `offerV4`/
    /// `acceptV4` (this file's own `HandshakeTranscript.swift`) was then read
    /// line-by-line against the same construction: same domain/role bytes, same
    /// `appendLP`/`capByte`/`appendU32BE`/`advEnc` encoders, same field order, same
    /// 9-byte CAPS layout, same "offerBinding always empty" ACCEPT shape. No divergence
    /// found. UNVERIFIED against a live Swift/CryptoKit run (no macOS/Xcode toolchain
    /// available this session) — if this test is ever run on real hardware/CI and
    /// fails, that is real signal a divergence exists despite the source-level match;
    /// do not assume the fixture is stale without re-diffing against Desktop's real run
    /// first.
    func testCrossPlatformKatFixture() throws {
        let callId = "kat-transcript-v3"
        let rekeyNonce = Data(repeating: 0x05, count: 8)
        guard let offerBytes = HandshakeTranscript.offerV4(
            callId: callId,
            signerIdentityKey: Data(repeating: 0x01, count: 32),
            epochId: Data(repeating: 0x02, count: 16),
            pqcPublicKey: Data(repeating: 0x03, count: 8),
            x25519PublicKey: Data(repeating: 0x04, count: 8),
            strongBoxPublicKey: nil,
            dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true,
            ratchetV4: false, srtpDirKeyV1: true, pskMixV1: true, hsTranscriptBindV1: true, ratchetV5: true,
            ratchetV: 3, suiteId: 1,
            pskFingerprints: nil, pskRoles: nil,
            rekeyNonce: rekeyNonce, rekeyRound: 1
        ) else {
            XCTFail("offerV4 returned nil"); return
        }
        XCTAssertEqual(offerBytes.count, 146)
        XCTAssertEqual(
            offerBytes.map { String(format: "%02x", $0) }.joined(),
            "71617564696f6e2d68616e647368616b652d7369672d76340100116b61742d7472616e7363726970742d7633002001010101010101010101010101010101010101010101010101010101010101010010020202020202020202020202020202020008030303030303030300080404040404040404000000000101010100010101010301000100050505050505050500000001"
        )

        let offerBinding = Data(SHA256.hash(data: offerBytes))
        XCTAssertEqual(
            offerBinding.map { String(format: "%02x", $0) }.joined(),
            "a787a6f6cae46bb95a9c271bebc0fd5090877a0fff3d6b197e0948beab57d40a"
        )

        guard let acceptBytes = HandshakeTranscript.acceptV4(
            callId: callId,
            signerIdentityKey: Data(repeating: 0x06, count: 32),
            epochId: Data(repeating: 0x07, count: 16),
            ctPqc: Data(repeating: 0x08, count: 8),
            ctX25519: Data(repeating: 0x09, count: 8),
            ctStrongBox: nil,
            ctDualCurve: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true,
            ratchetV4: false, srtpDirKeyV1: true, pskMixV1: true, hsTranscriptBindV1: true, ratchetV5: true,
            ratchetV: 3, suiteId: 1,
            selectedPskFingerprint: nil,
            offerBinding: Data(),
            responderPskFingerprints: nil, responderPskRoles: nil,
            rekeyNonce: rekeyNonce, rekeyRound: 1
        ) else {
            XCTFail("acceptV4 returned nil"); return
        }
        XCTAssertEqual(acceptBytes.count, 150)

        let transcriptHash = Data(SHA256.hash(data: acceptBytes))
        XCTAssertEqual(
            transcriptHash.map { String(format: "%02x", $0) }.joined(),
            "aa9e8400637c853717e8f5b0037c01318fcfeab87a7cca068bbbd6dcfcb3c4d4"
        )
    }
}

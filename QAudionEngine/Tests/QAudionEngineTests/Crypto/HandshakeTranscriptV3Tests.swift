import XCTest
import CryptoKit
@testable import QAudionEngine

/// CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit) — independent,
/// first-principles reconstruction tests for the v3 transcript additions
/// (`domainV3`, the 8th CAPS byte `transcriptBindV1`, `rekeyNonce`/`rekeyRound`,
/// `offerV3`, `acceptV3`).
///
/// This file does NOT touch, re-derive, or re-run `offer`/`accept` (v1) or
/// `offerV2`/`acceptV2` — those functions are byte-for-byte UNCHANGED by this
/// addition (v3 is a third, purely additive transcript domain, mirroring how
/// `domainV2` did not touch `domain`). `HandshakeTranscriptKatTests.swift` and
/// `HandshakeTranscriptV2Tests.swift` remain the proof those stayed
/// byte-identical: this fix never edited either function body.
final class HandshakeTranscriptV3Tests: XCTestCase {

    // MARK: - Fixtures (mirrors HandshakeTranscriptV2Tests' own helpers)

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

    private func domainV3Bytes() -> Data { Data("qaudion-handshake-sig-v3".utf8) }

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

    private func offerV3Fixture(
        rekeyNonce: Data?,
        rekeyRound: UInt32,
        transcriptBindV1: Bool = true,
        pskFingerprints: [String]? = nil,
        pskRoles: [Int]? = nil
    ) -> Data? {
        HandshakeTranscript.offerV3(
            callId: "call-fixture",
            signerIdentityKey: fixedBytes(32, seed: 0x10),
            epochId: fixedBytes(16, seed: 0x20),
            pqcPublicKey: fixedBytes(24, seed: 0x30),
            x25519PublicKey: fixedBytes(32, seed: 0x40),
            strongBoxPublicKey: nil,
            dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: false,
            ratchetV4: true, srtpDirKeyV1: false, pskMixV1: true,
            transcriptBindV1: transcriptBindV1,
            ratchetV: 0x04, suiteId: 0x01,
            pskFingerprints: pskFingerprints, pskRoles: pskRoles,
            rekeyNonce: rekeyNonce, rekeyRound: rekeyRound
        )
    }

    // MARK: - domainV3

    func testDomainV3SameLengthAsDomainV1V2DifferentBytes() {
        let v1 = HandshakeTranscript.offer(
            callId: "c", signerIdentityKey: fixedBytes(32, seed: 1), epochId: fixedBytes(16, seed: 2),
            pqcPublicKey: fixedBytes(8, seed: 3), x25519PublicKey: fixedBytes(32, seed: 4),
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true, ratchetV4: true, srtpDirKeyV1: true,
            ratchetV: 0x04, suiteId: 0x01, pskFingerprints: nil
        )
        let v2 = HandshakeTranscript.offerV2(
            callId: "c", signerIdentityKey: fixedBytes(32, seed: 1), epochId: fixedBytes(16, seed: 2),
            pqcPublicKey: fixedBytes(8, seed: 3), x25519PublicKey: fixedBytes(32, seed: 4),
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true, ratchetV4: true, srtpDirKeyV1: true,
            pskMixV1: false,
            ratchetV: 0x04, suiteId: 0x01, pskFingerprints: nil, pskRoles: nil
        )
        guard let v3 = offerV3Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1) else {
            XCTFail("offerV3 returned nil"); return
        }
        XCTAssertEqual(v1.prefix(24).count, 24)
        XCTAssertEqual(v2?.prefix(24).count, 24)
        XCTAssertEqual(v3.prefix(24).count, 24)
        XCTAssertNotEqual(v1.prefix(24), v3.prefix(24), "domainV3 must differ from domain (v1)")
        XCTAssertNotEqual(v2?.prefix(24), v3.prefix(24), "domainV3 must differ from domainV2")
        XCTAssertEqual(String(data: v3.prefix(22), encoding: .utf8), "qaudion-handshake-sig-")
        XCTAssertEqual(String(data: v3.subdata(in: 22..<24), encoding: .utf8), "v3")
    }

    // MARK: - Byte-layout: OFFER v3

    func testOfferV3ByteLayoutMatchesFirstPrinciplesReconstruction_round1WithNonce() {
        let callId = "call-42"
        let sik = fixedBytes(32, seed: 0x10)
        let epoch = fixedBytes(16, seed: 0x20)
        let pqc = fixedBytes(24, seed: 0x30)
        let x25 = fixedBytes(32, seed: 0x40)
        let fps = [fp(0xAA), fp(0xBB)]
        let roles = [0, 1]

        guard let actual = HandshakeTranscript.offerV3(
            callId: callId, signerIdentityKey: sik, epochId: epoch,
            pqcPublicKey: pqc, x25519PublicKey: x25,
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: false, vkeyV1: true, sessionKdfV3: false, ratchetV4: true, srtpDirKeyV1: false,
            pskMixV1: true, transcriptBindV1: true,
            ratchetV: 0x04, suiteId: 0x01,
            pskFingerprints: fps, pskRoles: roles,
            rekeyNonce: eightByteNonce, rekeyRound: 1
        ) else {
            XCTFail("offerV3 returned nil"); return
        }

        var expected = Data()
        expected.append(domainV3Bytes())
        expected.append(0x01)  // ROLE_OFFER
        expected.append(lp(Data(callId.utf8)))
        expected.append(lp(sik))
        expected.append(lp(epoch))
        expected.append(lp(pqc))
        expected.append(lp(x25))
        expected.append(lp(nil))
        expected.append(lp(nil))
        // caps8: ratchetV3,sframeV1,vkeyV1,sessionKdfV3,ratchetV4,srtpDirKeyV1,pskMixV1,transcriptBindV1
        expected.append(contentsOf: [UInt8(1), 0, 1, 0, 1, 0, 1, 1])
        expected.append(0x04)
        expected.append(0x01)
        expected.append(lp(expectedAdvEnc(fps, roles)))
        expected.append(lp(eightByteNonce))
        expected.append(u32be(1))

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, expected.count)
    }

    func testOfferV3Round2OmitsNonceOnTheWire() {
        guard let round1 = offerV3Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1),
              let round2 = offerV3Fixture(rekeyNonce: nil, rekeyRound: 2) else {
            XCTFail("offerV3 returned nil"); return
        }
        // round2's transcript must NOT contain the nonce bytes anywhere its LP
        // slot would put them, and must be a DIFFERENT overall byte string.
        XCTAssertNotEqual(round1, round2)
        // The nonce LP field encodes as 0x00 0x08 <8 bytes> when present, and
        // 0x00 0x00 (LP of empty) when absent — the two transcripts must differ
        // in length by exactly 8 bytes (the omitted nonce payload) once the
        // round number's own encoding (same width, u32 BE, both cases) is
        // accounted for.
        XCTAssertEqual(round1.count, round2.count + 8)
    }

    // MARK: - Byte-layout: ACCEPT v3

    func testAcceptV3ByteLayoutMatchesFirstPrinciplesReconstruction() {
        let callId = "call-99"
        let sik = fixedBytes(32, seed: 0x50)
        let epoch = fixedBytes(16, seed: 0x60)
        let ctPqc = fixedBytes(24, seed: 0x70)
        let ctX25 = fixedBytes(32, seed: 0x80)
        let offerBindingV3 = fixedBytes(32, seed: 0x90)
        let responderFps = [fp(0x01)]
        let responderRoles = [0]

        guard let actual = HandshakeTranscript.acceptV3(
            callId: callId, signerIdentityKey: sik, epochId: epoch,
            ctPqc: ctPqc, ctX25519: ctX25,
            ctStrongBox: nil, ctDualCurve: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: false, sessionKdfV3: true, ratchetV4: false, srtpDirKeyV1: true,
            pskMixV1: false, transcriptBindV1: true,
            ratchetV: 0x04, suiteId: 0x01,
            selectedPskFingerprint: "abc",
            offerBinding: offerBindingV3,
            responderPskFingerprints: responderFps, responderPskRoles: responderRoles,
            rekeyRound: 3
        ) else {
            XCTFail("acceptV3 returned nil"); return
        }

        var expected = Data()
        expected.append(domainV3Bytes())
        expected.append(0x02)  // ROLE_ACCEPT
        expected.append(lp(Data(callId.utf8)))
        expected.append(lp(sik))
        expected.append(lp(epoch))
        expected.append(lp(ctPqc))
        expected.append(lp(ctX25))
        expected.append(lp(nil))
        expected.append(lp(nil))
        expected.append(contentsOf: [UInt8(1), 1, 0, 1, 0, 1, 0, 1])
        expected.append(0x04)
        expected.append(0x01)
        expected.append(lp(Data("abc".utf8)))
        expected.append(lp(offerBindingV3))
        expected.append(lp(expectedAdvEnc(responderFps, responderRoles)))
        expected.append(u32be(3))

        XCTAssertEqual(actual, expected)
    }

    // MARK: - transcriptBindV1 is signed (closes the "strip a capability bit" gap for THIS bit itself)

    func testOfferV3TranscriptBindV1FlipChangesTranscript() {
        let a = offerV3Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, transcriptBindV1: false)
        let b = offerV3Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1, transcriptBindV1: true)
        XCTAssertNotEqual(a, b, "the 8th CAPS byte (transcriptBindV1) must itself be signed into the v3 transcript")
    }

    // MARK: - CALL-3: round number changes the transcript (closes the "identical epoch every round" gap)

    func testOfferV3DifferentRoundsProduceDifferentTranscripts() {
        let r1 = offerV3Fixture(rekeyNonce: nil, rekeyRound: 1)
        let r2 = offerV3Fixture(rekeyNonce: nil, rekeyRound: 2)
        let r3 = offerV3Fixture(rekeyNonce: nil, rekeyRound: 3)
        XCTAssertNotEqual(r1, r2)
        XCTAssertNotEqual(r2, r3)
        XCTAssertNotEqual(r1, r3)
    }

    func testOfferV3DifferentNoncesProduceDifferentRound1Transcripts() {
        let a = offerV3Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1)
        let b = offerV3Fixture(rekeyNonce: Data([0, 0, 0, 0, 0, 0, 0, 1]), rekeyRound: 1)
        XCTAssertNotEqual(a, b, "a different rekeyNonce must change round 1's signed transcript")
    }

    // MARK: - Precondition safety: caller-only responsibility, not adversarial input

    func testOfferV3AcceptsExactly8ByteNonce() {
        XCTAssertNotNil(offerV3Fixture(rekeyNonce: Data(count: 8), rekeyRound: 1))
    }

    // MARK: - Never-throw on malformed peer PSK input (same discipline as v2's advEnc)

    func testOfferV3ReturnsNilForOversizedPskList() {
        let many = (0..<256).map { _ in fp(0x11) }
        let result = offerV3Fixture(rekeyNonce: nil, rekeyRound: 1, pskFingerprints: many)
        XCTAssertNil(result, "a >255-entry advertised list must fail gracefully (nil), never trap the process")
    }

    // MARK: - Sign/verify round trip (the v3 signature itself, independent of QAudionCallIntegration wiring)

    func testOfferV3SignVerifyRoundTrip() throws {
        let priv = Curve25519.Signing.PrivateKey()
        guard let transcript = offerV3Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1) else {
            XCTFail("offerV3 returned nil"); return
        }
        let sig = try HandshakeTranscript.sign(transcript: transcript, signingPrivateKeyRaw: priv.rawRepresentation)
        XCTAssertTrue(HandshakeTranscript.verify(transcript: transcript, signature: sig, signerIdentityKey: priv.publicKey.rawRepresentation))
    }

    func testOfferV3SignatureInvalidatedByRoundTampering() throws {
        let priv = Curve25519.Signing.PrivateKey()
        guard let round1 = offerV3Fixture(rekeyNonce: eightByteNonce, rekeyRound: 1),
              let round2 = offerV3Fixture(rekeyNonce: nil, rekeyRound: 2) else {
            XCTFail("offerV3 returned nil"); return
        }
        let sig = try HandshakeTranscript.sign(transcript: round1, signingPrivateKeyRaw: priv.rawRepresentation)
        // A signature over round 1's transcript must NOT verify against round
        // 2's transcript — this is the mechanism CALL-3 relies on: a stale
        // round's bundle cannot be relabelled as a later round without
        // invalidating its own signature.
        XCTAssertFalse(HandshakeTranscript.verify(transcript: round2, signature: sig, signerIdentityKey: priv.publicKey.rawRepresentation))
    }
}

import XCTest
import CryptoKit
@testable import QAudionEngine

/// W-TRANSCRIPTV2 (multi-PSK-mixing SYNTHESIS.md ship step 4) — independent,
/// first-principles reconstruction tests for the v2 transcript additions
/// (`domainV2`, the 7th CAPS byte, `advEnc`, `offerV2`, `acceptV2`) and the
/// dual-signature verify-both/prefer-v2 decision
/// (`HandshakeSigningPolicy.evaluate`'s `sigV2B64`/`transcriptV2` params).
///
/// Mirrors Android's `HandshakeTranscriptV2Test.kt` (commit d3244418) and
/// Desktop's `handshakeTranscriptV2.spec.ts` (commit c6bf155) — same ship
/// step, same byte layout, same dual-signature semantics. This file does NOT
/// touch/re-derive the v1 golden-bytes KAT
/// (`HandshakeTranscriptKatTests.swift`), which remains the proof that v1
/// stayed byte-identical after this addition.
final class HandshakeTranscriptV2Tests: XCTestCase {

    // MARK: - Fixtures

    private func fixedBytes(_ n: Int, seed: UInt8) -> Data {
        Data((0..<n).map { UInt8((Int($0) + Int(seed)) & 0xFF) })
    }

    /// A well-formed 64-char lowercase-hex fingerprint, deterministic per index
    /// (all 32 bytes equal to `i`).
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

    private func domainV2Bytes() -> Data { Data("qaudion-handshake-sig-v2".utf8) }

    /// First-principles `advEnc` reconstruction: `u8(m) || CONCAT(u8(role) || fp32)`.
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

    /// Well-formed-hex-only decoder (test-side twin of `HandshakeTranscript.hexFpToRaw32`,
    /// re-derived independently rather than reaching into the private implementation).
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

    /// Common OFFER-v2 fixture with fixed, deterministic non-PSK fields — only
    /// `pskFingerprints`/`pskRoles`/`pskMixV1` vary per test.
    private func offerV2Fixture(
        pskFingerprints: [String]?,
        pskRoles: [Int]? = nil,
        pskMixV1: Bool = false
    ) -> Data? {
        HandshakeTranscript.offerV2(
            callId: "call-fixture",
            signerIdentityKey: fixedBytes(32, seed: 0x10),
            epochId: fixedBytes(16, seed: 0x20),
            pqcPublicKey: fixedBytes(24, seed: 0x30),
            x25519PublicKey: fixedBytes(32, seed: 0x40),
            strongBoxPublicKey: nil,
            dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: false, ratchetV4: true, srtpDirKeyV1: false,
            pskMixV1: pskMixV1,
            ratchetV: 0x04, suiteId: 0x01,
            pskFingerprints: pskFingerprints,
            pskRoles: pskRoles
        )
    }

    // MARK: - domainV2

    func testDomainV2SameLengthAsDomainV1DifferentBytes() {
        let v1 = HandshakeTranscript.offer(
            callId: "c", signerIdentityKey: fixedBytes(32, seed: 1), epochId: fixedBytes(16, seed: 2),
            pqcPublicKey: fixedBytes(8, seed: 3), x25519PublicKey: fixedBytes(32, seed: 4),
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true, ratchetV4: true, srtpDirKeyV1: true,
            ratchetV: 0x04, suiteId: 0x01, pskFingerprints: nil
        )
        guard let v2 = HandshakeTranscript.offerV2(
            callId: "c", signerIdentityKey: fixedBytes(32, seed: 1), epochId: fixedBytes(16, seed: 2),
            pqcPublicKey: fixedBytes(8, seed: 3), x25519PublicKey: fixedBytes(32, seed: 4),
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: true, sessionKdfV3: true, ratchetV4: true, srtpDirKeyV1: true,
            pskMixV1: false,
            ratchetV: 0x04, suiteId: 0x01, pskFingerprints: nil, pskRoles: nil
        ) else {
            XCTFail("offerV2 returned nil"); return
        }
        XCTAssertEqual(v1.prefix(24).count, v2.prefix(24).count, "domain prefix must be the same length")
        XCTAssertNotEqual(v1.prefix(24), v2.prefix(24), "domainV2 must differ from domain (trailing v1->v2)")
        XCTAssertEqual(String(data: v1.prefix(22), encoding: .utf8), "qaudion-handshake-sig-")
        XCTAssertEqual(String(data: v2.prefix(22), encoding: .utf8), "qaudion-handshake-sig-")
        XCTAssertEqual(String(data: v1.subdata(in: 22..<24), encoding: .utf8), "v1")
        XCTAssertEqual(String(data: v2.subdata(in: 22..<24), encoding: .utf8), "v2")
    }

    // MARK: - Byte-layout: OFFER v2

    func testOfferV2ByteLayoutMatchesFirstPrinciplesReconstruction() {
        let callId = "call-42"
        let sik = fixedBytes(32, seed: 0x10)
        let epoch = fixedBytes(16, seed: 0x20)
        let pqc = fixedBytes(24, seed: 0x30)
        let x25 = fixedBytes(32, seed: 0x40)
        let fps = [fp(0xAA), fp(0xBB), fp(0xCC)]
        let roles = [0, 1, 0]

        guard let actual = HandshakeTranscript.offerV2(
            callId: callId, signerIdentityKey: sik, epochId: epoch,
            pqcPublicKey: pqc, x25519PublicKey: x25,
            strongBoxPublicKey: nil, dualCurvePublicKey: nil,
            ratchetV3: true, sframeV1: false, vkeyV1: true, sessionKdfV3: false, ratchetV4: true, srtpDirKeyV1: false,
            pskMixV1: true,
            ratchetV: 0x04, suiteId: 0x01,
            pskFingerprints: fps, pskRoles: roles
        ) else {
            XCTFail("offerV2 returned nil"); return
        }

        var expected = Data()
        expected.append(domainV2Bytes())
        expected.append(0x01)  // ROLE_OFFER
        expected.append(lp(Data(callId.utf8)))
        expected.append(lp(sik))
        expected.append(lp(epoch))
        expected.append(lp(pqc))
        expected.append(lp(x25))
        expected.append(lp(nil))
        expected.append(lp(nil))
        expected.append(contentsOf: [UInt8(1), 0, 1, 0, 1, 0, 1])  // caps7: ratchetV3,sframeV1,vkeyV1,sessionKdfV3,ratchetV4,srtpDirKeyV1,pskMixV1
        expected.append(0x04)
        expected.append(0x01)
        expected.append(lp(expectedAdvEnc(fps, roles)))

        XCTAssertEqual(actual, expected)
    }

    // MARK: - Byte-layout: ACCEPT v2

    func testAcceptV2ByteLayoutMatchesFirstPrinciplesReconstruction() {
        let callId = "call-99"
        let sik = fixedBytes(32, seed: 0x50)
        let epoch = fixedBytes(16, seed: 0x60)
        let ctPqc = fixedBytes(24, seed: 0x70)
        let ctX25 = fixedBytes(32, seed: 0x80)
        let offerBindingV2 = fixedBytes(32, seed: 0x90)
        let responderFps = [fp(0x01), fp(0x02)]
        let responderRoles = [0, 0]

        guard let actual = HandshakeTranscript.acceptV2(
            callId: callId, signerIdentityKey: sik, epochId: epoch,
            ctPqc: ctPqc, ctX25519: ctX25,
            ctStrongBox: nil, ctDualCurve: nil,
            ratchetV3: true, sframeV1: true, vkeyV1: false, sessionKdfV3: true, ratchetV4: false, srtpDirKeyV1: true,
            pskMixV1: false,
            ratchetV: 0x04, suiteId: 0x01,
            selectedPskFingerprint: "abc",
            offerBinding: offerBindingV2,
            responderPskFingerprints: responderFps, responderPskRoles: responderRoles
        ) else {
            XCTFail("acceptV2 returned nil"); return
        }

        var expected = Data()
        expected.append(domainV2Bytes())
        expected.append(0x02)  // ROLE_ACCEPT
        expected.append(lp(Data(callId.utf8)))
        expected.append(lp(sik))
        expected.append(lp(epoch))
        expected.append(lp(ctPqc))
        expected.append(lp(ctX25))
        expected.append(lp(nil))
        expected.append(lp(nil))
        expected.append(contentsOf: [UInt8(1), 1, 0, 1, 0, 1, 0])
        expected.append(0x04)
        expected.append(0x01)
        expected.append(lp(Data("abc".utf8)))
        expected.append(lp(offerBindingV2))
        expected.append(lp(expectedAdvEnc(responderFps, responderRoles)))

        XCTAssertEqual(actual, expected)
    }

    // MARK: - Order-binding (closes the permute defect pskJoin left open)

    func testOfferV2BindsAdvertisedOrderNotSortedSet() {
        let a = offerV2Fixture(pskFingerprints: [fp(1), fp(2)])
        let b = offerV2Fixture(pskFingerprints: [fp(2), fp(1)])
        XCTAssertNotEqual(a, b, "advEnc must bind wire ORDER, not a sorted set — permuting must change the transcript")
    }

    func testOfferV2PskMixV1FlipChangesTranscript() {
        let a = offerV2Fixture(pskFingerprints: nil, pskMixV1: false)
        let b = offerV2Fixture(pskFingerprints: nil, pskMixV1: true)
        XCTAssertNotEqual(a, b, "the 7th CAPS byte (pskMixV1) must be signed into the v2 transcript")
    }

    // MARK: - Never-throw on malformed peer input

    func testMalformedFingerprintDecodesToZeroPlaceholderNeverThrows() {
        let malformed = offerV2Fixture(pskFingerprints: ["not-a-valid-hex-fingerprint"], pskRoles: [0])
        let allZero = offerV2Fixture(pskFingerprints: [String(repeating: "0", count: 64)], pskRoles: [0])
        XCTAssertNotNil(malformed, "a malformed peer fingerprint must never crash the transcript rebuild")
        XCTAssertEqual(
            malformed, allZero,
            "a malformed peer fingerprint must decode to the same deterministic 32-zero-byte placeholder as an explicit all-zero fingerprint"
        )
    }

    func testOfferV2ReturnsNilForOversizedPskList() {
        let many = (0..<256).map { _ in fp(0x11) }
        let result = offerV2Fixture(pskFingerprints: many)
        XCTAssertNil(result, "a >255-entry advertised list cannot be represented by the u8(m) count prefix — must fail gracefully (nil), never trap the process")
    }

    // MARK: - Dual-signature verify-both/prefer-v2 (HandshakeSigningPolicy)

    private func makeSigner() -> (priv: Curve25519.Signing.PrivateKey, pubRaw: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv, priv.publicKey.rawRepresentation)
    }

    func testEvaluateFallsBackToV1WhenSigV2Absent() throws {
        let (priv, pubRaw) = makeSigner()
        let transcript = fixedBytes(64, seed: 7)
        let sig = try priv.signature(for: transcript)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: transcript,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false
        )
        guard case .authenticated = verdict else {
            XCTFail("expected .authenticated via the v1 path when sigV2 is absent, got \(verdict)"); return
        }
    }

    func testEvaluatePrefersValidSigV2EvenWithGarbageV1Signature() throws {
        let (priv, pubRaw) = makeSigner()
        let transcriptV1 = fixedBytes(64, seed: 1)
        let transcriptV2 = fixedBytes(64, seed: 9)
        let sigV2 = try priv.signature(for: transcriptV2)
        let garbageV1Sig = Data(count: 64)  // all-zero — not a valid signature over transcriptV1
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: garbageV1Sig.base64EncodedString(),
            transcript: transcriptV1,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            sigV2B64: sigV2.base64EncodedString(),
            transcriptV2: transcriptV2
        )
        guard case .authenticated = verdict else {
            XCTFail("a valid sigV2 must authenticate even though the v1 signature is garbage — v1 must never be consulted once sigV2 is present, got \(verdict)")
            return
        }
    }

    func testEvaluateFailsClosedOnWrongSigV2EvenWithValidV1Signature() throws {
        let (priv, pubRaw) = makeSigner()
        let transcriptV1 = fixedBytes(64, seed: 1)
        let validV1Sig = try priv.signature(for: transcriptV1)
        let transcriptV2 = fixedBytes(64, seed: 9)
        let (otherPriv, _) = makeSigner()
        // Signed by a DIFFERENT key => wrong signature over transcriptV2 under `pubRaw`.
        let wrongSigV2 = try otherPriv.signature(for: transcriptV2)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: validV1Sig.base64EncodedString(),
            transcript: transcriptV1,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            sigV2B64: wrongSigV2.base64EncodedString(),
            transcriptV2: transcriptV2
        )
        guard case .abort(let code) = verdict, code == "sig_invalid" else {
            XCTFail("a present-but-wrong sigV2 must fail CLOSED (sig_invalid), never fall back to the valid v1 signature — got \(verdict)")
            return
        }
    }

    func testEvaluateFailsClosedWhenSigV2PresentButTranscriptV2Unavailable() throws {
        let (priv, pubRaw) = makeSigner()
        let transcriptV1 = fixedBytes(64, seed: 1)
        let validV1Sig = try priv.signature(for: transcriptV1)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: validV1Sig.base64EncodedString(),
            transcript: transcriptV1,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            sigV2B64: "c29tZS1zaWc=",  // present, non-empty
            transcriptV2: nil          // ...but the v2 transcript couldn't be rebuilt
        )
        guard case .abort(let code) = verdict, code == "sig_invalid" else {
            XCTFail("sigV2 present + transcriptV2 nil must abort(sig_invalid), never silently fall back to v1 — got \(verdict)")
            return
        }
    }

    func testEvaluateTreatsEmptySigV2StringAsAbsent() throws {
        let (priv, pubRaw) = makeSigner()
        let transcript = fixedBytes(64, seed: 3)
        let sig = try priv.signature(for: transcript)
        let verdict = HandshakeSigningPolicy.evaluate(
            signerIdentityKeyB64: pubRaw.base64EncodedString(),
            signatureB64: sig.base64EncodedString(),
            transcript: transcript,
            pinnedKey: nil, serverFetchedKey: nil,
            requireSigned: false, advertisedV4: false,
            sigV2B64: "",  // present key, but empty string
            transcriptV2: fixedBytes(64, seed: 99)
        )
        guard case .authenticated = verdict else {
            XCTFail("empty-string sigV2 must be treated as absent (falls back to v1), got \(verdict)")
            return
        }
    }
}

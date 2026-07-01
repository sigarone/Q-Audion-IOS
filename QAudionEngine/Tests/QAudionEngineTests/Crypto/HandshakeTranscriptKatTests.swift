import XCTest
import CryptoKit
@testable import QAudionEngine

/// Cross-platform KAT verifier for the Phase-10b handshake-signing transcript (§3 of
/// `docs/phase18/HANDSHAKE-SIGNING-SPEC.md`).
///
/// ⚠️ **MUST be run by Xcode / SwiftPM (`swift test`) to confirm.** This file was authored
/// in an environment that cannot execute Swift / CryptoKit, so the assertions here are
/// UNVERIFIED on-device. The byte LAYOUT (transcript length + SHA-256) was hand-traced
/// against the golden JSON offline and matches (XC-4, CAPS=6 bytes: OFFER 1853 / `01496bb5…`,
/// ACCEPT 1822 / `5e4ce2f0…`). The Ed25519 **signature** equality assertions can only be
/// confirmed by a real CryptoKit run — `kat-cross-platform.yml` / `engine-tests.yml` is
/// the gate. If the signature assertion fails while the SHA-256 assertion passes, the
/// transcript bytes are correct and the divergence is purely in the Ed25519 primitive
/// (which would be surprising — CryptoKit `Curve25519.Signing` is RFC 8032 pure, same as
/// the Android BouncyCastle reference that produced the golden).
///
/// Loads `handshake-sig-kat.json` (byte-copy of
/// `apps/qaudion-desktop/tools/kat/handshake-sig/handshake-sig-kat.json`) from the test
/// bundle and, for each vector, reconstructs the transcript from the documented RAW inputs
/// and asserts:
///   1. `SHA256(transcript) == expected.transcript_sha256_hex`
///   2. `transcript.count == expected.transcript_len`
///   3. `Ed25519.sign(seed, transcript) == expected.signature_hex` (deterministic, RFC 8032)
///   4. (OFFER) `offerBinding(transcript) == expected.offer_binding_hex`
///   5. round-trip: `verify(transcript, signature, signerIdentityKey) == true`
///
/// The JSON is the immutable cross-platform contract — DO NOT modify it.
final class HandshakeTranscriptKatTests: XCTestCase {

    /// C1 guard: ratchet_v/suite_id are signed into the transcript but NOT on the wire,
    /// so each platform's verifier rebuilds with its OWN constant. They MUST be identical
    /// across Android/iOS/Desktop or signed calls fail cross-platform. Canonical =
    /// 0x04/0x01 (Phase-18 GO-LIVE 2026-06-21, bumped in lockstep across all 3).
    func testRatchetVSuiteIdAreCrossPlatformCanonical() {
        XCTAssertEqual(HandshakeSigningPolicy.ratchetV, 0x04)
        XCTAssertEqual(HandshakeSigningPolicy.suiteId, 0x01)
    }

    func testHandshakeSigKatMatchesCrossPlatformContract() throws {
        guard let url = Bundle.module.url(forResource: "handshake-sig-kat", withExtension: "json") else {
            XCTFail("handshake-sig-kat.json not found in Bundle.module")
            return
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("KAT JSON top-level is not an object"); return
        }
        XCTAssertEqual(json["domain"] as? String, "qaudion-handshake-sig-v1",
                       "KAT domain string must match the fixed transcript prefix")
        guard let vectors = json["vectors"] as? [[String: Any]] else {
            XCTFail("KAT JSON missing 'vectors' array"); return
        }
        XCTAssertFalse(vectors.isEmpty, "KAT JSON contains no vectors")

        var sawOffer = false
        var sawAccept = false
        for v in vectors {
            guard let role = v["role"] as? String else { XCTFail("vector missing role"); continue }
            switch role {
            case "OFFER":  try runOffer(v);  sawOffer = true
            case "ACCEPT": try runAccept(v); sawAccept = true
            default: XCTFail("unknown role \(role)")
            }
        }
        XCTAssertTrue(sawOffer, "expected at least one OFFER vector")
        XCTAssertTrue(sawAccept, "expected at least one ACCEPT vector")
    }

    // MARK: - OFFER

    private func runOffer(_ v: [String: Any]) throws {
        let id = (v["id"] as? String) ?? "?"
        guard let inp = v["inputs"] as? [String: Any],
              let exp = v["expected"] as? [String: Any] else {
            XCTFail("[\(id)] missing inputs/expected"); return
        }
        let callId = try str(inp, "callId", id)
        let sik = try hex(inp, "signerIdentityKey_hex", id)
        let epoch = try hex(inp, "epochId_hex", id)
        let pqc = try hex(inp, "pqcPublicKey_hex", id)
        let x25519 = try hex(inp, "x25519PublicKey_hex", id)
        let strongBox = optHex(inp, "strongBoxPublicKey_hex")
        let dualCurve = optHex(inp, "dualCurvePublicKey_hex")
        let caps = try capabilities(inp, id)
        let ratchetV = try byte(inp, "ratchetV", id)
        let suiteId = try byte(inp, "suiteId", id)
        let psks = inp["pskFingerprints_sorted"] as? [String]

        let transcript = HandshakeTranscript.offer(
            callId: callId,
            signerIdentityKey: sik,
            epochId: epoch,
            pqcPublicKey: pqc,
            x25519PublicKey: x25519,
            strongBoxPublicKey: strongBox,
            dualCurvePublicKey: dualCurve,
            ratchetV3: caps.ratchetV3,
            sframeV1: caps.sframeV1,
            vkeyV1: caps.vkeyV1,
            sessionKdfV3: caps.sessionKdfV3,
            ratchetV4: caps.ratchetV4,
            srtpDirKeyV1: caps.srtpDirKeyV1,
            ratchetV: ratchetV,
            suiteId: suiteId,
            pskFingerprints: psks
        )

        assertTranscript(id: id, transcript: transcript, expected: exp)

        // offer_binding = SHA-256(offerTranscript)
        if let bindingHex = exp["offer_binding_hex"] as? String {
            let binding = HandshakeTranscript.offerBinding(transcript)
            XCTAssertEqual(Self.toHex(binding), bindingHex.lowercased(),
                           "[\(id)] offer_binding mismatch")
        }

        // signature: deterministic Ed25519 over the transcript from the seed.
        assertSignature(id: id, transcript: transcript, inputs: inp, expected: exp, signerPub: sik)
    }

    // MARK: - ACCEPT

    private func runAccept(_ v: [String: Any]) throws {
        let id = (v["id"] as? String) ?? "?"
        guard let inp = v["inputs"] as? [String: Any],
              let exp = v["expected"] as? [String: Any] else {
            XCTFail("[\(id)] missing inputs/expected"); return
        }
        let callId = try str(inp, "callId", id)
        let sik = try hex(inp, "signerIdentityKey_hex", id)
        let epoch = try hex(inp, "epochId_hex", id)
        let ctPqc = try hex(inp, "ctPqc_hex", id)
        let ctX = try hex(inp, "ctX25519_hex", id)
        let ctStrongBox = optHex(inp, "ctStrongBox_hex")
        let ctDualCurve = optHex(inp, "ctDualCurve_hex")
        let selPsk = inp["selectedPskFingerprint"] as? String
        let caps = try capabilities(inp, id)
        let ratchetV = try byte(inp, "ratchetV", id)
        let suiteId = try byte(inp, "suiteId", id)
        let binding = try hex(inp, "binds_offer_binding_hex", id)

        let transcript = HandshakeTranscript.accept(
            callId: callId,
            signerIdentityKey: sik,
            epochId: epoch,
            ctPqc: ctPqc,
            ctX25519: ctX,
            ctStrongBox: ctStrongBox,
            ctDualCurve: ctDualCurve,
            ratchetV3: caps.ratchetV3,
            sframeV1: caps.sframeV1,
            vkeyV1: caps.vkeyV1,
            sessionKdfV3: caps.sessionKdfV3,
            ratchetV4: caps.ratchetV4,
            srtpDirKeyV1: caps.srtpDirKeyV1,
            ratchetV: ratchetV,
            suiteId: suiteId,
            selectedPskFingerprint: selPsk,
            offerBinding: binding
        )

        assertTranscript(id: id, transcript: transcript, expected: exp)
        assertSignature(id: id, transcript: transcript, inputs: inp, expected: exp, signerPub: sik)
    }

    // MARK: - Shared assertions

    private func assertTranscript(id: String, transcript: Data, expected: [String: Any]) {
        if let expLen = (expected["transcript_len"] as? NSNumber)?.intValue {
            XCTAssertEqual(transcript.count, expLen, "[\(id)] transcript length mismatch")
        }
        if let expSha = expected["transcript_sha256_hex"] as? String {
            let actual = Self.toHex(Data(SHA256.hash(data: transcript)))
            if actual != expSha.lowercased() {
                let prefix = Self.commonPrefixLength(actual, expSha.lowercased())
                XCTFail(
                    """
                    [\(id)] transcript SHA-256 mismatch — Swift output diverges from JSON contract.
                      expected: \(expSha.lowercased())
                      actual  : \(actual)
                      diverges at hex char index: \(prefix)
                    """
                )
            }
        }
    }

    /// Re-sign with the seed and assert byte-equal to the golden detached signature, then
    /// confirm the signature verifies against the signer's public key.
    private func assertSignature(id: String, transcript: Data, inputs: [String: Any],
                                 expected: [String: Any], signerPub: Data) {
        guard let seedHex = inputs["signerSeed_hex"] as? String,
              let seed = Self.fromHex(seedHex) else {
            XCTFail("[\(id)] missing/invalid signerSeed_hex"); return
        }
        guard let expSig = expected["signature_hex"] as? String else {
            XCTFail("[\(id)] missing signature_hex"); return
        }
        do {
            let sig = try HandshakeTranscript.sign(transcript: transcript, signingPrivateKeyRaw: seed)
            XCTAssertEqual(sig.count, 64, "[\(id)] Ed25519 signature must be 64 bytes")
            XCTAssertEqual(Self.toHex(sig), expSig.lowercased(),
                           "[\(id)] signature mismatch (Ed25519 is deterministic / RFC 8032)")
            // Verify path: the produced signature MUST verify under the signer pubkey.
            XCTAssertTrue(
                HandshakeTranscript.verify(transcript: transcript, signature: sig, signerIdentityKey: signerPub),
                "[\(id)] verify() rejected a freshly produced signature"
            )
            // Negative: a flipped byte in the transcript must NOT verify.
            var tampered = transcript
            tampered[0] ^= 0xFF
            XCTAssertFalse(
                HandshakeTranscript.verify(transcript: tampered, signature: sig, signerIdentityKey: signerPub),
                "[\(id)] verify() accepted a signature over a tampered transcript"
            )
        } catch {
            XCTFail("[\(id)] sign threw: \(error)")
        }
    }

    // MARK: - JSON extraction helpers

    private struct Caps { let ratchetV3: Bool; let sframeV1: Bool; let vkeyV1: Bool; let sessionKdfV3: Bool; let ratchetV4: Bool; let srtpDirKeyV1: Bool }

    private func capabilities(_ inp: [String: Any], _ id: String) throws -> Caps {
        guard let c = inp["capabilities"] as? [String: Any] else {
            XCTFail("[\(id)] missing capabilities"); throw KatError.shape
        }
        return Caps(
            ratchetV3: (c["ratchetV3"] as? Bool) ?? false,
            sframeV1: (c["sframeV1"] as? Bool) ?? false,
            vkeyV1: (c["vkeyV1"] as? Bool) ?? false,
            sessionKdfV3: (c["sessionKdfV3"] as? Bool) ?? false,
            ratchetV4: (c["ratchetV4"] as? Bool) ?? false,
            srtpDirKeyV1: (c["srtpDirKeyV1"] as? Bool) ?? false
        )
    }

    private func str(_ inp: [String: Any], _ key: String, _ id: String) throws -> String {
        guard let s = inp[key] as? String else { XCTFail("[\(id)] missing \(key)"); throw KatError.shape }
        return s
    }

    private func hex(_ inp: [String: Any], _ key: String, _ id: String) throws -> Data {
        guard let h = inp[key] as? String, let d = Self.fromHex(h) else {
            XCTFail("[\(id)] invalid hex for \(key)"); throw KatError.shape
        }
        return d
    }

    /// Optional hex: absent OR empty-string => nil (the LP(empty) case is exercised by the
    /// transcript builder itself, which treats `nil` and empty `Data` identically).
    private func optHex(_ inp: [String: Any], _ key: String) -> Data? {
        guard let h = inp[key] as? String, !h.isEmpty, let d = Self.fromHex(h) else { return nil }
        return d
    }

    private func byte(_ inp: [String: Any], _ key: String, _ id: String) throws -> UInt8 {
        guard let n = inp[key] as? NSNumber else { XCTFail("[\(id)] missing \(key)"); throw KatError.shape }
        return UInt8(truncatingIfNeeded: n.intValue)
    }

    private enum KatError: Error { case shape }

    // MARK: - Hex helpers (mirror SFrameCodecKatTest)

    private static func fromHex(_ hex: String) -> Data? {
        let h = hex.replacingOccurrences(of: " ", with: "").lowercased()
        guard h.count % 2 == 0 else { return nil }
        var out = Data(capacity: h.count / 2)
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let b = UInt8(h[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    private static func toHex(_ data: Data) -> String {
        var s = ""
        s.reserveCapacity(data.count * 2)
        for b in data { s += String(format: "%02x", b) }
        return s
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let n = min(aChars.count, bChars.count)
        var i = 0
        while i < n && aChars[i] == bChars[i] { i += 1 }
        return i
    }
}

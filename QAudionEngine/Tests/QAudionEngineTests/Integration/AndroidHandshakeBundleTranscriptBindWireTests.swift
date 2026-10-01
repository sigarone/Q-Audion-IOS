import XCTest
@testable import QAudionEngine

/// Wire-encoding properties of the transcript-v5 bundle fields: `sigV5`, `dtlsFingerprint`,
/// `rekeyNonce`, `rekeyRound` and the `hsTranscriptBindV1` capability. Optional fields are
/// omitted from the encoded JSON when nil; decoding uses the literal wire spelling written by the
/// other platforms (never a round trip through this encoder alone).
final class AndroidHandshakeBundleTranscriptBindWireTests: XCTestCase {

    // MARK: - Capabilities.hsTranscriptBindV1

    func testCapabilitiesOmitsTranscriptBindV1WhenNil() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true)
        let json = String(data: try JSONEncoder().encode(caps), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("hsTranscriptBindV1"), "got: \(json)")
    }

    func testCapabilitiesEncodesTranscriptBindV1WhenSetTrue() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true, hsTranscriptBindV1: true)
        let json = String(data: try JSONEncoder().encode(caps), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"hsTranscriptBindV1\":true"))
    }

    /// Decodes a hand-written literal with the exact key the other platforms emit.
    func testDecodesWireKeyLiteralHsTranscriptBindV1() throws {
        let wire = "{\"ratchetV3\":true,\"hsTranscriptBindV1\":true}"
        let caps = try JSONDecoder().decode(AndroidHandshakeBundle.Capabilities.self, from: Data(wire.utf8))
        XCTAssertEqual(caps.hsTranscriptBindV1, true)
    }

    // MARK: - Bundle root: sigV5 / dtlsFingerprint / rekeyNonce / rekeyRound

    func testBundleOmitsV5FieldsWhenNil() throws {
        let bundle = AndroidHandshakeBundle(
            kind: .offer, callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=", x25519PublicKey: "cGxhY2Vob2xkZXI=")
        let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? ""
        for key in ["sigV5", "dtlsFingerprint", "rekeyNonce", "rekeyRound", "signerIdentityKey"] {
            XCTAssertFalse(json.contains(key), "\(key) must be omitted when nil, got: \(json)")
        }
    }

    func testBundleEncodesV5FieldsWhenSet() throws {
        let fp = V5TestFixtures.fingerprintText("offerer")
        let bundle = AndroidHandshakeBundle(
            kind: .offer, callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=", x25519PublicKey: "cGxhY2Vob2xkZXI=",
            signerIdentityKey: "a2V5", sigV5: "c2ln", dtlsFingerprint: fp,
            rekeyNonce: "bm9uY2U4Qg==", rekeyRound: 1)
        let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"sigV5\":\"c2ln\""))
        XCTAssertTrue(json.contains("\"dtlsFingerprint\":\"\(fp)\""))
        XCTAssertTrue(json.contains("\"signerIdentityKey\":\"a2V5\""))
        XCTAssertTrue(json.contains("\"rekeyNonce\":\"bm9uY2U4Qg==\""))
        XCTAssertTrue(json.contains("\"rekeyRound\":1"))
    }

    /// The retired signature fields no longer exist on the wire model: a bundle carrying them
    /// still decodes (unknown keys are ignored) but exposes no value for them.
    func testRetiredSignatureKeysAreIgnoredOnDecode() throws {
        let wire = """
        {"kind":"OFFER","callId":"abc-123","pqcPublicKey":"cGxhY2Vob2xkZXI=","x25519PublicKey":"cGxhY2Vob2xkZXI=",\
        "signature":"AAAA","sigV2":"AAAA","sigV3":"AAAA","sigV4":"AAAA"}
        """
        let bundle = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: Data(wire.utf8))
        XCTAssertNil(bundle.sigV5)
        XCTAssertNil(bundle.dtlsFingerprint)
        XCTAssertNil(bundle.signerIdentityKey)
    }

    func testBundleRoundTripsV5Fields() throws {
        let fp = V5TestFixtures.fingerprintText("acceptor")
        let original = AndroidHandshakeBundle(
            kind: .accept, callId: "abc-123", pqcPublicKey: "", x25519PublicKey: "",
            ciphertext: AndroidHandshakeBundle.Ciphertext(pqc: "cA==", x25519: "eA=="),
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, hsTranscriptBindV1: true),
            signerIdentityKey: "a2V5", sigV5: "c2lnNQ==", dtlsFingerprint: fp,
            rekeyNonce: "bm9uY2U4Qg==", rekeyRound: 3)
        let decoded = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.sigV5, original.sigV5)
        XCTAssertEqual(decoded.dtlsFingerprint, fp)
        XCTAssertEqual(decoded.rekeyRound, 3)
        XCTAssertEqual(decoded.rekeyNonce, original.rekeyNonce)
        XCTAssertEqual(decoded.capabilities?.hsTranscriptBindV1, true)
    }
}

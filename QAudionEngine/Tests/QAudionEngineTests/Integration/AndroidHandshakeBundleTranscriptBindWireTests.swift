import XCTest
@testable import QAudionEngine

/// Wire-encoding properties of the transcript-v6 bundle fields: `sigV6`, `sasCommit`, `dtlsFingerprint`,
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

    // MARK: - Bundle root: sigV6 / sasCommit / dtlsFingerprint / rekeyNonce / rekeyRound

    func testBundleOmitsV6FieldsWhenNil() throws {
        let bundle = AndroidHandshakeBundle(
            kind: .offer, callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=", x25519PublicKey: "cGxhY2Vob2xkZXI=")
        let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? ""
        for key in ["sigV6", "sasCommit", "dtlsFingerprint", "rekeyNonce", "rekeyRound", "signerIdentityKey"] {
            XCTAssertFalse(json.contains(key), "\(key) must be omitted when nil, got: \(json)")
        }
    }

    func testBundleEncodesV6FieldsWhenSet() throws {
        let fp = V6TestFixtures.fingerprintText("offerer")
        let bundle = AndroidHandshakeBundle(
            kind: .offer, callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=", x25519PublicKey: "cGxhY2Vob2xkZXI=",
            signerIdentityKey: "a2V5", sigV6: "c2ln", dtlsFingerprint: fp, sasCommit: "Y29tbWl0",
            rekeyNonce: "bm9uY2U4Qg==", rekeyRound: 1)
        let json = String(data: try JSONEncoder().encode(bundle), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"sigV6\":\"c2ln\""))
        XCTAssertTrue(json.contains("\"sasCommit\":\"Y29tbWl0\""))
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
        "signature":"AAAA","sigV2":"AAAA","sigV3":"AAAA","sigV4":"AAAA","sigV5":"AAAA"}
        """
        let bundle = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: Data(wire.utf8))
        XCTAssertNil(bundle.sigV6)
        XCTAssertNil(bundle.sasCommit)
        XCTAssertNil(bundle.dtlsFingerprint)
        XCTAssertNil(bundle.signerIdentityKey)
    }

    func testBundleRoundTripsV6Fields() throws {
        let fp = V6TestFixtures.fingerprintText("acceptor")
        let original = AndroidHandshakeBundle(
            kind: .accept, callId: "abc-123", pqcPublicKey: "", x25519PublicKey: "",
            ciphertext: AndroidHandshakeBundle.Ciphertext(pqc: "cA==", x25519: "eA=="),
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, hsTranscriptBindV1: true),
            signerIdentityKey: "a2V5", sigV6: "c2lnNg==", dtlsFingerprint: fp,
            rekeyNonce: "bm9uY2U4Qg==", rekeyRound: 3)
        let decoded = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded.sigV6, original.sigV6)
        XCTAssertEqual(decoded.dtlsFingerprint, fp)
        XCTAssertEqual(decoded.rekeyRound, 3)
        XCTAssertEqual(decoded.rekeyNonce, original.rekeyNonce)
        XCTAssertEqual(decoded.capabilities?.hsTranscriptBindV1, true)
    }

    // MARK: - R-COMMIT-FIELD (sasCommit) and R-COMMIT-REVEAL (SASREVEAL piggy-back)

    private func envelope(_ json: String) -> String { "abc-123|" + json }

    private let offerHead = "{\"kind\":\"OFFER\",\"callId\":\"abc-123\",\"pqcPublicKey\":\"cGs=\",\"x25519PublicKey\":\"eA==\""

    func testASasCommitOfTheWireDecodes() throws {
        let parsed = try XCTUnwrap(AndroidHandshakeEnvelope.parse(envelope(offerHead + ",\"rekeyRound\":1,\"sasCommit\":\"AAAA\"}")))
        XCTAssertEqual(parsed.bundle.sasCommit, "AAAA")
    }

    /// A JSON null is PRESENT: Codable would read it as absent, which is wrong for a rekey OFFER or an
    /// ACCEPT (they must not carry the key at all). The parser maps it to the empty string, which the
    /// policy then rejects in every position (`commit_malformed` in round 1, `commit_unexpected` elsewhere).
    func testANullSasCommitIsPresentNotAbsent() throws {
        let nullCommit = try XCTUnwrap(AndroidHandshakeEnvelope.parse(
            envelope(offerHead + ",\"rekeyRound\":2,\"sasCommit\":null}")))
        XCTAssertEqual(nullCommit.bundle.sasCommit, "")
        XCTAssertEqual(HandshakeSigningPolicy.sasCommitMalformedCode(
            isOffer: true, round: 2, sasCommitB64: nullCommit.bundle.sasCommit), "commit_unexpected")
        let round1 = try XCTUnwrap(AndroidHandshakeEnvelope.parse(
            envelope(offerHead + ",\"rekeyRound\":1,\"sasCommit\":null}")))
        XCTAssertEqual(HandshakeSigningPolicy.sasCommitMalformedCode(
            isOffer: true, round: 1, sasCommitB64: round1.bundle.sasCommit), "commit_malformed")
        let absent = try XCTUnwrap(AndroidHandshakeEnvelope.parse(envelope(offerHead + ",\"rekeyRound\":2}")))
        XCTAssertNil(absent.bundle.sasCommit, "an absent key stays absent")
    }

    func testBundleThatDoesNotDecodeIsStillRecognisedAsAHandshakeBundle() {
        // an OFFER without the key fields does not decode as a bundle, but names `kind` OFFER
        let noKeys = envelope("{\"kind\":\"OFFER\",\"callId\":\"abc-123\"}")
        XCTAssertNil(AndroidHandshakeEnvelope.parse(noKeys))
        XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(noKeys), "abc-123")
        // truncated JSON that still names the kind
        let truncated = envelope("{\"kind\":\"ACCEPT\",\"callId\":\"abc-123\",\"cipher")
        XCTAssertNil(AndroidHandshakeEnvelope.parse(truncated))
        XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(truncated), "abc-123")
        // a wrong type for a known field
        XCTAssertEqual(AndroidHandshakeEnvelope.malformedBundleCallId(
            envelope("{\"kind\":\"ACCEPT\",\"callId\":\"abc-123\",\"rekeyRound\":\"x\"}")), "abc-123")
    }

    func testOtherJsonOnTheChannelIsNotAHandshakeBundle() {
        XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId("abc-123|{\"qa_grpcall_ctrl\":1,\"kind\":\"OFFER\"}"))
        XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId("abc-123|{\"qa_kms\":1,\"env_b64\":\"AA==\"}"))
        XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId("abc-123|{\"kind\":\"SOMETHING\"}"))
        XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId("abc-123|HANGUP:x"))
        XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId("no-pipe"))
        XCTAssertNil(AndroidHandshakeEnvelope.malformedBundleCallId("|{\"kind\":\"OFFER\"}"))
    }

    func testSasRevealIsRoutedBeforeTheBundleParserAndKeepsTheRawPayload() {
        let raw = "abc-123|SASREVEAL:AAECAwQ="
        XCTAssertEqual(CallPiggyBack.parse(raw), .sasReveal(callId: "abc-123", raw: "AAECAwQ="))
        // the tag is case-sensitive ASCII: a lower-case one is not a REVEAL
        XCTAssertNil(CallPiggyBack.parse("abc-123|sasreveal:AAECAwQ="))
        // the REVEAL never parses as a bundle either
        XCTAssertNil(AndroidHandshakeEnvelope.parse(raw))
        // KCMAC is still its own tag
        XCTAssertEqual(CallPiggyBack.parse("abc-123|KCMAC:AAEC"), .kcmac(callId: "abc-123", raw: "AAEC"))
    }
}

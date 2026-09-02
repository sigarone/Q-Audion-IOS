import XCTest
@testable import QAudionEngine

/// CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit): wire-encoding
/// properties for the new additive fields — `Capabilities.transcriptBindV1`
/// and the bundle root's `sigV3`/`rekeyNonce`/`rekeyRound`. All FOUR MUST be
/// omitted from the encoded JSON at their default (nil) so the wire bytes for
/// a peer that has not shipped this fix stay byte-identical to today, mirroring
/// the established "omit when default" convention `AndroidHandshakeBundlePskMixWireTests`
/// already proves for `pskMixV1`/`pskRoles`.
final class AndroidHandshakeBundleTranscriptBindWireTests: XCTestCase {

    // MARK: - Capabilities.transcriptBindV1

    func testCapabilitiesOmitsTranscriptBindV1WhenNil() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true)
        let data = try JSONEncoder().encode(caps)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("transcriptBindV1"), "transcriptBindV1 must be omitted from the wire when nil, got: \(json)")
    }

    func testCapabilitiesEncodesTranscriptBindV1WhenSetTrue() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true, transcriptBindV1: true)
        let data = try JSONEncoder().encode(caps)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"transcriptBindV1\":true"))
    }

    func testCapabilitiesDecodesLegacyWithoutTranscriptBindV1AsNil() throws {
        let legacyJson = """
        {"ratchetV3":true}
        """
        let caps = try JSONDecoder().decode(AndroidHandshakeBundle.Capabilities.self, from: Data(legacyJson.utf8))
        XCTAssertNil(caps.transcriptBindV1)
    }

    // MARK: - Bundle root: sigV3 / rekeyNonce / rekeyRound

    func testBundleOmitsSigV3RekeyNonceRekeyRoundWhenNil() throws {
        let bundle = AndroidHandshakeBundle(
            kind: .offer,
            callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=",
            x25519PublicKey: "cGxhY2Vob2xkZXI="
        )
        let data = try JSONEncoder().encode(bundle)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("sigV3"), "sigV3 must be omitted from the wire when nil, got: \(json)")
        XCTAssertFalse(json.contains("rekeyNonce"), "rekeyNonce must be omitted from the wire when nil, got: \(json)")
        XCTAssertFalse(json.contains("rekeyRound"), "rekeyRound must be omitted from the wire when nil, got: \(json)")
    }

    func testBundleEncodesSigV3RekeyNonceRekeyRoundWhenSet() throws {
        let bundle = AndroidHandshakeBundle(
            kind: .offer,
            callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=",
            x25519PublicKey: "cGxhY2Vob2xkZXI=",
            sigV3: "c2ln",
            rekeyNonce: "bm9uY2U4Qg==",
            rekeyRound: 1
        )
        let data = try JSONEncoder().encode(bundle)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"sigV3\":\"c2ln\""))
        XCTAssertTrue(json.contains("\"rekeyNonce\":\"bm9uY2U4Qg==\""))
        XCTAssertTrue(json.contains("\"rekeyRound\":1"))
    }

    /// A re-key round's OFFER carries `rekeyRound` WITHOUT `rekeyNonce` — the
    /// nonce is established once at round 1 and never retransmitted.
    func testBundleEncodesRekeyRoundWithoutNonceForReKeyRounds() throws {
        let bundle = AndroidHandshakeBundle(
            kind: .offer,
            callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=",
            x25519PublicKey: "cGxhY2Vob2xkZXI=",
            rekeyRound: 2
        )
        let data = try JSONEncoder().encode(bundle)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"rekeyRound\":2"))
        XCTAssertFalse(json.contains("rekeyNonce"))
    }

    /// Round-trip sanity: an inbound OFFER from a peer that has not shipped
    /// this fix (omits all four new fields entirely) decodes to nil for every
    /// one of them, never a crash or a spurious default.
    func testBundleDecodesLegacyOfferWithoutNewFieldsAsNil() throws {
        let legacyJson = """
        {"kind":"OFFER","callId":"abc-123","pqcPublicKey":"cGxhY2Vob2xkZXI=","x25519PublicKey":"cGxhY2Vob2xkZXI="}
        """
        let bundle = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: Data(legacyJson.utf8))
        XCTAssertNil(bundle.sigV3)
        XCTAssertNil(bundle.rekeyNonce)
        XCTAssertNil(bundle.rekeyRound)
        XCTAssertNil(bundle.capabilities)
    }

    /// Round-trip: encode then decode preserves all four new fields exactly.
    func testBundleRoundTripsNewFields() throws {
        let original = AndroidHandshakeBundle(
            kind: .accept,
            callId: "abc-123",
            pqcPublicKey: "",
            x25519PublicKey: "",
            ciphertext: AndroidHandshakeBundle.Ciphertext(pqc: "cA==", x25519: "eA=="),
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, transcriptBindV1: true),
            sigV3: "c2lnMw==",
            rekeyRound: 3
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: data)
        XCTAssertEqual(decoded.sigV3, original.sigV3)
        XCTAssertEqual(decoded.rekeyRound, original.rekeyRound)
        XCTAssertEqual(decoded.capabilities?.transcriptBindV1, true)
        XCTAssertNil(decoded.rekeyNonce)
    }
}

import XCTest
@testable import QAudionEngine

/// CALL-3/CALL-4 (HSID-002 remainder, 2026-09-02 protocol audit): wire-encoding
/// properties for the new additive fields — `Capabilities.hsTranscriptBindV1`
/// and the bundle root's `sigV3`/`rekeyNonce`/`rekeyRound`. All FOUR MUST be
/// omitted from the encoded JSON at their default (nil) so the wire bytes for
/// a peer that has not shipped this fix stay byte-identical to today, mirroring
/// the established "omit when default" convention `AndroidHandshakeBundlePskMixWireTests`
/// already proves for `pskMixV1`/`pskRoles`.
///
/// W-HSCAPKEYFIX (2026-09-03) — this file's own round-trip tests below only
/// ever encode-then-decode with iOS's OWN encoder/decoder, so they could not
/// have caught (and did not catch) the real bug: iOS originally spelled this
/// property `transcriptBindV1` while Android's kotlinx.serialization
/// `Capabilities.hsTranscriptBindV1` field (no `@SerialName`, so the Kotlin
/// property name IS the JSON key, exactly like iOS's un-annotated `Codable`
/// struct) put it on the wire as `hsTranscriptBindV1` — a mismatch invisible
/// to any test that only ever decodes iOS's own output. `testDecodesAndroidWireKeyLiteralHsTranscriptBindV1`
/// below closes that gap by decoding a hand-written literal matching Android's
/// actual wire spelling, so a future regression back to a mismatched name
/// fails this suite immediately instead of silently breaking interop again.
final class AndroidHandshakeBundleTranscriptBindWireTests: XCTestCase {

    // MARK: - Capabilities.hsTranscriptBindV1

    func testCapabilitiesOmitsTranscriptBindV1WhenNil() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true)
        let data = try JSONEncoder().encode(caps)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("hsTranscriptBindV1"), "hsTranscriptBindV1 must be omitted from the wire when nil, got: \(json)")
    }

    func testCapabilitiesEncodesTranscriptBindV1WhenSetTrue() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true, hsTranscriptBindV1: true)
        let data = try JSONEncoder().encode(caps)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"hsTranscriptBindV1\":true"))
    }

    func testCapabilitiesDecodesLegacyWithoutTranscriptBindV1AsNil() throws {
        let legacyJson = """
        {"ratchetV3":true}
        """
        let caps = try JSONDecoder().decode(AndroidHandshakeBundle.Capabilities.self, from: Data(legacyJson.utf8))
        XCTAssertNil(caps.hsTranscriptBindV1)
    }

    /// W-HSCAPKEYFIX (2026-09-03) — THE test that would have caught the
    /// original wire-key-name mismatch bug, and must exist going forward so
    /// it can never silently regress back to a mismatched name. Decodes a
    /// HAND-WRITTEN JSON literal using the EXACT key Android's
    /// kotlinx.serialization `Capabilities.hsTranscriptBindV1` field actually
    /// emits on the wire (no `@SerialName` override there either, so the
    /// Kotlin property name IS the JSON key) — never a round-trip through
    /// iOS's own encoder, which is precisely what let the original mismatch
    /// hide from every other test in this file.
    func testDecodesAndroidWireKeyLiteralHsTranscriptBindV1() throws {
        let androidWireJson = """
        {"ratchetV3":true,"hsTranscriptBindV1":true}
        """
        let caps = try JSONDecoder().decode(AndroidHandshakeBundle.Capabilities.self, from: Data(androidWireJson.utf8))
        XCTAssertEqual(caps.hsTranscriptBindV1, true, "must decode Android's literal hsTranscriptBindV1 wire key to true, not nil/false")
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

    /// `AndroidHandshakeBundle` itself imposes NO relationship between
    /// `rekeyRound` and `rekeyNonce` — either may be set independently of the
    /// other at the Codable/wire level; a bundle carrying `rekeyRound` alone
    /// still encodes/decodes cleanly. This is a struct-level property test
    /// only, NOT a claim about production behaviour: ITEM 2/3 FOLLOW-UP
    /// (2026-09-02) made `QAudionCallIntegration` itself always populate
    /// `rekeyNonce` alongside `rekeyRound` on every OFFER (round 1 AND every
    /// re-key round — see `HandshakeTranscript.offerV3`'s doc for why the
    /// prior "round 1 only" production behaviour broke cross-platform
    /// transcript-hash equality); this test's own construction below simply
    /// never sets it, to prove the struct doesn't require it.
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
            capabilities: AndroidHandshakeBundle.Capabilities(ratchetV3: true, hsTranscriptBindV1: true),
            sigV3: "c2lnMw==",
            rekeyRound: 3
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: data)
        XCTAssertEqual(decoded.sigV3, original.sigV3)
        XCTAssertEqual(decoded.rekeyRound, original.rekeyRound)
        XCTAssertEqual(decoded.capabilities?.hsTranscriptBindV1, true)
        XCTAssertNil(decoded.rekeyNonce)
    }
}

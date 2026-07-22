import XCTest
@testable import QAudionEngine

/// PSK-mix ship-step-2 (parse-only): wire-encoding properties for the two new
/// additive fields — `Capabilities.pskMixV1` and
/// `AndroidHandshakeBundle.pskRoles`. Both MUST be omitted from the encoded
/// JSON at their default (nil) so the wire bytes for an ordinary today-shaped
/// call stay byte-identical to before these fields existed, mirroring the
/// established "omit when default" convention already used for
/// `ratchetV4`/`srtpDirKeyV1` (see the doc comments on
/// `AndroidHandshakeBundle.Capabilities`).
final class AndroidHandshakeBundlePskMixWireTests: XCTestCase {

    func testCapabilitiesOmitsPskMixV1WhenNil() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true)
        let data = try JSONEncoder().encode(caps)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("pskMixV1"), "pskMixV1 must be omitted from the wire when nil, got: \(json)")
    }

    func testCapabilitiesEncodesPskMixV1WhenSetTrue() throws {
        let caps = AndroidHandshakeBundle.Capabilities(ratchetV3: true, pskMixV1: true)
        let data = try JSONEncoder().encode(caps)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"pskMixV1\":true"))
    }

    func testBundleOmitsPskRolesWhenNil() throws {
        let bundle = AndroidHandshakeBundle(
            kind: .offer,
            callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=",
            x25519PublicKey: "cGxhY2Vob2xkZXI="
        )
        let data = try JSONEncoder().encode(bundle)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("pskRoles"), "pskRoles must be omitted from the wire when nil, got: \(json)")
    }

    func testBundleEncodesPskRolesWhenSet() throws {
        let bundle = AndroidHandshakeBundle(
            kind: .offer,
            callId: "abc-123",
            pqcPublicKey: "cGxhY2Vob2xkZXI=",
            x25519PublicKey: "cGxhY2Vob2xkZXI=",
            pskRoles: [0, 1]
        )
        let data = try JSONEncoder().encode(bundle)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"pskRoles\":[0,1]"))
    }

    /// Round-trip sanity: an inbound OFFER that omits `pskRoles` entirely
    /// (every peer today) decodes to `nil`, not `[]` or a crash.
    func testBundleDecodesLegacyOfferWithoutPskRolesAsNil() throws {
        let legacyJson = """
        {"kind":"OFFER","callId":"abc-123","pqcPublicKey":"cGxhY2Vob2xkZXI=","x25519PublicKey":"cGxhY2Vob2xkZXI="}
        """
        let bundle = try JSONDecoder().decode(AndroidHandshakeBundle.self, from: Data(legacyJson.utf8))
        XCTAssertNil(bundle.pskRoles)
    }
}

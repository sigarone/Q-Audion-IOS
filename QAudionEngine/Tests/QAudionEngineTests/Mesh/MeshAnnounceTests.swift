import XCTest
@testable import QAudionEngine

final class MeshAnnounceTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let announce = MeshAnnounce(
            nodeIdHex: "a13f0c8e77b20001",
            identityFingerprintHex: "a13f0c8e77b20001",
            displayHint: "Marco",
            neighborNodeIdsHex: ["1111111111111111", "2222222222222222"]
        )
        let decoded = MeshAnnounce.decode(announce.encode())
        XCTAssertEqual(decoded, announce)
    }

    func testEncodeDecodeRoundTripWithNoNeighborsOrHint() {
        let announce = MeshAnnounce(nodeIdHex: "a13f0c8e77b20001", identityFingerprintHex: "a13f0c8e77b20001")
        let decoded = MeshAnnounce.decode(announce.encode())
        XCTAssertEqual(decoded, announce)
        XCTAssertNil(decoded?.displayHint)
        XCTAssertTrue(decoded?.neighborNodeIdsHex.isEmpty ?? false)
    }

    func testDecodeNeverThrowsOnGarbageBytes() {
        XCTAssertNil(MeshAnnounce.decode(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(MeshAnnounce.decode(Data()))
    }

    func testDecodeRejectsUnrelatedJson() {
        let json = Data(#"{"hello": "world"}"#.utf8)
        XCTAssertNil(MeshAnnounce.decode(json))
    }

    func testWireUsesShortFieldNames() throws {
        // Pins the compact key shape (`v`/`node`/`fp`/`hint`/`nbrs`) so a
        // future refactor can't silently balloon the on-air JSON. `hint` is
        // Optional and nil here, so the synthesized encoder omits it; `nbrs`
        // is a non-Optional array (default `[]`) so it is always present.
        let announce = MeshAnnounce(nodeIdHex: "a13f0c8e77b20001", identityFingerprintHex: "a13f0c8e77b20001")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: announce.encode()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["v", "node", "fp", "nbrs"]))
    }
}

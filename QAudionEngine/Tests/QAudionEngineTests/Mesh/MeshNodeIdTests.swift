import XCTest
@testable import QAudionEngine

final class MeshNodeIdTests: XCTestCase {

    func testValidHexRoundTrips() throws {
        let id = try MeshNodeId(hex: "a13f0c8e77b20001")
        XCTAssertEqual(id.hex, "a13f0c8e77b20001")
        XCTAssertEqual(id.description, "a13f0c8e77b20001")
    }

    func testWrongLengthThrows() {
        XCTAssertThrowsError(try MeshNodeId(hex: "abcd")) { error in
            XCTAssertEqual(error as? MeshNodeId.MeshNodeIdError, .wrongLength(4))
        }
    }

    func testUppercaseHexRejected() {
        XCTAssertThrowsError(try MeshNodeId(hex: "A13F0C8E77B20001")) { error in
            guard case .notLowercaseHex = error as? MeshNodeId.MeshNodeIdError else {
                return XCTFail("expected notLowercaseHex, got \(error)")
            }
        }
    }

    func testBytesRoundTrip() throws {
        let id = try MeshNodeId(hex: "0011223344556677")
        let bytes = id.toBytes()
        XCTAssertEqual(bytes.count, MeshNodeId.sizeBytes)
        XCTAssertEqual(MeshNodeId.fromBytes(bytes), id)
    }

    func testFromBytesRejectsWrongSize() {
        XCTAssertNil(MeshNodeId.fromBytes(Data([0x01, 0x02])))
    }

    func testBroadcastSentinelIsAllFF() {
        XCTAssertEqual(MeshNodeId.broadcast.hex, String(repeating: "f", count: 16))
    }

    func testRandomProducesValidId() {
        let a = MeshNodeId.random()
        let b = MeshNodeId.random()
        XCTAssertEqual(a.hex.count, MeshNodeId.hexLength)
        // Astronomically unlikely to collide; guards against a broken RNG
        // that always returns the same bytes.
        XCTAssertNotEqual(a, b)
    }

    func testIdentityKeyDerivationIsStableAndObserverIndependent() {
        let key = Data(repeating: 0x42, count: 32)
        let a = MeshNodeId.from(identityKeyRaw: key)
        let b = MeshNodeId.from(identityKeyRaw: key)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
    }

    func testIdentityKeyDerivationDiffersPerKey() {
        let a = MeshNodeId.from(identityKeyRaw: Data(repeating: 0x01, count: 32))
        let b = MeshNodeId.from(identityKeyRaw: Data(repeating: 0x02, count: 32))
        XCTAssertNotEqual(a, b)
    }

    func testIdentityKeyDerivationRejectsEmptyInput() {
        XCTAssertNil(MeshNodeId.from(identityKeyRaw: Data()))
    }
}

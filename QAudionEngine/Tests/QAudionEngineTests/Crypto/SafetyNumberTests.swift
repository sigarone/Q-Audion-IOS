import XCTest
@testable import QAudionEngine

/// Cross-platform parity tests for `SafetyNumber`, pinned against Android
/// `core-trust/.../SafetyNumberKatTest.kt` (itself KAT-tested against
/// Desktop `SafetyNumber.spec.ts`). Same inputs, same expected outputs —
/// if this ever fails, the CBOR encoding or HKDF labels drifted from
/// WIRE_SPEC.md §5.1.2; fix that, never adjust the expected output.
final class SafetyNumberTests: XCTestCase {

    private let uuidAHex = "01940000000070008000aaaabbbbcccc"
    private let uuidBHex = "0194000000007000800011112222dddd"
    private let ikA = Data(repeating: 0x11, count: 32)
    private let ikB = Data(repeating: 0x22, count: 32)

    private let expectedDisplay =
        "54000 44743 06999 97232 17912 39550 98493 78657 23147 63876 95955 60152"
    private let expectedFingerprintHex =
        "3e030235674af37db0d01cc98ccf7e48dfd13341c8f6b58d64c25333f838"

    func testKatByteForByteParityWithAndroidAndDesktop() throws {
        let uuidA = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidAHex))
        let uuidB = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidBHex))
        let r = try SafetyNumber.compute(localUuidRaw: uuidA, localIkEdPub: ikA,
                                          peerUuidRaw: uuidB, peerIkEdPub: ikB)
        XCTAssertEqual(r.display, expectedDisplay)
        XCTAssertEqual(r.fingerprintHex, expectedFingerprintHex)
        XCTAssertEqual(r.groups.count, SafetyNumber.digitGroups)
    }

    func testOrderInvarianceAToBAndBToA() throws {
        let uuidA = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidAHex))
        let uuidB = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidBHex))
        let ab = try SafetyNumber.compute(localUuidRaw: uuidA, localIkEdPub: ikA,
                                           peerUuidRaw: uuidB, peerIkEdPub: ikB)
        let ba = try SafetyNumber.compute(localUuidRaw: uuidB, localIkEdPub: ikB,
                                           peerUuidRaw: uuidA, peerIkEdPub: ikA)
        XCTAssertEqual(ab.display, ba.display)
        XCTAssertEqual(ab.fingerprintHex, ba.fingerprintHex)
    }

    func test60DigitDisplayHasExactly60NumericChars() throws {
        let uuidA = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidAHex))
        let uuidB = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidBHex))
        let r = try SafetyNumber.compute(localUuidRaw: uuidA, localIkEdPub: ikA,
                                          peerUuidRaw: uuidB, peerIkEdPub: ikB)
        let digitsOnly = r.display.replacingOccurrences(of: " ", with: "")
        XCTAssertEqual(digitsOnly.count, 60)
        XCTAssertTrue(digitsOnly.allSatisfy { $0.isNumber })
    }

    func testFingerprintChangesWhenPeerIkEdPubRotates() throws {
        let uuidA = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidAHex))
        let uuidB = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidBHex))
        let before = try SafetyNumber.compute(localUuidRaw: uuidA, localIkEdPub: ikA,
                                               peerUuidRaw: uuidB, peerIkEdPub: ikB)
        let after = try SafetyNumber.compute(localUuidRaw: uuidA, localIkEdPub: ikA,
                                              peerUuidRaw: uuidB, peerIkEdPub: Data(repeating: 0x33, count: 32))
        XCTAssertNotEqual(before.fingerprintHex, after.fingerprintHex)
    }

    func testRejectsEqualUuids() throws {
        let uuidA = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidAHex))
        XCTAssertThrowsError(try SafetyNumber.compute(localUuidRaw: uuidA, localIkEdPub: ikA,
                                                        peerUuidRaw: uuidA, peerIkEdPub: ikB)) { error in
            XCTAssertEqual(error as? SafetyNumber.SafetyNumberError, .equalUuids)
        }
    }

    func testRejectsWrongLengthUuid() throws {
        let uuidB = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidBHex))
        XCTAssertThrowsError(try SafetyNumber.compute(localUuidRaw: Data(count: 15), localIkEdPub: ikA,
                                                        peerUuidRaw: uuidB, peerIkEdPub: ikB))
    }

    func testRejectsWrongLengthIkEdPub() throws {
        let uuidA = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidAHex))
        let uuidB = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidBHex))
        XCTAssertThrowsError(try SafetyNumber.compute(localUuidRaw: uuidA, localIkEdPub: Data(count: 31),
                                                        peerUuidRaw: uuidB, peerIkEdPub: ikB))
    }

    func testRawUuidBytesRoundTrip() throws {
        let raw = try XCTUnwrap(SafetyNumber.rawUuidBytes(fromUuidString: uuidAHex))
        XCTAssertEqual(raw.map { String(format: "%02x", $0) }.joined(), uuidAHex)
    }
}

import XCTest
@testable import QAudionEngine

final class MessageWireFormatTests: XCTestCase {

    func testDetectV1OnEmpty() {
        XCTAssertEqual(MessageWireFormat.detect(Data()), .v1)
    }

    func testDetectV2() {
        XCTAssertEqual(MessageWireFormat.detect(Data([0xE2, 0x00])), .v2)
        XCTAssertTrue(MessageWireFormat.isV2(Data([0xE2, 0x01, 0x02])))
    }

    func testDetectV3() {
        XCTAssertEqual(MessageWireFormat.detect(Data([0xE3, 0x00])), .v3)
        XCTAssertTrue(MessageWireFormat.isV3(Data([0xE3, 0x01, 0x02])))
    }

    func testDetectV1OnUnknownMagic() {
        // Random first byte → assume legacy v1 (no magic byte).
        XCTAssertEqual(MessageWireFormat.detect(Data([0x42, 0x00])), .v1)
        XCTAssertEqual(MessageWireFormat.detect(Data([0xFF])), .v1)
    }

    // MARK: - parseV3Header

    func testParseV3HeaderHappyPath() throws {
        let epoch = "epoch-1"                  // 7 bytes
        let dir: UInt8 = 0x01                  // lo->hi
        let chainIdx: UInt64 = 0x0123_4567_89AB_CDEF
        let ciphertext = Data(repeating: 0xAA, count: 8)
        let tag = Data(repeating: 0xCC, count: 16)

        var wire = Data()
        wire.append(0xE3)                                            // magic
        wire.append(UInt8(epoch.utf8.count))                         // epoch_len
        wire.append(Data(epoch.utf8))
        wire.append(dir)
        // chain_idx BE
        var idx = chainIdx
        for _ in 0..<8 {
            wire.append(UInt8((idx >> 56) & 0xFF))
            idx <<= 8
        }
        wire.append(ciphertext)
        wire.append(tag)

        let header = try MessageWireFormat.parseV3Header(wire)
        XCTAssertEqual(header.epoch, "epoch-1")
        XCTAssertEqual(header.directionFlag, 0x01)
        XCTAssertEqual(header.chainIdx, 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(header.ciphertextLength, ciphertext.count)
    }

    func testParseV3HeaderRejectsNonV3() {
        let bad = Data([0xE2, 0x05, 0x68, 0x69])
        XCTAssertThrowsError(try MessageWireFormat.parseV3Header(bad)) { err in
            guard case MessageWireFormat.WireError.notV3 = err else {
                XCTFail("expected .notV3, got \(err)"); return
            }
        }
    }

    func testParseV3HeaderRejectsTruncated() {
        // 0xE3 + epoch_len(1) + epoch(1 byte) + dir(0x01) — missing chain_idx & tag.
        let bad = Data([0xE3, 0x01, 0x65, 0x01])
        XCTAssertThrowsError(try MessageWireFormat.parseV3Header(bad))
    }

    func testParseV3HeaderRejectsBadDirection() {
        var wire = Data([0xE3, 0x01, 0x65, 0x99]) // dir=0x99 invalid
        wire.append(Data(repeating: 0, count: 8 + 16)) // chain_idx + tag
        XCTAssertThrowsError(try MessageWireFormat.parseV3Header(wire)) { err in
            guard case MessageWireFormat.WireError.badDirection(let d) = err else {
                XCTFail("expected .badDirection, got \(err)"); return
            }
            XCTAssertEqual(d, 0x99)
        }
    }
}

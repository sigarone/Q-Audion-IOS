import XCTest
@testable import QAudionEngine

/// The values of the server interface: the geometry of an object, the parts map, and that no secret reaches a log.
final class FileV2ServerTypesTests: XCTestCase {

    // MARK: Geometry

    func testPartSizeIsEightChunksOfTheFormat() {
        XCTAssertEqual(FileV2Wire.partSize, 8_388_736)
        XCTAssertEqual(FileV2Wire.partSize, FileV2Wire.chunksPerPart * FileV2.stride)
        XCTAssertEqual(FileV2Wire.maxParts, 640)
        XCTAssertEqual(FileV2Wire.pathPrefix, "/api/v1/files/v2")
        XCTAssertEqual(FileV2Wire.maxRetryAfterSeconds, 300)
    }

    func testPartCountOfEveryEdge() {
        let size = Int64(FileV2Wire.partSize)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: 0), 0)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: 64), 0, "a header and no payload")
        XCTAssertEqual(FileV2Wire.partCount(blobLength: 65), 1)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: 64 + size - 1), 1)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: 64 + size), 1)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: 64 + size + 1), 2)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: 64 + 2 * size), 2)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: Int64(FileV2.maxBlob)), 640)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: Int64(FileV2.maxBlob) + 1), 641)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: -1), 0)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: Int64.min), 0)
        XCTAssertEqual(FileV2Wire.partCount(blobLength: Int64.max), Int(Int32.max), "no trap, clamped")
    }

    func testPartOffsetAndLength() {
        let size = Int64(FileV2Wire.partSize)
        XCTAssertEqual(FileV2Wire.partOffset(0), 64)
        XCTAssertEqual(FileV2Wire.partOffset(1), 64 + size)
        XCTAssertEqual(FileV2Wire.partOffset(639), 64 + 639 * size)
        XCTAssertNil(FileV2Wire.partOffset(-1))
        XCTAssertNil(FileV2Wire.partOffset(Int.max), "overflow is nil, not a trap")

        // two parts: the second one is the remainder
        let blob = 64 + size + 700
        XCTAssertEqual(FileV2Wire.partLength(blobLength: blob, part: 0), FileV2Wire.partSize)
        XCTAssertEqual(FileV2Wire.partLength(blobLength: blob, part: 1), 700)
        XCTAssertEqual(FileV2Wire.partLength(blobLength: blob, part: 2), 0, "no such part")
        XCTAssertEqual(FileV2Wire.partLength(blobLength: blob, part: -1), 0)
        // a blob that ends exactly on a part boundary has no short part
        XCTAssertEqual(FileV2Wire.partLength(blobLength: 64 + 2 * size, part: 1), FileV2Wire.partSize)
        // the payload bytes of all the parts add up to the payload
        var sum = 0
        for part in 0..<FileV2Wire.partCount(blobLength: blob) { sum += FileV2Wire.partLength(blobLength: blob, part: part) }
        XCTAssertEqual(Int64(sum), blob - 64)
        let max = Int64(FileV2.maxBlob)
        XCTAssertEqual(FileV2Wire.partLength(blobLength: max, part: 639), FileV2Wire.partSize)
    }

    // MARK: Parts map

    func testPartsMapBitOrderIsLeastSignificantFirst() throws {
        // parts 0, 1 and 9 of 10: byte 0 = 0b0000_0011, byte 1 = 0b0000_0010
        let map = try FileV2PartsMap.fromWire(blobLength: 100, partSize: FileV2Wire.partSize, parts: 10, received: 3, complete: false,
                                              bitmap: Data([0x03, 0x02]))
        XCTAssertEqual(map.bits, [true, true, false, false, false, false, false, false, false, true])
        XCTAssertEqual(map.missing, [2, 3, 4, 5, 6, 7, 8])
        XCTAssertTrue(map.isReceived(9))
        XCTAssertFalse(map.isReceived(8))
        XCTAssertFalse(map.isReceived(10))
        XCTAssertFalse(map.isReceived(-1))
        XCTAssertEqual(map.toWireBitmap(), Data([0x03, 0x02]))
    }

    func testPartsMapRoundTripsEveryLength() throws {
        for parts in [0, 1, 7, 8, 9, 16, 17, 640] {
            var bits = [Bool](repeating: false, count: parts)
            for index in stride(from: 0, to: parts, by: 3) { bits[index] = true }
            let received = bits.filter { $0 }.count
            let map = FileV2PartsMap(blobLength: 1, partSize: FileV2Wire.partSize, parts: parts, received: received, complete: false, bits: bits)
            let wire = map.toWireBitmap()
            XCTAssertEqual(wire.count, (parts + 7) / 8)
            let back = try FileV2PartsMap.fromWire(blobLength: 1, partSize: FileV2Wire.partSize, parts: parts, received: received,
                                                   complete: false, bitmap: wire)
            XCTAssertEqual(back, map, "\(parts) parts")
        }
    }

    func testAPartsMapThatDoesNotDescribeItsObjectIsRefused() {
        func decode(parts: Int, received: Int, bitmap: [UInt8]) throws -> FileV2PartsMap {
            try FileV2PartsMap.fromWire(blobLength: 1, partSize: FileV2Wire.partSize, parts: parts, received: received, complete: false,
                                        bitmap: Data(bitmap))
        }
        XCTAssertThrowsError(try decode(parts: 10, received: 0, bitmap: [0])) { XCTAssertEqual($0 as? FileV2WireFormatError, .invalidPartsMap) }
        XCTAssertThrowsError(try decode(parts: 10, received: 0, bitmap: [0, 0, 0]))
        XCTAssertThrowsError(try decode(parts: 8, received: 0, bitmap: [0, 0]))
        XCTAssertThrowsError(try decode(parts: 10, received: 3, bitmap: [0x03, 0x04]), "a bit set past the last part")
        XCTAssertThrowsError(try decode(parts: 10, received: 4, bitmap: [0x03, 0x02]), "received differs from the bits")
        XCTAssertThrowsError(try decode(parts: -1, received: 0, bitmap: []))
        XCTAssertNoThrow(try decode(parts: 0, received: 0, bitmap: []))
        XCTAssertNoThrow(try decode(parts: 10, received: 3, bitmap: [0x03, 0x02]))
    }

    // MARK: Nothing secret in a description

    func testSecretsNeverAppearInADescriptionOrADump() {
        let secret = "deadbeefcafe0123456789abcdef"
        let object = "0b9f3b9e-8d4a-4a0e-9d0e-0123456789ab"
        let token = FileV2IssuedToken(v: secret, exp: 1, max: 10, scope: "user")
        let auth = FileV2DownloadAuth(v: secret, expMs: 1, max: 10)
        let created = FileV2Created(obj: object, blobLength: 100, partSize: FileV2Wire.partSize, parts: 1, parallelism: 6,
                                    maxParallelism: 8, token: token, existing: false, received: 0, complete: false)
        let request = FileV2CreateRequest(blobLength: 100, head: Data(repeating: 7, count: 64),
                                          token: FileV2TokenRequest.forRecipient("some-user-id"))
        let item = FileV2UnfinishedItem(obj: object, blobLength: 1, parts: 1, received: 0, createdMs: 0, activityMs: 0)

        for value in [String(describing: token), String(reflecting: token), String(describing: auth), String(reflecting: auth),
                      String(describing: created), String(reflecting: created), String(describing: item),
                      String(describing: request), String(describing: request.token as Any)] {
            XCTAssertFalse(value.contains(secret), value)
            XCTAssertFalse(value.contains("0123456789ab"), value)
            XCTAssertFalse(value.contains("some-user-id"), value)
            XCTAssertFalse(value.contains("7, 7"), value)
        }
        var dumped = ""
        dump(token, to: &dumped)
        dump(auth, to: &dumped)
        XCTAssertFalse(dumped.contains(secret), dumped)
        XCTAssertTrue(String(describing: created).contains("0b9f3b9e"), "an id is cut to its first 8 characters")
    }

    func testTokenRequestsKnowTheirScopeAndNothingMore() {
        let user = FileV2TokenRequest.forRecipient("alice", ttlSeconds: 60, maxUses: 3)
        XCTAssertEqual(user.recipientUserID, "alice")
        XCTAssertNil(user.groupID)
        XCTAssertEqual(user.ttlSeconds, 60)
        XCTAssertEqual(user.maxUses, 3)
        let group = FileV2TokenRequest.forGroup("group-0001abcd")
        XCTAssertNil(group.recipientUserID)
        XCTAssertNil(group.ttlSeconds)
        // a malformed request can be built: the server refuses it
        XCTAssertNotNil(FileV2TokenRequest(recipientUserID: nil, groupID: nil))
        XCTAssertNotNil(FileV2TokenRequest(recipientUserID: "a", groupID: "b"))
    }

    func testTheSystemClockIsTheWallClockInMilliseconds() {
        let now = FileV2SystemClock().nowMs()
        XCTAssertGreaterThan(now, 1_790_000_000_000)    // after 2026-09
        XCTAssertLessThan(now, 4_000_000_000_000)
        XCTAssertLessThanOrEqual(abs(now - Int64(Date().timeIntervalSince1970 * 1000)), 1000)
    }
}

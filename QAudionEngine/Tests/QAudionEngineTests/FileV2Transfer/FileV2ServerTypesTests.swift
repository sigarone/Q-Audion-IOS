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
        // the server's numbers can be anything: no trap at either end of the range
        XCTAssertEqual(FileV2Wire.partLength(blobLength: Int64.max, part: Int(Int32.max) - 1), FileV2Wire.partSize)
        XCTAssertEqual(FileV2Wire.partLength(blobLength: Int64.max, part: Int(Int32.max)), 0)
        XCTAssertEqual(FileV2Wire.partLength(blobLength: Int64.max, part: Int.max), 0)
        XCTAssertEqual(FileV2Wire.partLength(blobLength: Int64.min, part: 0), 0)
        XCTAssertNotNil(FileV2Wire.partOffset(Int(Int32.max)))
        XCTAssertNil(FileV2Wire.partOffset(Int.max / 2), "the product overflows: nil, not a trap")
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
        for parts in [1, 7, 8, 9, 16, 17, 640] {
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
        XCTAssertThrowsError(try decode(parts: 0, received: 0, bitmap: []), "an object has at least one part") {
            XCTAssertEqual($0 as? FileV2WireFormatError, .invalidPartsMap)
        }
        XCTAssertNoThrow(try decode(parts: 10, received: 3, bitmap: [0x03, 0x02]))
    }

    /// The `parts` of a parts map is a number from the server's JSON, so it can be any `Int`; the length of the bitmap it
    /// asks for was `(parts + 7) / 8`, which traps for the last seven values of the range and, for the others, sizes an
    /// allocation by a number the server chose. Now a count outside 1...640 (an object of this protocol has 1 to 640 parts)
    /// is refused before any arithmetic, whatever the bitmap holds.
    func testAHostilePartsCountIsRefusedWithoutTrappingOrAllocating() {
        let counts: [Int] = [
            Int.max, Int.max - 1, Int.max - 6, Int.max - 7, Int.max - 8, Int.max / 2, 1 << 62, 1 << 40, Int(Int32.max),
            Int(Int32.max) + 1, Int(Int32.max) + 7, Int.min, Int.min + 1, Int.min + 7, -1, -7, -8, -9, 0, 641, 648, 5_000
        ]
        let bitmaps: [Data] = [Data(), Data([0]), Data([0xFF]), Data(count: 80), Data(count: 81), Data(count: 82),
                               Data(repeating: 0xFF, count: 1 << 16), Data(count: 1 << 23)]
        for parts in counts {
            for bitmap in bitmaps {
                for received in [0, 1, parts, Int.max, Int.min] {
                    XCTAssertThrowsError(try FileV2PartsMap.fromWire(blobLength: 100, partSize: FileV2Wire.partSize, parts: parts,
                                                                     received: received, complete: false, bitmap: bitmap),
                                         "parts \(parts), \(bitmap.count) bytes, received \(received)") {
                        XCTAssertEqual($0 as? FileV2WireFormatError, .invalidPartsMap)
                    }
                }
            }
        }
    }

    func testThePartsCountAtTheEdgesOfTheRange() throws {
        // 640 parts: exactly 80 bytes, all of them set
        let full = try FileV2PartsMap.fromWire(blobLength: Int64(FileV2.maxBlob), partSize: FileV2Wire.partSize, parts: FileV2Wire.maxParts,
                                               received: 640, complete: true, bitmap: Data(repeating: 0xFF, count: 80))
        XCTAssertEqual(full.parts, 640)
        XCTAssertTrue(full.missing.isEmpty)
        XCTAssertEqual(full.toWireBitmap(), Data(repeating: 0xFF, count: 80))
        // 641 parts: one more than an object can have, even with the right number of bytes for it (81)
        XCTAssertThrowsError(try FileV2PartsMap.fromWire(blobLength: 100, partSize: FileV2Wire.partSize, parts: 641, received: 0,
                                                         complete: false, bitmap: Data(count: 81)))
        // one part: one byte, bit 0
        let one = try FileV2PartsMap.fromWire(blobLength: 100, partSize: FileV2Wire.partSize, parts: 1, received: 1, complete: false,
                                              bitmap: Data([0x01]))
        XCTAssertEqual(one.bits, [true])
        XCTAssertThrowsError(try FileV2PartsMap.fromWire(blobLength: 100, partSize: FileV2Wire.partSize, parts: 1, received: 1,
                                                         complete: false, bitmap: Data([0x03])), "a bit past the last part")
        // a bitmap that is a slice of a larger buffer reads from its own start
        let buffer = Data([0xEE, 0xEE, 0x01, 0xEE])
        let slice = buffer[2..<3]
        XCTAssertNoThrow(try FileV2PartsMap.fromWire(blobLength: 100, partSize: FileV2Wire.partSize, parts: 1, received: 1, complete: false,
                                                     bitmap: slice))
    }

    func testTheBitmapLengthNeverOverflows() {
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: 0), 0)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: 1), 1)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: 8), 1)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: 9), 2)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: 640), 80)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: -5), 0)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: Int.max), Int.max / 8 + 1)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: Int.max - 6), Int.max / 8 + 1)
        XCTAssertEqual(FileV2PartsMap.bitmapLength(parts: Int.min), 0)
    }

    /// The memberwise initializer is public and does not validate, so a map made by hand can say anything about `parts`: the
    /// wire form is still built from the bits it holds, with no overflow and no allocation sized by `parts`.
    func testAHandMadeMapWithAnAbsurdPartsCountStillEncodesFromItsBits() {
        for parts in [Int.max, Int.max - 6, Int.min, -1, 1 << 40] {
            let map = FileV2PartsMap(blobLength: 1, partSize: FileV2Wire.partSize, parts: parts, received: 2, complete: false,
                                     bits: [true, false, true])
            XCTAssertEqual(map.toWireBitmap(), parts >= 3 ? Data([0x05]) : Data(), "parts \(parts)")
        }
        XCTAssertEqual(FileV2PartsMap(blobLength: 1, partSize: 1, parts: 0, received: 0, complete: false, bits: []).toWireBitmap(), Data())
    }

    // MARK: Nothing secret in a description or a dump

    /// What a `dump` shows of a type that is NOT redacted: the control that proves the checks below can see a leak.
    private struct PlainWithSecrets {
        let head: [UInt8]
        let token: String
        let user: String
    }

    /// Every value reachable through the mirrors of `value` (what `dump`, `print` and a debugger walk), to a depth.
    private func reflectedValues(_ value: Any, depth: Int = 0) -> [Any] {
        guard depth < 8 else { return [] }
        var out: [Any] = [value]
        for child in Mirror(reflecting: value).children { out += reflectedValues(child.value, depth: depth + 1) }
        return out
    }

    /// Every public value type of the layer that holds a token, a header, the bytes of the file, or a user, group or object
    /// id, and every other one (so that a new field cannot leak unnoticed in a type nobody looked at again), is described,
    /// reflected and dumped; none of it may show a token, the bytes of a header or of a range, or an identifier in full.
    func testSecretsNeverAppearInADescriptionOrADump() throws {
        let secret = "deadbeefcafe0123456789abcdef"                  // a download token value
        let object = "0b9f3b9e-8d4a-4a0e-9d0e-0123456789ab"           // a full object id
        let cursor = "5e7a1c44-3b2d-4f60-9a8e-fedcba987654"           // the cursor of a next page: an object id as well
        let user = "user-id-c0ffee-1234"
        let group = "group-id-badc0de-5678"
        let head = Data(repeating: 0xA7, count: 64)                   // the 64-byte header: 167 in a dump
        let range = Data(repeating: 0xB9, count: 64)                  // the bytes of a range: 185 in a dump
        let hex = "a7a7a7a7"

        let token = FileV2IssuedToken(v: secret, exp: 1, max: 10, scope: "user")
        let auth = FileV2DownloadAuth(v: secret, expMs: 1, max: 10)
        let userScope = FileV2TokenRequest.forRecipient(user, ttlSeconds: 60, maxUses: 3)
        let groupScope = FileV2TokenRequest.forGroup(group)
        let request = FileV2CreateRequest(blobLength: 100, head: head, token: userScope)
        let created = FileV2Created(obj: object, blobLength: 100, partSize: FileV2Wire.partSize, parts: 1, parallelism: 6,
                                    maxParallelism: 8, token: token, existing: false, received: 0, complete: false)
        let item = FileV2UnfinishedItem(obj: object, blobLength: 100, parts: 1, received: 0, createdMs: 0, activityMs: 0)
        let page = FileV2UnfinishedPage(objects: [item], next: cursor)
        let ranged = FileV2RangeResult(body: range, totalLength: 100)
        let map = try FileV2PartsMap.fromWire(blobLength: 100, partSize: FileV2Wire.partSize, parts: 1, received: 1, complete: false,
                                              bitmap: Data([0x01]))
        let details = FileV2ErrorDetails(used: 5, limit: 9, maxBlobLength: 12, feature: "feat.files", packageName: "pro")

        let values: [(String, Any)] = [
            ("FileV2IssuedToken", token), ("FileV2DownloadAuth", auth), ("FileV2TokenRequest user", userScope),
            ("FileV2TokenRequest group", groupScope), ("FileV2CreateRequest", request), ("FileV2Created", created),
            ("FileV2UnfinishedItem", item), ("FileV2UnfinishedPage", page), ("FileV2RangeResult", ranged),
            ("[FileV2Created]", [created]), ("[FileV2UnfinishedItem]", [item]), ("FileV2Created?", Optional(created) as Any),
            ("FileV2CreateRequest?", Optional(request) as Any),
            ("FileV2PutResult", FileV2PutResult(part: 0, duplicate: false, received: 1, parts: 1)),
            ("FileV2PartsMap", map), ("FileV2BulkDeleteResult", FileV2BulkDeleteResult(deleted: 1, freedBytes: 100)),
            ("FileV2ErrorDetails", details),
            ("FileV2ServerError", FileV2ServerError(status: 413, code: "quota_exceeded", missing: [1, 2], details: details)),
            ("FileV2WireFormatError", FileV2WireFormatError.invalidPartsMap), ("FileV2TransferError", FileV2TransferError.quota),
            ("FileV2Disposition", FileV2Disposition.userRemedy(.quota)), ("FileV2Op", FileV2Op.putPart),
            ("FileV2ConfigError", FileV2ConfigError.invalidArgument("memoryMiB")),
            ("FileV2MemBudget", try FileV2MemBudget(memoryMiB: 512)), ("FileV2RetryPolicy", FileV2RetryPolicy()),
            ("FileV2ParallelismStats", FileV2ParallelismStats(finalParallelism: 4, changes: 1, meanGoodputBytesPerSecond: 12.5)),
            ("FileV2AdaptiveParallelism", FileV2AdaptiveParallelism(serverParallelism: 6, serverMaxParallelism: 8, memoryCap: 6, startMs: 0)),
            ("FileV2ProgressDeadline", FileV2ProgressDeadline(idleLimitMs: 1, startMs: 0)),
            ("FileV2SystemClock", FileV2SystemClock())
        ]
        let forbidden = [secret, "0123456789ab", "9d0e-0123", "fedcba987654", "5e7a1c44", user, group, "c0ffee", "badc0de", hex,
                         "167", "185", "0xa7", "0xb9", "0xA7", "0xB9"]

        for (name, value) in values {
            var dumped = ""
            dump(value, to: &dumped)
            let texts = [String(describing: value), String(reflecting: value), "\(value)", dumped]
            for text in texts {
                for needle in forbidden {
                    XCTAssertFalse(text.contains(needle), "\(name) shows '\(needle)': \(text)")
                }
            }
            // and nothing the mirror reaches is the bytes of a header or of a range, or a secret string
            for leaf in reflectedValues(value) {
                XCTAssertFalse(leaf is Data, "\(name) reflects a Data")
                XCTAssertFalse(leaf is [UInt8], "\(name) reflects a byte array")
                if let text = leaf as? String {
                    for needle in [secret, object, cursor, user, group] { XCTAssertFalse(text.contains(needle), "\(name): \(text)") }
                }
            }
        }

        // the redaction keeps what a log needs: the first 8 characters of an id, the kind of scope, the numbers
        XCTAssertTrue(String(describing: created).contains("0b9f3b9e"), "an id is cut to its first 8 characters")
        XCTAssertTrue(String(describing: item).contains("0b9f3b9e"))
        var dumpedCreated = ""
        dump(created, to: &dumpedCreated)
        XCTAssertTrue(dumpedCreated.contains("0b9f3b9e"), dumpedCreated)
        XCTAssertTrue(dumpedCreated.contains("parts"), dumpedCreated)
        var dumpedRequest = ""
        dump(request, to: &dumpedRequest)
        XCTAssertTrue(dumpedRequest.contains("blobLength"), dumpedRequest)
        XCTAssertTrue(dumpedRequest.contains("user"), "the kind of scope is kept")
        XCTAssertEqual(String(describing: page), "FileV2UnfinishedPage(objects=1, hasNext=true)")
        XCTAssertEqual(String(describing: ranged), "FileV2RangeResult(bytes=64, totalLength=100)")

        // the control: a type that is not redacted shows all of it, so the checks above can see a leak
        var plain = ""
        dump(PlainWithSecrets(head: [UInt8](head), token: secret, user: user), to: &plain)
        XCTAssertTrue(plain.contains(secret))
        XCTAssertTrue(plain.contains(user))
        XCTAssertTrue(plain.contains("167"))
        XCTAssertTrue(reflectedValues(PlainWithSecrets(head: [UInt8](head), token: secret, user: user)).contains { $0 is [UInt8] })
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

    /// Durations are measured on the monotonic clock: it has no epoch (it is not the wall clock) and it never goes back.
    func testTheSystemMonotonicClockOnlyMovesForwardAndIsNotTheWallClock() {
        let clock = FileV2SystemClock()
        var last = clock.monotonicMs()
        XCTAssertGreaterThan(last, 0)
        for _ in 0..<2_000 {
            let now = clock.monotonicMs()
            XCTAssertGreaterThanOrEqual(now, last)
            last = now
        }
        let before = clock.monotonicMs()
        Thread.sleep(forTimeInterval: 0.05)
        let after = clock.monotonicMs()
        XCTAssertGreaterThanOrEqual(after - before, 40, "it follows real time")
        XCTAssertLessThan(after - before, 10_000)
        XCTAssertLessThan(clock.monotonicMs(), clock.nowMs() / 2, "its origin is not the epoch: only differences mean anything")
    }

    /// The test clock keeps the two apart the way a real device does when its wall clock is set: time passes on both, a step
    /// moves the wall clock only.
    func testTheTestClockMovesTheWallClockWithoutTheMonotonicOne() {
        let clock = XferManualClock(startMs: 1_700_000_000_000, monotonicStartMs: 5_000)
        clock.advance(ms: 250)
        XCTAssertEqual(clock.nowMs(), 1_700_000_000_250)
        XCTAssertEqual(clock.monotonicMs(), 5_250)
        clock.stepWall(byMs: -3_600_000)
        XCTAssertEqual(clock.nowMs(), 1_700_000_000_250 - 3_600_000)
        XCTAssertEqual(clock.monotonicMs(), 5_250, "a wall clock set back does not move the monotonic one")
        clock.advance(ms: 10)
        XCTAssertEqual(clock.monotonicMs(), 5_260)
    }
}

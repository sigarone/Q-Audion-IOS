import XCTest
@testable import QAudionEngine

/// The HTTP of the parts protocol as pure functions: how a typed request becomes a path, headers and a JSON body, and how an
/// answer becomes a typed value or a `FileV2ServerError`. The JSON used here is the one of docs/FILES_V2_PARTS_PROTOCOL.md.
final class FileV2HTTPWireTests: XCTestCase {

    private let obj = "0a1b2c3d-0000-4000-8000-123456789abc"

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Requests

    func test_anObjectPathIsBuiltOnlyForTheServersOwnIdShape() {
        XCTAssertEqual(FileV2HTTPWire.objectPath(obj), "/api/v1/files/v2/" + obj)
        XCTAssertEqual(FileV2HTTPWire.objectPath(obj, "/parts/3"), "/api/v1/files/v2/" + obj + "/parts/3")
        XCTAssertNil(FileV2HTTPWire.objectPath(obj.uppercased()))          // the server's ids are lowercase
        XCTAssertNil(FileV2HTTPWire.objectPath("../../etc/passwd"))
        XCTAssertNil(FileV2HTTPWire.objectPath(obj + "/../x"))
        XCTAssertNil(FileV2HTTPWire.objectPath(String(obj.dropLast())))
        XCTAssertNil(FileV2HTTPWire.objectPath(""))
    }

    func test_theHeadersOfADownloadCarryTheTokenAndTheRange() {
        let auth = FileV2DownloadAuth(v: String(repeating: "ab", count: 32), expMs: 1_800_000_000_000, max: 30)
        let headers = FileV2HTTPWire.downloadHeaders(from: 64, toInclusive: 8_388_799, token: auth, waitSeconds: 0)
        XCTAssertEqual(headers["Range"], "bytes=64-8388799")
        XCTAssertEqual(headers["X-Download-Token"], auth.v)
        XCTAssertEqual(headers["X-Download-Expires-Ms"], "1800000000000")
        XCTAssertEqual(headers["X-Download-Max-Uses"], "30")
        XCTAssertNil(headers["Prefer"])
        XCTAssertEqual(FileV2HTTPWire.downloadHeaders(from: 0, toInclusive: 63, token: nil, waitSeconds: 5)["Prefer"], "wait=5")
        XCTAssertNil(FileV2HTTPWire.downloadHeaders(from: 0, toInclusive: 63, token: nil, waitSeconds: 0)["X-Download-Token"])
    }

    func test_theContentDigestIsRFC9530() {
        XCTAssertEqual(FileV2HTTPWire.contentDigest(Data([1, 2, 3])), "sha-256=:AQID:")
    }

    func test_theCreateBodyHasTheServersMembers() throws {
        let request = FileV2CreateRequest(blobLength: 12_345_678, head: Data(repeating: 9, count: 64),
                                          token: .forRecipient("user-b", maxUses: 30))
        let body = try object(try FileV2HTTPWire.createBody(request))
        XCTAssertEqual(body["blob_len"] as? Int64, 12_345_678)
        XCTAssertEqual(body["part_size"] as? Int, FileV2Wire.partSize)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(body["head"] as? String)), Data(repeating: 9, count: 64))
        let token = try XCTUnwrap(body["token"] as? [String: Any])
        XCTAssertEqual(token["recipient_user_id"] as? String, "user-b")
        XCTAssertEqual(token["max_uses"] as? Int, 30)
        XCTAssertNil(token["group_id"])
        // no mime and no digest of the file: the server refuses unknown members
        XCTAssertNil(body["mime"])
        XCTAssertNil(body["sha256_b64"])
    }

    func test_theListQueryEscapesTheCursor() {
        XCTAssertEqual(FileV2HTTPWire.listQuery(limit: nil, after: nil), "state=unfinished")
        XCTAssertEqual(FileV2HTTPWire.listQuery(limit: 100, after: nil), "state=unfinished&limit=100")
        XCTAssertEqual(FileV2HTTPWire.listQuery(limit: 20, after: "a b&c"), "state=unfinished&limit=20&after=a%20b%26c")
    }

    func test_theTotalLengthComesFromContentRange() {
        XCTAssertEqual(FileV2HTTPWire.totalLength(ofContentRange: "bytes 0-63/12345"), 12345)
        XCTAssertNil(FileV2HTTPWire.totalLength(ofContentRange: "bytes 0-63/*"))
        XCTAssertNil(FileV2HTTPWire.totalLength(ofContentRange: "bytes 0-63/12x"))
        XCTAssertNil(FileV2HTTPWire.totalLength(ofContentRange: "nonsense"))
    }

    // MARK: Answers

    func test_aCreateAnswerBecomesATypedValue_andAMissingFieldIsMalformed() throws {
        let created = try FileV2HTTPWire.parseCreated(json("""
            {"obj":"\(obj)","blob_len":12345678,"part_size":8388736,"parts":2,"parallelism":6,"max_parallelism":8,
             "token":{"v":"\(String(repeating: "cd", count: 32))","exp":1800000000000,"max":30,"scope":"user"}}
            """))
        XCTAssertEqual(created.obj, obj)
        XCTAssertEqual(created.blobLength, 12_345_678)
        XCTAssertEqual(created.parts, 2)
        XCTAssertEqual(created.token?.max, 30)
        XCTAssertEqual(created.token?.exp, 1_800_000_000_000)
        XCTAssertFalse(created.existing)

        let resumed = try FileV2HTTPWire.parseCreated(json("""
            {"obj":"\(obj)","blob_len":9,"part_size":8388736,"parts":1,"parallelism":6,"max_parallelism":8,
             "existing":true,"received":1,"complete":true}
            """))
        XCTAssertTrue(resumed.existing)
        XCTAssertTrue(resumed.complete)
        XCTAssertEqual(resumed.received, 1)
        XCTAssertNil(resumed.token)

        XCTAssertThrowsError(try FileV2HTTPWire.parseCreated(json(#"{"obj":"x"}"#))) {
            XCTAssertEqual($0 as? FileV2WireFormatError, .malformedAnswer)
        }
        XCTAssertThrowsError(try FileV2HTTPWire.parseCreated(json("not json")))
    }

    func test_aBooleanIsNotANumber() {
        #if canImport(Darwin)
        // the check rests on CoreFoundation's boolean type (the Linux scratch harness has none)
        XCTAssertThrowsError(try FileV2HTTPWire.parsePut(json(#"{"part":true,"duplicate":false,"received":1,"parts":1}"#)))
        #endif
        XCTAssertNoThrow(try FileV2HTTPWire.parsePut(json(#"{"part":0,"duplicate":false,"received":1,"parts":1}"#)))
    }

    func test_aPartsMapIsDecodedAndChecked() throws {
        // parts 0 and 2 of 3 received: bitmap 0b101
        let map = try FileV2HTTPWire.parsePartsMap(json("""
            {"blob_len":20000000,"part_size":8388736,"parts":3,"received":2,"complete":false,"map":"BQ=="}
            """))
        XCTAssertEqual(map.bits, [true, false, true])
        XCTAssertEqual(map.missing, [1])
        // a count that disagrees with the bits is a protocol violation, not data
        XCTAssertThrowsError(try FileV2HTTPWire.parsePartsMap(json("""
            {"blob_len":20000000,"part_size":8388736,"parts":3,"received":3,"complete":false,"map":"BQ=="}
            """))) { XCTAssertEqual($0 as? FileV2WireFormatError, .invalidPartsMap) }
    }

    func test_anErrorAnswerKeepsTheStatusTheCodeTheWaitAndTheNumbers() {
        let quota = FileV2HTTPWire.parseError(
            status: 413, body: json(#"{"error":"quota_exceeded","message":"x","used":100,"limit":200}"#),
            retryAfterHeader: nil, nowMs: 0)
        XCTAssertEqual(quota.status, 413)
        XCTAssertEqual(quota.code, "quota_exceeded")
        XCTAssertEqual(quota.details.used, 100)
        XCTAssertEqual(quota.details.limit, 200)

        let busy = FileV2HTTPWire.parseError(status: 429, body: json(#"{"error":"part_busy"}"#), retryAfterHeader: "2", nowMs: 0)
        XCTAssertEqual(busy.retryAfter, 2)

        let incomplete = FileV2HTTPWire.parseError(
            status: 409, body: json(#"{"error":"incomplete","parts":4,"missing":[1,3]}"#), retryAfterHeader: nil, nowMs: 0)
        XCTAssertEqual(incomplete.missing, [1, 3])
    }

    func test_anAnswerThatIsNotTheProtocols_neverPutsItsTextInTheError() {
        let proxy = FileV2HTTPWire.parseError(status: 502, body: json("<html>Bad gateway token=SECRET</html>"),
                                              retryAfterHeader: nil, nowMs: 0)
        XCTAssertEqual(proxy.code, "http_502")
        XCTAssertFalse(String(describing: proxy).contains("SECRET"))

        let hostile = FileV2HTTPWire.parseError(status: 400, body: json(#"{"error":"Bad Code With Spaces & secrets"}"#),
                                                retryAfterHeader: nil, nowMs: 0)
        XCTAssertEqual(hostile.code, "invalid_code")
    }
}

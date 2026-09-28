import XCTest
@testable import QAudionEngine

/// W-LIVELOGOFFMAIN (2026-09-21) — golden tests for the W417 chunk format. The blob was
/// moved out of `LiveLogStreamer` unchanged; a server-side shipper parses it, so these
/// pin the exact bytes: a header JSON line, then `{"ts","lvl","tag","msg"}` lines, each
/// newline-terminated, in a file named `qaudion-live-...`.
final class LiveLogBlobTests: XCTestCase {

    // MARK: - Escaping

    func test_escapeJsonHandlesEveryCharacterTheShipperEverEscaped() {
        let input = "a\\b\"c\nd\re\tf"
        let expected = "a\\\\b\\\"c\\nd\\re\\tf"
        XCTAssertEqual(LiveLogBlob.escapeJson(input), expected)
    }

    func test_escapeJsonLeavesPlainAndNonAsciiTextAlone() {
        XCTAssertEqual(LiveLogBlob.escapeJson("rx=1 tx=2 [call] caff\u{E8}"), "rx=1 tx=2 [call] caff\u{E8}")
    }

    // MARK: - One log line

    func test_jsonLineIsExactlyTheOldShape() {
        let line = LiveLogBlob.jsonLine(timestamp: "2026-09-20T08:24:48.123Z",
                                        levelInitial: "I",
                                        tag: "call",
                                        message: "rx=1")
        XCTAssertEqual(line, #"{"ts":"2026-09-20T08:24:48.123Z","lvl":"I","tag":"call","msg":"rx=1"}"#)
    }

    func test_jsonLineEscapesTagAndMessageButNotTimestampOrLevel() {
        let line = LiveLogBlob.jsonLine(timestamp: "T",
                                        levelInitial: "W",
                                        tag: "a\"b",
                                        message: "line1\nline2 \"quoted\" back\\slash")
        XCTAssertEqual(line, #"{"ts":"T","lvl":"W","tag":"a\"b","msg":"line1\nline2 \"quoted\" back\\slash"}"#)
    }

    func test_aJsonLineParsesAsJsonWithTheFourKeysTheShipperReads() throws {
        let message = "tricky: \"q\" \\ \n \r \t end"
        let line = LiveLogBlob.jsonLine(timestamp: "2026-09-20T08:24:48.123Z",
                                        levelInitial: "E",
                                        tag: "net",
                                        message: message)
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let object = try XCTUnwrap(parsed as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["ts", "lvl", "tag", "msg"]))
        XCTAssertEqual(object["msg"] as? String, message)
        XCTAssertEqual(object["tag"] as? String, "net")
        XCTAssertEqual(object["lvl"] as? String, "E")
    }

    // MARK: - Header

    func test_headerIsExactlyTheOldShape() {
        let header = LiveLogBlob.header(session: "s-1",
                                        model: "iPhone",
                                        os: "ios-17.5",
                                        net: "WIFI",
                                        metered: false,
                                        appVer: "1.0.1180")
        XCTAssertEqual(header, #"{"type":"header","session":"s-1","model":"iPhone","brand":"Apple","os":"ios-17.5","net":"WIFI","metered":false,"app_ver":"1.0.1180"}"#)
    }

    func test_headerWritesMeteredAsABareJsonBoolean() {
        let header = LiveLogBlob.header(session: "s", model: "m", os: "o", net: "CELLULAR", metered: true, appVer: "v")
        XCTAssertTrue(header.contains(#""metered":true,"#))
    }

    // MARK: - Whole chunk

    func test_chunkIsTheHeaderThenEachLineNewlineTerminated() {
        let header = #"{"type":"header"}"#
        let lines = [#"{"a":1}"#, #"{"b":2}"#]
        let data = LiveLogBlob.chunkData(header: header, lines: lines, maxBytes: 65_536)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text, "{\"type\":\"header\"}\n{\"a\":1}\n{\"b\":2}\n")
    }

    func test_aChunkWithNoLinesIsJustTheHeaderLine() {
        let data = LiveLogBlob.chunkData(header: "H", lines: [], maxBytes: 1_000)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "H\n")
    }

    func test_aChunkExactlyAtTheCapIsNotTruncated() {
        // "H\n" + 97 x + "\n" = 2 + 97 + 1 = 100 bytes.
        let line = String(repeating: "x", count: 97)
        let data = LiveLogBlob.chunkData(header: "H", lines: [line], maxBytes: 100)
        XCTAssertEqual(data.count, 100)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("[livelog-truncated]"))
    }

    func test_anOversizeChunkIsCutAndMarkedTheWayItAlwaysWas() {
        let line = String(repeating: "x", count: 200)
        let data = LiveLogBlob.chunkData(header: "H", lines: [line], maxBytes: 100)
        let marker = Data(LiveLogBlob.truncationMarker.utf8)
        // 100 - 64 = 36 bytes of content, then the marker.
        XCTAssertEqual(data.count, 36 + marker.count)
        XCTAssertEqual(data.suffix(marker.count), marker)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("H\n" + String(repeating: "x", count: 34)))
        XCTAssertEqual(LiveLogBlob.truncationMarker, "\n[livelog-truncated]\n")
    }

    func test_linesChosenWithTheBudgetAlwaysFitTheCap() {
        let header = LiveLogBlob.header(session: "0123456789abcdef", model: "iPhone", os: "ios-17.5",
                                        net: "WIFI", metered: false, appVer: "1.0.1180")
        var backlog = LiveLogBacklog(maxEntries: 1_000, maxBytes: 1_000_000)
        for seq in 0..<400 {
            let line = LiveLogBlob.jsonLine(timestamp: "2026-09-20T08:24:48.123Z", levelInitial: "I",
                                            tag: "call", message: "RX playout: pu=\(seq) un=1 ov=0 hd=0 cc=1 dp=3")
            backlog.append(seq: Int64(seq), line: line)
        }
        let maxBytes = 8_192
        let budget = LiveLogBlob.linesByteBudget(header: header, maxBytes: maxBytes)
        let batch = backlog.peekBatch(maxLines: 256, byteBudget: budget)
        XCTAssertNotNil(batch)
        let data = LiveLogBlob.chunkData(header: header, lines: batch?.lines ?? [], maxBytes: maxBytes)
        XCTAssertLessThanOrEqual(data.count, maxBytes)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("[livelog-truncated]"),
                       "a chunk built from a budgeted batch is never cut mid-line")
        XCTAssertGreaterThan(batch?.lines.count ?? 0, 1)
    }

    func test_linesByteBudgetLeavesRoomForTheHeaderAndItsNewline() {
        XCTAssertEqual(LiveLogBlob.linesByteBudget(header: "0123456789", maxBytes: 100), 89)
        XCTAssertEqual(LiveLogBlob.linesByteBudget(header: "0123456789", maxBytes: 5), 0)
    }

    // MARK: - File name

    func test_filenameFollowsTheQaudionLivePattern() {
        XCTAssertEqual(LiveLogBlob.filename(userTag: "ab12cd34", session: "sess-1", seq: 7),
                       "qaudion-live-ab12cd34-sess-1-000007.log")
        XCTAssertEqual(LiveLogBlob.filename(userTag: "ab12cd34", session: "sess-1", seq: 1_234_567),
                       "qaudion-live-ab12cd34-sess-1-1234567.log")
    }

    func test_zeroPadPadsToTheWidthAndNeverTruncates() {
        XCTAssertEqual(LiveLogBlob.zeroPad(0, width: 6), "000000")
        XCTAssertEqual(LiveLogBlob.zeroPad(42, width: 6), "000042")
        XCTAssertEqual(LiveLogBlob.zeroPad(123_456, width: 6), "123456")
        XCTAssertEqual(LiveLogBlob.zeroPad(9_999_999, width: 6), "9999999")
    }
}

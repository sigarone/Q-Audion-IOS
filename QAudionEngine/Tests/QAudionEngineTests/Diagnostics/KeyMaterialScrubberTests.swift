import XCTest
@testable import QAudionEngine

/// W-KEYSCRUB (2026-09-21) -- tests for the key-material scrub that sits in front of every log
/// consumer (`RuntimeLogSink.record`, `LogRedactor`). SYNTHETIC data only: lists such as
/// 1,2,3,...,32 and 200,...,231, never a real key.
///
/// The golden vectors in `key-material-scrub-vectors.json` are shared with the Python port
/// (`scripts/test_keymaterial_scrub_parity.py`): their expected texts were composed by hand from the
/// spec, so the Swift scanner, the Python port and the spec all have to agree on every one.
/// `vectors` are checked with `scrub` (one log entry), `lineVectors` with `scrubLines` (a text of
/// several lines, what the app calls).
///
/// String expectations are built with interpolation and typed `let`s, never with a chain of three
/// or more `+` inside an `XCTAssertEqual` (CLAUDE.md section 13: type-checker timeouts).
final class KeyMaterialScrubberTests: XCTestCase {

    private let marker: String = KeyMaterialScrubber.marker

    // MARK: - Helpers

    /// "from,from+1,...,to" joined with `separator`.
    private func list(_ from: Int, _ to: Int, separator: String = ",") -> String {
        var parts: [String] = []
        var n: Int = from
        while n <= to {
            parts.append(String(describing: n))
            n += 1
        }
        return parts.joined(separator: separator)
    }

    private func scrub(_ text: String) -> String {
        return KeyMaterialScrubber.scrub(text)
    }

    private func scrubLines(_ text: String) -> String {
        return KeyMaterialScrubber.scrubLines(text)
    }

    /// Independent reference for `scrubLines`: cut the text at every line feed BYTE, scrub each
    /// piece with `scrub`, join the pieces with a line feed.
    private func scrubEachLine(_ text: String) -> String {
        var pieces: [String] = []
        var current: [UInt8] = []
        for byte in text.utf8 {
            if byte == 0x0A {
                pieces.append(scrub(String(decoding: current, as: UTF8.self)))
                current = []
            } else {
                current.append(byte)
            }
        }
        pieces.append(scrub(String(decoding: current, as: UTF8.self)))
        return pieces.joined(separator: "\n")
    }

    private func kinds(_ text: String) -> [KeyMaterialScrubber.Kind] {
        return KeyMaterialScrubber.matches(in: text).map { $0.kind }
    }

    private func seconds(_ block: () -> Void) -> TimeInterval {
        let start = Date()
        block()
        return Date().timeIntervalSince(start)
    }

    // MARK: - (a) derived_key

    func test_derivedKeyRealShapeIsScrubbedAndTheWordStays() {
        let line: String = "derived_key [\(list(1, 32))] len 32"
        XCTAssertEqual(scrub(line), "derived_key \(marker)")
        XCTAssertEqual(kinds(line), [.derivedKey])
    }

    func test_derivedKeyWithATrailingCommaAndWithSpacesAfterCommas() {
        let spacedList: String = list(1, 32, separator: ", ")
        let trailing: String = "derived_key [\(list(1, 32)),] len 32"
        let spaced: String = "derived_key [\(spacedList)] len 32"
        XCTAssertEqual(scrub(trailing), "derived_key \(marker)")
        XCTAssertEqual(scrub(spaced), "derived_key \(marker)")
    }

    func test_derivedKeyIsCaseInsensitiveAndKeepsItsSeparator() {
        let upper: String = "DERIVED_KEY: [\(list(1, 32))] len 32"
        XCTAssertEqual(scrub(upper), "DERIVED_KEY: \(marker)")
        XCTAssertEqual(scrub("DeRiVeD_kEy [1,2,3]"), "DeRiVeD_kEy \(marker)")
        XCTAssertEqual(scrub("call ok derived_key=abc123 rest"), "call ok derived_key=\(marker)")
    }

    func test_derivedKeyWithNothingAfterItIsLeftAlone() {
        XCTAssertEqual(scrub("derived_key"), "derived_key")
        XCTAssertEqual(scrub("got derived_key "), "got derived_key ")
    }

    func test_derivedKeyTakesTheRestOfTheTextEvenOverSeveralLines() {
        // `scrub` is for ONE log entry: the rest of the TEXT goes. (The app uses `scrubLines`.)
        XCTAssertEqual(scrub("first\nderived_key [1,2,3]\nlast"), "first\nderived_key \(marker)")
    }

    // MARK: - (b) secret / slat / salt

    func test_secretAndSlatRealShapeKeepsTheLengths() {
        let line: String = "(x.cc:118): secret [\(list(1, 32))] len 32 slat [\(list(1, 16))] len 16"
        let expected: String = "(x.cc:118): secret \(marker) len 32 slat \(marker) len 16"
        XCTAssertEqual(scrub(line), expected)
        XCTAssertEqual(kinds(line), [.keywordList, .keywordList])
    }

    func test_anEmptySlatGroupIsNotKeyMaterialAndStaysReadable() {
        let line: String = "(x.cc:118): secret [\(list(1, 32))] len 32 slat << [] len 0"
        let expected: String = "(x.cc:118): secret \(marker) len 32 slat << [] len 0"
        XCTAssertEqual(scrub(line), expected)
        XCTAssertEqual(scrub("salt [] len 0"), "salt [] len 0")
        XCTAssertEqual(scrub("salt [  ] len 0"), "salt [  ] len 0")
    }

    func test_keywordGroupsMayBeParenthesisedNestedOrUnclosed() {
        let parenthesised: String = "SECRET=(\(list(1, 10))) ok"
        XCTAssertEqual(scrub(parenthesised), "SECRET=\(marker) ok")
        XCTAssertEqual(scrub("secret [[1,2],[3,4]] len 4"), "secret \(marker) len 4")
        let unclosed: String = "(x.cc:118): secret [\(list(1, 17))"
        XCTAssertEqual(scrub(unclosed), "(x.cc:118): secret \(marker)")
        XCTAssertEqual(scrub("secret [abc def"), "secret \(marker)")
    }

    func test_aKeywordWithoutAdjacentGroupIsLeftAlone() {
        XCTAssertEqual(scrub("secret handshake ok"), "secret handshake ok")
        XCTAssertEqual(scrub("secretary [1,2,3]"), "secretary [1,2,3]")
        XCTAssertEqual(scrub("secret len 32 [1,2,3]"), "secret len 32 [1,2,3]")
    }

    // MARK: - (c) lists of 8 or more integers

    func test_aListOfEightIsScrubbedAndAListOfSevenIsNot() {
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8] y"), "x \(marker) y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7] y"), "x [1,2,3,4,5,6,7] y")
        XCTAssertEqual(kinds("x [1,2,3,4,5,6,7,8] y"), [.intList])
    }

    func test_parenthesisedAndSemicolonSeparatedLists() {
        let semicolons: String = list(1, 32, separator: ";")
        let parenthesised: String = "x (\(list(1, 32))) y"
        let separated: String = "x [\(semicolons)] y"
        XCTAssertEqual(scrub(parenthesised), "x \(marker) y")
        XCTAssertEqual(scrub(separated), "x \(marker) y")
        XCTAssertEqual(scrub("x [1,2;3, 4 ;5 , 6,7;8] y"), "x \(marker) y")
    }

    func test_optionalSpacesAndATrailingSeparatorAreAccepted() {
        XCTAssertEqual(scrub("x [ 1, 2, 3, 4, 5, 6, 7, 8 ] y"), "x \(marker) y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8,] y"), "x \(marker) y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8;] y"), "x \(marker) y")
    }

    func test_onlyDecimalIntegersUpTo255CountAsBytes() {
        XCTAssertEqual(scrub("x [0,255,0,255,0,255,0,255] y"), "x \(marker) y")
        XCTAssertEqual(scrub("x [001,002,003,004,005,006,007,008] y"), "x \(marker) y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,256] y"), "x [1,2,3,4,5,6,7,256] y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,0008] y"), "x [1,2,3,4,5,6,7,0008] y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,-8] y"), "x [1,2,3,4,5,6,7,-8] y")
        XCTAssertEqual(scrub("x [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5] y"), "x [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5] y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8,ab] y"), "x [1,2,3,4,5,6,7,8,ab] y")
    }

    func test_policyAListOfEightSmallNumbersIsScrubbedInAnyContext() {
        // Over-scrubbing is deliberate: the scrub cannot know what the numbers mean.
        XCTAssertEqual(scrub("histogram buckets [1,2,3,4,5,6,7,8] ok"), "histogram buckets \(marker) ok")
    }

    func test_severalAndTouchingListsGetOneMarkerEach() {
        let expected: String = "a \(marker) b \(marker) c"
        XCTAssertEqual(scrub("a [1,2,3,4,5,6,7,8] b (9,10,11,12,13,14,15,16) c"), expected)
        XCTAssertEqual(scrub("[1,2,3,4,5,6,7,8][1,2,3,4,5,6,7,8]"), marker)
    }

    // MARK: - (e) a key line split in two by the stdout tee

    func test_theTailOfASplitKeyLineIsScrubbed() {
        let tailKey: String = list(18, 32)
        XCTAssertEqual(scrub("\(tailKey)] len 32 slat << [] len 0"), "\(marker) len 32 slat << [] len 0")
        XCTAssertEqual(scrub(",18,19,20] len 32"), "\(marker) len 32")
        XCTAssertEqual(scrub("5,17,200,] len 32 slat << [] len 0"), "\(marker) len 32 slat << [] len 0")
        XCTAssertEqual(kinds("\(tailKey)] len 32"), [.tailFragment])
    }

    func test_theHeadOfASplitKeyLineIsScrubbedEvenWithoutAKeyword() {
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7"), "x \(marker)")
        XCTAssertEqual(scrub("index [1"), "index \(marker)")
        XCTAssertEqual(scrub("x ["), "x [")
        XCTAssertEqual(scrub("x [ab"), "x [ab")
    }

    func test_textThatOnlyLooksLikeATailIsLeftAlone() {
        XCTAssertEqual(scrub("12,34,56 not closed"), "12,34,56 not closed")
        XCTAssertEqual(scrub("300,4] foo"), "300,4] foo")
        XCTAssertEqual(scrub("text 18,19,20] len 32"), "text 18,19,20] len 32")
        XCTAssertEqual(scrub("32 slat << [] len 0"), "32 slat << [] len 0")
    }

    /// Copilot follow-up to #109: `)` is now accepted symmetrically with `]` as a tail-fragment
    /// closing delimiter, so a parenthesised key list split by the stdout tee right before its
    /// last value (`32) len 32`, the shape reported against #109) is caught too. The accepted
    /// price (this file's over-scrubbing policy) is that a bare numbered item or the tail of a
    /// `(file.cc:118): ...` prefix -- both used to survive untouched -- are now treated the same
    /// way as a real tail fragment.
    func test_aParenthesisedTailFragmentIsNowScrubbedSymmetricallyWithBrackets() {
        XCTAssertEqual(scrub("32) len 32"), "\(marker) len 32")
        XCTAssertEqual(scrub("1) first item"), "\(marker) first item")
        XCTAssertEqual(scrub("118): voice send channel options"), "\(marker): voice send channel options")
        XCTAssertEqual(kinds("32) len 32"), [.tailFragment])
    }

    /// The real shapes cut at EVERY byte offset, the way a 4096-byte pipe read cuts them: no key
    /// number may survive in either half.
    func test_aKeyLineCutAtAnyOffsetLeaksNothing() {
        let key: String = list(200, 231)
        let salt: String = list(200, 215)
        var shapes: [String] = []
        shapes.append("derived_key [\(key)] len 32")
        shapes.append("(x.cc:118): secret [\(key)] len 32 slat [\(salt)] len 16")
        shapes.append("(x.cc:118): secret [\(key)] len 32 slat << [] len 0")
        shapes.append("key bytes [\(key)] len 32")
        for line in shapes {
            let bytes: [UInt8] = Array(line.utf8)
            var offset: Int = 0
            while offset <= bytes.count {
                let head: String = String(decoding: bytes[0..<offset], as: UTF8.self)
                let tail: String = String(decoding: bytes[offset..<bytes.count], as: UTF8.self)
                let joined: String = "\(scrub(head))\n\(scrub(tail))"
                var number: Int = 200
                while number <= 231 {
                    let digits: String = String(describing: number)
                    let message: String = "number \(digits) survived a cut at offset \(offset) of: \(line)"
                    XCTAssertFalse(joined.contains(digits), message)
                    number += 1
                }
                offset += 1
            }
        }
    }

    // MARK: - (d) hex bytes

    func test_eightHexBytesWithSpacesOrColonsAreScrubbed() {
        XCTAssertEqual(scrub("aa bb cc dd ee ff 00 11"), marker)
        XCTAssertEqual(scrub("aa:bb:cc:dd:ee:ff:00:11"), marker)
        XCTAssertEqual(scrub("key: AA BB CC DD EE FF 00 11 end"), "key: \(marker) end")
        XCTAssertEqual(scrub("aa:bb cc:dd ee:ff 00:11"), marker)
        XCTAssertEqual(kinds("aa bb cc dd ee ff 00 11"), [.hexRun])
    }

    /// Copilot follow-up to #109: the 256 KiB scan cap can fall inside a hex key with fewer than
    /// `minHexBytes` pairs visible before it (here 7 of 8). `matchHexRun` used to see only those 7
    /// pairs, return -1 (not sensitive), and leave them in the output while only the separate
    /// `.overlong` span (`limit..<n`) got redacted -- so 7 of the 8 key bytes survived. Fail closed
    /// instead: the visible prefix now merges into one marker with the overlong tail.
    func test_hexRunCutAtTheCapBoundaryWithFewerThanEightVisiblePairsIsStillRedacted() {
        let cap: Int = KeyMaterialScrubber.maxScanBytes
        let hexRun: String = "aa bb cc dd ee ff 00 11"   // 8 pairs; the cut below leaves 7 visible
        let eighthPairOffset: Int = 21                    // index of "11" (the 8th pair) in hexRun
        // A non-hex separator (space) right before the run, so the hex-run scan actually starts
        // at "aa" (a token boundary) instead of being swallowed into the "x" padding as one run.
        let padding: String = String(repeating: "x", count: cap - eighthPairOffset - 1) + " "
        let text: String = padding + hexRun
        XCTAssertGreaterThan(text.utf8.count, cap)
        let result: String = scrub(text)
        XCTAssertEqual(result, padding + marker)
        XCTAssertFalse(result.contains("aa"))
        XCTAssertFalse(result.contains("11"))
    }

    func test_hexLookAlikesAreLeftAlone() {
        XCTAssertEqual(scrub("aa bb cc dd ee ff 00"), "aa bb cc dd ee ff 00")
        XCTAssertEqual(scrub("02:42:ac:11:00:02"), "02:42:ac:11:00:02")
        XCTAssertEqual(scrub("AA:BB:CC:DD:EE:FF-tsco name = x"), "AA:BB:CC:DD:EE:FF-tsco name = x")
        XCTAssertEqual(scrub("2001:0db8:85a3:0000:0000:8a2e:0370:7334"), "2001:0db8:85a3:0000:0000:8a2e:0370:7334")
        XCTAssertEqual(scrub("aabbccddeeff0011"), "aabbccddeeff0011")
        XCTAssertEqual(scrub("aa bb cc dd ee ff 00 112 x"), "aa bb cc dd ee ff 00 112 x")
        XCTAssertEqual(scrub("0xaa 0xbb 0xcc 0xdd 0xee 0xff 0x00 0x11"), "0xaa 0xbb 0xcc 0xdd 0xee 0xff 0x00 0x11")
    }

    // MARK: - Text that must never change

    func test_ordinaryLogTextIsReturnedUnchanged() {
        let clean: [String] = [
            "2026-09-21T13:54:00.123Z rx=12 tx=13",
            "app 1.0.1180 build 1180 v1.0.1181",
            "peer 1.2.3.4:5060 via 192.168.0.1",
            "call 3f2504e0-4f89-11d3-9a0c-0305e82c3301 ended",
            "blob SGVsbG8gV29ybGQhIFRoaXMgaXMgYmFzZTY0IHRleHQ= ok",
            "caff\u{E8} \u{2615} \u{65E5}\u{672C}\u{8A9E} [1,2,3] \u{1F680} ok",
            "",
            "   ",
            "[call] [rekey] (x.cc:118): started",
            "QAudionApp + 123456 at 0x0000000102abc000",
            "heartbeat rx_frames_d=250 tx_frames_d=250 jb_depth_now=3 iat_max_ms=40",
            "[alpha, beta, gamma]",
            "x [] y () z",
            "channels [0,1] ok"
        ]
        for line in clean {
            XCTAssertEqual(scrub(line), line)
            XCTAssertEqual(scrubLines(line), line)
            XCTAssertTrue(KeyMaterialScrubber.matches(in: line).isEmpty)
        }
    }

    func test_unicodeAroundAMatchSurvivesIntact() {
        let input: String = "h\u{E9}llo [1,2,3,4,5,6,7,8] w\u{F6}rld \u{1F680}"
        let expected: String = "h\u{E9}llo \(marker) w\u{F6}rld \u{1F680}"
        XCTAssertEqual(scrub(input), expected)
        XCTAssertEqual(scrub("\u{65E5}\u{672C} derived_key [1,2,3]"), "\u{65E5}\u{672C} derived_key \(marker)")
    }

    // MARK: - Marker, idempotence

    func test_theMarkerIsNeverMatchedAgain() {
        XCTAssertEqual(scrub(marker), marker)
        XCTAssertEqual(scrub("x \(marker) y"), "x \(marker) y")
        XCTAssertEqual(scrub("derived_key \(marker)"), "derived_key \(marker)")
        XCTAssertEqual(scrub("secret \(marker) len 32"), "secret \(marker) len 32")
    }

    func test_scrubbingTwiceEqualsScrubbingOnce() throws {
        let file = try loadVectors()
        for vector in file.vectors {
            let once = scrub(vector.input)
            XCTAssertEqual(scrub(once), once, vector.name)
        }
        let everyVector: [Vector] = file.vectors + file.lineVectors
        for vector in everyVector {
            let once: String = scrubLines(vector.input)
            XCTAssertEqual(scrubLines(once), once, vector.name)
        }
    }

    // MARK: - scrubLines: a text of several lines (what the app calls)

    func test_scrubLinesKeepsTheLinesAroundAKeyLine() {
        XCTAssertEqual(scrubLines("first\nderived_key [1,2,3]\nlast"), "first\nderived_key \(marker)\nlast")
        let realShape: String = "ts [INFO] [stdout] derived_key [\(list(1, 32))] len 32\nnext row"
        XCTAssertEqual(scrubLines(realShape), "ts [INFO] [stdout] derived_key \(marker)\nnext row")
        let twoKeyRows: String = "derived_key [1,2,3]\nsecret [4,5,6] len 3\n"
        XCTAssertEqual(scrubLines(twoKeyRows), "derived_key \(marker)\nsecret \(marker) len 3\n")
    }

    /// The regression the reviewers found: `ReportCrypto.buildDiagSummary` runs the redactor on the
    /// whole 2-minute `recentLogsAsString` blob, every row of which was already scrubbed at ring
    /// entry. The blob must come back unchanged and its last rows must still be there.
    func test_aBlobOfScrubbedRowsIsAFixedPointOfScrubLines() {
        let key: String = list(1, 32)
        let prefix: String = "2026-09-21T10:00:00.000Z [INFO] [stdout] "
        let entries: [String] = [
            "derived_key [\(key)] len 32",
            "rekey round 2 done",
            "(x.cc:118): secret [\(key)] len 32 slat << [] len 0",
            "secret [",
            "18,19,20,21] len 32",
            "media resumed"
        ]
        var rows: [String] = []
        var rawRows: [String] = []
        for entry in entries {
            rows.append(prefix + scrub(entry))
            rawRows.append(prefix + entry)
        }
        let blob: String = rows.joined(separator: "\n") + "\n"
        XCTAssertEqual(scrubLines(blob), blob)
        XCTAssertTrue(blob.hasSuffix("media resumed\n"))
        XCTAssertFalse(blob.contains("1,2,3"))
        XCTAssertFalse(blob.contains("18,19"))
        // what the 200-character diag summary keeps is the newest rows, not an old slice
        XCTAssertTrue(String(scrubLines(blob).suffix(200)).hasSuffix("media resumed\n"))

        // the same rows scrubbed for the first time, as one blob: key-free, nothing else lost
        let rawBlob: String = rawRows.joined(separator: "\n") + "\n"
        let once: String = scrubLines(rawBlob)
        XCTAssertFalse(once.contains("1,2,3"))
        XCTAssertTrue(once.contains("media resumed"))
        XCTAssertEqual(scrubLines(once), once)
    }

    func test_scrubLinesAnUnclosedKeywordGroupStaysInsideItsLine() {
        XCTAssertEqual(scrubLines("secret [\nnext line\nlast"), "secret [\nnext line\nlast")
        XCTAssertEqual(scrubLines("salt (\nfoo (bar\nlast"), "salt (\nfoo (bar\nlast")
        XCTAssertEqual(scrubLines("secret [1,2\nnext line"), "secret \(marker)\nnext line")
    }

    func test_scrubLinesCatchesAListCutByOneLineFeedAndKeepsTheLineFeeds() {
        XCTAssertEqual(scrubLines("x [1,2,3,4,5,6,7,\n8] y"), "x \(marker)\n\(marker) y")
        XCTAssertEqual(scrubLines("a\r\nsecret [1,2,3] len 3\r\nb\r\n"), "a\r\nsecret \(marker) len 3\r\nb\r\n")
        XCTAssertEqual(scrubLines("\n\n[1,2,3,4,5,6,7,8]\n\n"), "\n\n\(marker)\n\n")
        XCTAssertEqual(scrubLines("\n"), "\n")
        XCTAssertEqual(scrubLines(""), "")
    }

    func test_scrubLinesEqualsScrubOnEachLine() {
        let key: String = list(1, 32)
        let texts: [String] = [
            "a\nderived_key [1,2,3]\nb",
            "x [1,2,3,4,5,6,7,\n8] y",
            "\n\n",
            "",
            "salt (\nfoo\n",
            "secret [1,2\nnext\nlast",
            "a\r\nsecret [1,2,3] len 3\r\nb\r\n",
            "no key here\nat all\n",
            "h\u{E9}llo\nx [\(key)] w\u{F6}rld\n\u{1F680} ok",
            "\(key)] tail on the first row\nsecond row",
            "first row\n\(key)] tail on the second row\nthird row"
        ]
        for text in texts {
            XCTAssertEqual(scrubLines(text), scrubEachLine(text), text)
        }
    }

    func test_scrubLinesOfASingleLineIsScrub() throws {
        let file = try loadVectors()
        for vector in file.vectors where !vector.input.utf8.contains(0x0A) {
            XCTAssertEqual(scrubLines(vector.input), vector.expected, vector.name)
        }
    }

    func test_scrubLinesCapsEachLineNotTheWholeText() {
        let cap: Int = KeyMaterialScrubber.maxScanBytes
        let row: String = "2026-09-21T10:00:00.000Z [INFO] [call] media heartbeat rx_frames_d=250 tx_frames_d=250"
        let rowCount: Int = cap / (row.utf8.count + 1) + 50
        var rows: [String] = Array(repeating: row, count: rowCount)
        // a blob of short rows that is longer than the cap is not cut ...
        let plain: String = rows.joined(separator: "\n")
        XCTAssertGreaterThan(plain.utf8.count, cap)
        XCTAssertEqual(scrubLines(plain), plain)
        // ... and a key row at its very end is scrubbed while no row is lost
        rows.append("derived_key [\(list(1, 32))] len 32")
        rows.append("last row")
        var expectedRows: [String] = Array(repeating: row, count: rowCount)
        expectedRows.append("derived_key \(marker)")
        expectedRows.append("last row")
        XCTAssertEqual(scrubLines(rows.joined(separator: "\n")), expectedRows.joined(separator: "\n"))
    }

    func test_scrubLinesCutsAnOverlongRowOnItsOwn() {
        let cap: Int = KeyMaterialScrubber.maxScanBytes
        let overlong: String = String(repeating: "abcdefghij klm ", count: 20_000)   // 300000 bytes
        XCTAssertGreaterThan(overlong.utf8.count, cap)
        let blob: String = "before\n\(overlong)\nafter [\(list(1, 8))]\nlast"
        let head: String = String(overlong.prefix(cap))
        let expected: String = "before\n\(head)\(marker)\nafter \(marker)\nlast"
        XCTAssertEqual(scrubLines(blob), expected)
    }

    // MARK: - Bounded work

    func test_aTextLongerThanTheCapKeepsItsHeadAndLosesItsTail() {
        let cap: Int = KeyMaterialScrubber.maxScanBytes
        let clean: String = String(repeating: "abcdefghij klm ", count: 70_000)   // about 1 MB
        XCTAssertGreaterThan(clean.utf8.count, cap)
        let cleanExpected: String = "\(String(clean.prefix(cap)))\(marker)"
        XCTAssertEqual(scrub(clean), cleanExpected)

        // a key that starts after the cap is never looked at, and never survives
        let padding: String = String(repeating: "x", count: cap + 10)
        let keyAfterCap: String = "\(padding) derived_key [\(list(1, 32))] len 32"
        let scrubbedAfter: String = scrub(keyAfterCap)
        XCTAssertFalse(scrubbedAfter.contains("derived_key"))
        XCTAssertFalse(scrubbedAfter.contains("1,2,3"))
        XCTAssertTrue(scrubbedAfter.hasSuffix(marker))

        // a key inside the scanned part is still scrubbed
        let keyBeforeCap: String = "y [\(list(1, 32))] \(padding)"
        let scrubbedBefore: String = scrub(keyBeforeCap)
        let expectedPrefix: String = "y \(marker) "
        XCTAssertTrue(scrubbedBefore.hasPrefix(expectedPrefix))
        XCTAssertFalse(scrubbedBefore.contains("1,2,3"))
    }

    func test_theCapNeverCutsInsideAMultiByteCharacter() {
        let cap: Int = KeyMaterialScrubber.maxScanBytes
        // the 2-byte character straddles the cap: it goes, whole, with the tail
        let head: String = String(repeating: "a", count: cap - 1)
        let tail: String = String(repeating: "z", count: 10)
        let text: String = "\(head)\u{E9}\(tail)"
        let expected: String = "\(head)\(marker)"
        XCTAssertEqual(scrub(text), expected)
    }

    func test_aOneMegabyteLineIsScannedInBoundedTime() {
        let n: Int = 250_000
        var cases: [(String, String)] = []
        cases.append(("open brackets", String(repeating: "[1,2,3,4,5,6,7,", count: n / 15)))
        cases.append(("open parentheses", String(repeating: "(", count: n)))
        cases.append(("broken hex runs", String(repeating: "aa bb cc dd ee ff 00 zz ", count: n / 24)))
        cases.append(("secret [ repeated", String(repeating: "secret [", count: n / 8)))
        cases.append(("salt ] repeated", String(repeating: "salt ] ", count: n / 7)))
        cases.append(("digits", String(repeating: "1234567890", count: n / 10)))
        cases.append(("one megabyte, clean", String(repeating: "abcdefghij klm ", count: 70_000)))
        cases.append(("one megabyte, brackets", String(repeating: "[1,2,3,4,5,6,7,", count: 70_000)))
        for (name, text) in cases {
            var result: String = ""
            let took: TimeInterval = seconds { result = scrub(text) }
            // A quadratic scanner needs minutes here; a linear one needs milliseconds even unoptimised.
            XCTAssertLessThan(took, 10.0, name)
            XCTAssertLessThanOrEqual(result.utf8.count, 4 * KeyMaterialScrubber.maxScanBytes + 64, name)
        }
    }

    func test_scrubLinesIsLinearOnManyShortLines() {
        let n: Int = 250_000
        var cases: [(String, String)] = []
        cases.append(("secret [ on every line", String(repeating: "secret [\n", count: n / 9)))
        cases.append(("derived_key on every line", String(repeating: "derived_key [1,2,3]\n", count: n / 20)))
        cases.append(("open brackets, one per line", String(repeating: "[1,2,3,4,5,6,7,\n", count: n / 16)))
        cases.append(("tail fragments, one per line", String(repeating: "1]\n", count: n / 3)))
        cases.append(("line feeds only", String(repeating: "\n", count: n)))
        for (name, text) in cases {
            var result: String = ""
            let took: TimeInterval = seconds { result = scrubLines(text) }
            XCTAssertLessThan(took, 10.0, name)
            XCTAssertFalse(result.isEmpty, name)
        }
    }

    // MARK: - Shared golden vectors

    private struct Vector: Decodable {
        let name: String
        let input: String
        let expected: String
    }

    private struct VectorFile: Decodable {
        let schema: String
        let marker: String
        let vectors: [Vector]
        let lineVectors: [Vector]
    }

    private func loadVectors() throws -> VectorFile {
        guard let url = Bundle.module.url(forResource: "key-material-scrub-vectors", withExtension: "json") else {
            throw NSError(domain: "KeyMaterialScrubberTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "key-material-scrub-vectors.json not found in Bundle.module"
            ])
        }
        let data: Data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VectorFile.self, from: data)
    }

    func test_everySharedGoldenVectorMatches() throws {
        let file = try loadVectors()
        XCTAssertEqual(file.schema, "qaudion-key-material-scrub-vectors:1")
        XCTAssertEqual(file.marker, marker)
        XCTAssertGreaterThan(file.vectors.count, 100)
        for vector in file.vectors {
            XCTAssertEqual(scrub(vector.input), vector.expected, vector.name)
        }
    }

    func test_everySharedLineVectorMatches() throws {
        let file = try loadVectors()
        XCTAssertGreaterThan(file.lineVectors.count, 10)
        for vector in file.lineVectors {
            XCTAssertEqual(scrubLines(vector.input), vector.expected, vector.name)
            XCTAssertEqual(scrubLines(vector.expected), vector.expected, vector.name)
        }
    }
}

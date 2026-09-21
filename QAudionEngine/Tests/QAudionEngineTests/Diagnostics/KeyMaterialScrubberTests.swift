import XCTest
@testable import QAudionEngine

/// W-KEYSCRUB (2026-09-21) -- tests for the key-material scrub that sits in front of every log
/// consumer (`RuntimeLogSink.record`, `LogRedactor`). SYNTHETIC data only: lists such as
/// 1,2,3,...,32 and 200,...,231, never a real key.
///
/// The golden vectors in `key-material-scrub-vectors.json` are shared with the Python port
/// (`scripts/test_keymaterial_scrub_parity.py`): their expected texts were composed by hand from the
/// spec, so the Swift scanner, the Python port and the spec all have to agree on every one.
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
        let line = "derived_key [" + list(1, 32) + "] len 32"
        XCTAssertEqual(scrub(line), "derived_key " + marker)
        XCTAssertEqual(kinds(line), [.derivedKey])
    }

    func test_derivedKeyWithATrailingCommaAndWithSpacesAfterCommas() {
        XCTAssertEqual(scrub("derived_key [" + list(1, 32) + ",] len 32"), "derived_key " + marker)
        XCTAssertEqual(scrub("derived_key [" + list(1, 32, separator: ", ") + "] len 32"), "derived_key " + marker)
    }

    func test_derivedKeyIsCaseInsensitiveAndKeepsItsSeparator() {
        XCTAssertEqual(scrub("DERIVED_KEY: [" + list(1, 32) + "] len 32"), "DERIVED_KEY: " + marker)
        XCTAssertEqual(scrub("DeRiVeD_kEy [1,2,3]"), "DeRiVeD_kEy " + marker)
        XCTAssertEqual(scrub("call ok derived_key=abc123 rest"), "call ok derived_key=" + marker)
    }

    func test_derivedKeyWithNothingAfterItIsLeftAlone() {
        XCTAssertEqual(scrub("derived_key"), "derived_key")
        XCTAssertEqual(scrub("got derived_key "), "got derived_key ")
    }

    func test_derivedKeyTakesTheRestOfTheTextEvenOverSeveralLines() {
        XCTAssertEqual(scrub("first\nderived_key [1,2,3]\nlast"), "first\nderived_key " + marker)
    }

    // MARK: - (b) secret / slat / salt

    func test_secretAndSlatRealShapeKeepsTheLengths() {
        let line: String = "(x.cc:118): secret [\(list(1, 32))] len 32 slat [\(list(1, 16))] len 16"
        let expected: String = "(x.cc:118): secret \(marker) len 32 slat \(marker) len 16"
        XCTAssertEqual(scrub(line), expected)
        XCTAssertEqual(kinds(line), [.keywordList, .keywordList])
    }

    func test_anEmptySlatGroupIsNotKeyMaterialAndStaysReadable() {
        let line = "(x.cc:118): secret [" + list(1, 32) + "] len 32 slat << [] len 0"
        XCTAssertEqual(scrub(line), "(x.cc:118): secret " + marker + " len 32 slat << [] len 0")
        XCTAssertEqual(scrub("salt [] len 0"), "salt [] len 0")
        XCTAssertEqual(scrub("salt [  ] len 0"), "salt [  ] len 0")
    }

    func test_keywordGroupsMayBeParenthesisedNestedOrUnclosed() {
        XCTAssertEqual(scrub("SECRET=(" + list(1, 10) + ") ok"), "SECRET=" + marker + " ok")
        XCTAssertEqual(scrub("secret [[1,2],[3,4]] len 4"), "secret " + marker + " len 4")
        XCTAssertEqual(scrub("(x.cc:118): secret [" + list(1, 17)), "(x.cc:118): secret " + marker)
        XCTAssertEqual(scrub("secret [abc def"), "secret " + marker)
    }

    func test_aKeywordWithoutAdjacentGroupIsLeftAlone() {
        XCTAssertEqual(scrub("secret handshake ok"), "secret handshake ok")
        XCTAssertEqual(scrub("secretary [1,2,3]"), "secretary [1,2,3]")
        XCTAssertEqual(scrub("secret len 32 [1,2,3]"), "secret len 32 [1,2,3]")
    }

    // MARK: - (c) lists of 8 or more integers

    func test_aListOfEightIsScrubbedAndAListOfSevenIsNot() {
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8] y"), "x " + marker + " y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7] y"), "x [1,2,3,4,5,6,7] y")
        XCTAssertEqual(kinds("x [1,2,3,4,5,6,7,8] y"), [.intList])
    }

    func test_parenthesisedAndSemicolonSeparatedLists() {
        XCTAssertEqual(scrub("x (" + list(1, 32) + ") y"), "x " + marker + " y")
        XCTAssertEqual(scrub("x [" + list(1, 32, separator: ";") + "] y"), "x " + marker + " y")
        XCTAssertEqual(scrub("x [1,2;3, 4 ;5 , 6,7;8] y"), "x " + marker + " y")
    }

    func test_optionalSpacesAndATrailingSeparatorAreAccepted() {
        XCTAssertEqual(scrub("x [ 1, 2, 3, 4, 5, 6, 7, 8 ] y"), "x " + marker + " y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8,] y"), "x " + marker + " y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8;] y"), "x " + marker + " y")
    }

    func test_onlyDecimalIntegersUpTo255CountAsBytes() {
        XCTAssertEqual(scrub("x [0,255,0,255,0,255,0,255] y"), "x " + marker + " y")
        XCTAssertEqual(scrub("x [001,002,003,004,005,006,007,008] y"), "x " + marker + " y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,256] y"), "x [1,2,3,4,5,6,7,256] y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,0008] y"), "x [1,2,3,4,5,6,7,0008] y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,-8] y"), "x [1,2,3,4,5,6,7,-8] y")
        XCTAssertEqual(scrub("x [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5] y"), "x [1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5] y")
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7,8,ab] y"), "x [1,2,3,4,5,6,7,8,ab] y")
    }

    func test_policyAListOfEightSmallNumbersIsScrubbedInAnyContext() {
        // Over-scrubbing is deliberate: the scrub cannot know what the numbers mean.
        XCTAssertEqual(scrub("histogram buckets [1,2,3,4,5,6,7,8] ok"), "histogram buckets " + marker + " ok")
    }

    func test_severalAndTouchingListsGetOneMarkerEach() {
        let expected: String = "a \(marker) b \(marker) c"
        XCTAssertEqual(scrub("a [1,2,3,4,5,6,7,8] b (9,10,11,12,13,14,15,16) c"), expected)
        XCTAssertEqual(scrub("[1,2,3,4,5,6,7,8][1,2,3,4,5,6,7,8]"), marker)
    }

    // MARK: - (e) a key line split in two by the stdout tee

    func test_theTailOfASplitKeyLineIsScrubbed() {
        XCTAssertEqual(scrub(list(18, 32) + "] len 32 slat << [] len 0"), marker + " len 32 slat << [] len 0")
        XCTAssertEqual(scrub(",18,19,20] len 32"), marker + " len 32")
        XCTAssertEqual(scrub("5,17,200,] len 32 slat << [] len 0"), marker + " len 32 slat << [] len 0")
        XCTAssertEqual(kinds(list(18, 32) + "] len 32"), [.tailFragment])
    }

    func test_theHeadOfASplitKeyLineIsScrubbedEvenWithoutAKeyword() {
        XCTAssertEqual(scrub("x [1,2,3,4,5,6,7"), "x " + marker)
        XCTAssertEqual(scrub("index [1"), "index " + marker)
        XCTAssertEqual(scrub("x ["), "x [")
        XCTAssertEqual(scrub("x [ab"), "x [ab")
    }

    func test_textThatOnlyLooksLikeATailIsLeftAlone() {
        XCTAssertEqual(scrub("1) first item"), "1) first item")
        XCTAssertEqual(scrub("118): voice send channel options"), "118): voice send channel options")
        XCTAssertEqual(scrub("12,34,56 not closed"), "12,34,56 not closed")
        XCTAssertEqual(scrub("300,4] foo"), "300,4] foo")
        XCTAssertEqual(scrub("text 18,19,20] len 32"), "text 18,19,20] len 32")
        XCTAssertEqual(scrub("32 slat << [] len 0"), "32 slat << [] len 0")
    }

    /// The real shapes cut at EVERY byte offset, the way a 4096-byte pipe read cuts them: no key
    /// number may survive in either half.
    func test_aKeyLineCutAtAnyOffsetLeaksNothing() {
        let key = list(200, 231)
        let shapes: [String] = [
            "derived_key [" + key + "] len 32",
            "(x.cc:118): secret [" + key + "] len 32 slat [" + list(200, 215) + "] len 16",
            "(x.cc:118): secret [" + key + "] len 32 slat << [] len 0",
            "key bytes [" + key + "] len 32"
        ]
        for line in shapes {
            let bytes: [UInt8] = Array(line.utf8)
            var offset: Int = 0
            while offset <= bytes.count {
                let head: String = String(decoding: bytes[0..<offset], as: UTF8.self)
                let tail: String = String(decoding: bytes[offset..<bytes.count], as: UTF8.self)
                let joined: String = scrub(head) + "\n" + scrub(tail)
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
        XCTAssertEqual(scrub("key: AA BB CC DD EE FF 00 11 end"), "key: " + marker + " end")
        XCTAssertEqual(scrub("aa:bb cc:dd ee:ff 00:11"), marker)
        XCTAssertEqual(kinds("aa bb cc dd ee ff 00 11"), [.hexRun])
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
            XCTAssertTrue(KeyMaterialScrubber.matches(in: line).isEmpty)
        }
    }

    func test_unicodeAroundAMatchSurvivesIntact() {
        XCTAssertEqual(scrub("h\u{E9}llo [1,2,3,4,5,6,7,8] w\u{F6}rld \u{1F680}"),
                       "h\u{E9}llo " + marker + " w\u{F6}rld \u{1F680}")
        XCTAssertEqual(scrub("\u{65E5}\u{672C} derived_key [1,2,3]"), "\u{65E5}\u{672C} derived_key " + marker)
    }

    // MARK: - Marker, idempotence

    func test_theMarkerIsNeverMatchedAgain() {
        XCTAssertEqual(scrub(marker), marker)
        XCTAssertEqual(scrub("x " + marker + " y"), "x " + marker + " y")
        XCTAssertEqual(scrub("derived_key " + marker), "derived_key " + marker)
        XCTAssertEqual(scrub("secret " + marker + " len 32"), "secret " + marker + " len 32")
    }

    func test_scrubbingTwiceEqualsScrubbingOnce() throws {
        let file = try loadVectors()
        for vector in file.vectors {
            let once = scrub(vector.input)
            XCTAssertEqual(scrub(once), once, vector.name)
        }
    }

    // MARK: - Bounded work

    func test_aTextLongerThanTheCapKeepsItsHeadAndLosesItsTail() {
        let cap: Int = KeyMaterialScrubber.maxScanBytes
        let clean: String = String(repeating: "abcdefghij klm ", count: 70_000)   // about 1 MB
        XCTAssertGreaterThan(clean.utf8.count, cap)
        XCTAssertEqual(scrub(clean), String(clean.prefix(cap)) + marker)

        // a key that starts after the cap is never looked at, and never survives
        let padding: String = String(repeating: "x", count: cap + 10)
        let keyAfterCap: String = padding + " derived_key [\(list(1, 32))] len 32"
        let scrubbedAfter: String = scrub(keyAfterCap)
        XCTAssertFalse(scrubbedAfter.contains("derived_key"))
        XCTAssertFalse(scrubbedAfter.contains("1,2,3"))
        XCTAssertTrue(scrubbedAfter.hasSuffix(marker))

        // a key inside the scanned part is still scrubbed
        let keyBeforeCap: String = "y [\(list(1, 32))] " + padding
        let scrubbedBefore: String = scrub(keyBeforeCap)
        XCTAssertTrue(scrubbedBefore.hasPrefix("y " + marker + " "))
        XCTAssertFalse(scrubbedBefore.contains("1,2,3"))
    }

    func test_theCapNeverCutsInsideAMultiByteCharacter() {
        let cap: Int = KeyMaterialScrubber.maxScanBytes
        // the 2-byte character straddles the cap: it goes, whole, with the tail
        let text: String = String(repeating: "a", count: cap - 1) + "\u{E9}" + String(repeating: "z", count: 10)
        XCTAssertEqual(scrub(text), String(repeating: "a", count: cap - 1) + marker)
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
}

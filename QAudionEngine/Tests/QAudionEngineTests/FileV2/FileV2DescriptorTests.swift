import XCTest
import CryptoKit
@testable import QAudionEngine

/// The descriptor parser (section 12.7 and 12.9 steps 1 and 2), the strict JSON reader and the strict base64
/// decoder, beyond the descriptor vectors of the KAT (`FileV2KatTests`): the size limit, the number rules, the
/// string rules, the thumbnail rules, the header checks and their error codes.
final class FileV2DescriptorTests: XCTestCase {

    private typealias Support = FileV2TestSupport

    /// A real encryptor, so every descriptor built here carries a header that validates against its key.
    private func makeEncryptor(size: UInt64 = 1023) throws -> FileV2Encryptor {
        try FileV2Encryptor(fileKey: Data(repeating: 0x42, count: 32), fileID: Data(repeating: 0x24, count: 16),
                            plaintextSize: size)
    }

    private func b64(_ data: Data) -> String { data.base64EncodedString() }

    /// A minimal valid descriptor; `extra` is appended inside the object and starts with a comma.
    private func json(_ encryptor: FileV2Encryptor, kind: String = "file", source: String = #"{"via":"direct"}"#,
                      extra: String = "") -> String {
        #"{"qa_file":2,"id":"\#(b64(encryptor.fileID))","k":"\#(b64(encryptor.fileKey))","#
            + #""h":"\#(b64(encryptor.header.bytes))","sz":\#(encryptor.plaintextSize),"kind":"\#(kind)","#
            + #""src":\#(source)\#(extra)}"#
    }

    private func assertCode(_ text: String, _ code: String, _ label: String, file: StaticString = #filePath,
                            line: UInt = #line) {
        XCTAssertThrowsError(try FileV2Descriptor.parse(text), label, file: file, line: line) { error in
            XCTAssertEqual((error as? FileV2Error)?.code, code, label, file: file, line: line)
        }
    }

    private func assertParses(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try FileV2Descriptor.parse(text), label, file: file, line: line)
    }

    // MARK: Baseline and the size limit

    func testMinimalDescriptorParses() throws {
        let encryptor = try makeEncryptor()
        let descriptor = try FileV2Descriptor.parse(json(encryptor))
        XCTAssertEqual(descriptor.fileID, encryptor.fileID)
        XCTAssertEqual(descriptor.fileKey, encryptor.fileKey)
        XCTAssertEqual(descriptor.header, encryptor.header)
        XCTAssertEqual(descriptor.size, 1023)
        XCTAssertEqual(descriptor.kind, .file)
        XCTAssertEqual(descriptor.source.via, .direct)
        XCTAssertNil(descriptor.name)
        XCTAssertNil(descriptor.mimeType)
        XCTAssertNil(descriptor.preview)
        XCTAssertNil(descriptor.media)
        XCTAssertNil(descriptor.thumbnail)
        XCTAssertNil(descriptor.ex)
        XCTAssertNil(descriptor.xp)
        XCTAssertEqual(try FileV2Descriptor.parse(utf8: Data(json(encryptor).utf8)).fileID, encryptor.fileID)
    }

    func testEveryKindIsAccepted() throws {
        let encryptor = try makeEncryptor()
        for kind in ["file", "image", "video", "voice", "avatar", "thumb"] {
            XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, kind: kind)).kind.rawValue, kind)
        }
        XCTAssertEqual(FileV2Descriptor.Kind.allCases.count, 6)
        assertCode(json(encryptor, kind: "document"), "bad_descriptor", "unknown kind")
        assertCode(json(encryptor, kind: "File"), "bad_descriptor", "kind is case sensitive")
    }

    /// "MUST stay under 8 KiB": 8191 bytes parse, 8192 do not (the reference receiver's boundary).
    func testSerialisedDescriptorMustStayUnder8KiB() throws {
        let encryptor = try makeEncryptor()
        let base = json(encryptor)
        let overhead = #","pad":""#.utf8.count + 1    // ,"pad":"" around the filler
        func padded(totalBytes: Int) -> String {
            let filler = String(repeating: "x", count: totalBytes - base.utf8.count - overhead)
            return json(encryptor, extra: #","pad":"\#(filler)""#)
        }
        let atLimit = padded(totalBytes: FileV2.maxDescriptorBytes - 1)
        XCTAssertEqual(atLimit.utf8.count, 8191)
        assertParses(atLimit, "8191 bytes")
        let over = padded(totalBytes: FileV2.maxDescriptorBytes)
        XCTAssertEqual(over.utf8.count, 8192)
        assertCode(over, "bad_descriptor", "8192 bytes")
        // Counted in UTF-8 bytes, not characters.
        let multibyte = json(encryptor, extra: #","pad":"\#(String(repeating: "\u{20AC}", count: 2700))""#)
        XCTAssertLessThan(multibyte.count, 8192)
        XCTAssertGreaterThanOrEqual(multibyte.utf8.count, 8192)
        assertCode(multibyte, "bad_descriptor", "multi-byte characters count as bytes")
    }

    // MARK: The mandatory fields

    func testVersionMustBeTheIntegerTwo() throws {
        let encryptor = try makeEncryptor()
        let good = json(encryptor)
        for (replacement, label) in [(#""qa_file":1"#, "1"), (#""qa_file":3"#, "3"), (#""qa_file":"2""#, "string"),
                                     (#""qa_file":2.0"#, "2.0"), (#""qa_file":true"#, "true"),
                                     (#""qa_file":null"#, "null"), (#""qa_file":[2]"#, "array")] {
            assertCode(good.replacingOccurrences(of: #""qa_file":2"#, with: replacement), "bad_descriptor",
                       "qa_file \(label)")
        }
        assertCode(good.replacingOccurrences(of: #""qa_file":2,"#, with: ""), "bad_descriptor", "qa_file missing")
    }

    func testIdKeyAndHeaderMustBeBase64OfTheRightLength() throws {
        let encryptor = try makeEncryptor()
        let good = json(encryptor)
        func replacing(_ key: String, with value: String) -> String {
            let original: String
            switch key {
            case "id": original = b64(encryptor.fileID)
            case "k": original = b64(encryptor.fileKey)
            default: original = b64(encryptor.header.bytes)
            }
            return good.replacingOccurrences(of: #""\#(key)":"\#(original)""#, with: #""\#(key)":\#(value)"#)
        }
        for key in ["id", "k", "h"] {
            assertCode(replacing(key, with: #""""#), "bad_descriptor", "\(key) empty")
            assertCode(replacing(key, with: #""AAAA""#), "bad_descriptor", "\(key) too short")
            assertCode(replacing(key, with: "123"), "bad_descriptor", "\(key) a number")
            assertCode(replacing(key, with: "null"), "bad_descriptor", "\(key) null")
        }
        assertCode(replacing("id", with: #""\#(b64(Data(count: 15)))""#), "bad_descriptor", "id 15 bytes")
        assertCode(replacing("id", with: #""\#(b64(Data(count: 17)))""#), "bad_descriptor", "id 17 bytes")
        assertCode(replacing("k", with: #""\#(b64(Data(count: 31)))""#), "bad_descriptor", "k 31 bytes")
        assertCode(replacing("k", with: #""\#(b64(Data(count: 33)))""#), "bad_descriptor", "k 33 bytes")
        assertCode(replacing("h", with: #""\#(b64(Data(count: 63)))""#), "bad_descriptor", "h 63 bytes")
        assertCode(replacing("h", with: #""\#(b64(Data(count: 65)))""#), "bad_descriptor", "h 65 bytes")
        // Standard base64 only: the URL alphabet and missing padding are not accepted.
        let urlSafe = b64(encryptor.fileKey).replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        if urlSafe != b64(encryptor.fileKey) {
            assertCode(replacing("k", with: #""\#(urlSafe)""#), "bad_descriptor", "k in the URL alphabet")
        }
        assertCode(replacing("k", with: #""\#(b64(encryptor.fileKey).replacingOccurrences(of: "=", with: ""))""#),
                   "bad_descriptor", "k without padding")
    }

    func testSizeMustBeAnIntegerInRange() throws {
        let encryptor = try makeEncryptor()
        let good = json(encryptor)
        func withSize(_ literal: String) -> String { good.replacingOccurrences(of: #""sz":1023"#, with: #""sz":\#(literal)"#) }
        for literal in ["0", "-1", "1023.0", "1.023e3", "1e3", #""1023""#, "true", "null", "[1023]",
                        "5368709121", "9223372036854775808", "18446744073709551616", "01023", "+1023"] {
            assertCode(withSize(literal), "bad_descriptor", "sz \(literal)")
        }
        assertCode(good.replacingOccurrences(of: #""sz":1023,"#, with: ""), "bad_descriptor", "sz missing")
        // The largest file: 5 GiB, a header for it, and a descriptor that parses.
        let largest = try makeEncryptor(size: FileV2.maxSize)
        XCTAssertEqual(try FileV2Descriptor.parse(json(largest)).size, FileV2.maxSize)
    }

    // MARK: Optional text fields

    func testNameAndMimeTypeAreBoundedInUtf8Bytes() throws {
        let encryptor = try makeEncryptor()
        func name(_ value: String) -> String { json(encryptor, extra: #","nm":"\#(value)""#) }
        func mime(_ value: String) -> String { json(encryptor, extra: #","mt":"\#(value)""#) }
        XCTAssertEqual(try FileV2Descriptor.parse(name(String(repeating: "n", count: 255))).name?.utf8.count, 255)
        assertCode(name(String(repeating: "n", count: 256)), "bad_descriptor", "nm 256 bytes")
        // 127 two-byte characters and one ASCII byte are 255 bytes; one more character is 257.
        let accented = String(repeating: "\u{E9}", count: 127) + "a"
        XCTAssertEqual(accented.utf8.count, 255)
        XCTAssertEqual(try FileV2Descriptor.parse(name(accented)).name, accented)
        assertCode(name(String(repeating: "\u{E9}", count: 128)), "bad_descriptor", "nm 256 bytes in 128 characters")
        XCTAssertEqual(try FileV2Descriptor.parse(mime(String(repeating: "m", count: 128))).mimeType?.utf8.count, 128)
        assertCode(mime(String(repeating: "m", count: 129)), "bad_descriptor", "mt 129 bytes")
        assertCode(json(encryptor, extra: #","nm":7"#), "bad_descriptor", "nm not a string")
        assertCode(json(encryptor, extra: #","mt":["a"]"#), "bad_descriptor", "mt not a string")
        // Absent and null are the same thing.
        XCTAssertNil(try FileV2Descriptor.parse(json(encryptor, extra: #","nm":null"#)).name)
    }

    func testPreviewIsBase64OfAtMost2048Bytes() throws {
        let encryptor = try makeEncryptor()
        func preview(_ count: Int) -> String { json(encryptor, extra: #","pv":"\#(b64(Data(repeating: 1, count: count)))""#) }
        XCTAssertEqual(try FileV2Descriptor.parse(preview(2048)).preview?.count, 2048)
        XCTAssertEqual(try FileV2Descriptor.parse(preview(0)).preview?.count, 0)
        assertCode(preview(2049), "bad_descriptor", "pv 2049 bytes")
        assertCode(json(encryptor, extra: #","pv":"not base64!""#), "bad_descriptor", "pv not base64")
        assertCode(json(encryptor, extra: #","pv":12"#), "bad_descriptor", "pv not a string")
    }

    // MARK: The source

    func testSourceRules() throws {
        let encryptor = try makeEncryptor()
        let srv = #"{"via":"srv","obj":"0a1b","tok":{"v":"ff00","exp":1760000000000,"max":100}}"#
        let parsed = try FileV2Descriptor.parse(json(encryptor, source: srv))
        XCTAssertEqual(parsed.source.via, .srv)
        XCTAssertEqual(parsed.source.obj, "0a1b")
        XCTAssertEqual(parsed.source.token, FileV2Descriptor.Token(v: "ff00", exp: 1_760_000_000_000, max: 100))
        // direct needs no object and may carry one.
        XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, source: #"{"via":"direct","obj":"x"}"#)).source.obj, "x")
        for (source, label) in [(#"{"via":"srv"}"#, "srv without obj"), (#"{"via":"srv","obj":""}"#, "srv with empty obj"),
                                (#"{"via":"srv","obj":5}"#, "obj not a string"), (#"{"via":"ftp","obj":"x"}"#, "unknown via"),
                                (#"{"via":"SRV","obj":"x"}"#, "via is case sensitive"), (#"{"obj":"x"}"#, "via missing"),
                                (#"{"via":1}"#, "via not a string"), (#"["srv"]"#, "src an array"),
                                (#""srv""#, "src a string"), ("null", "src null"),
                                (#"{"via":"srv","obj":"x","tok":"t"}"#, "tok not an object"),
                                (#"{"via":"srv","obj":"x","tok":{}}"#, "tok without v"),
                                (#"{"via":"srv","obj":"x","tok":{"v":1}}"#, "tok.v not a string"),
                                (#"{"via":"srv","obj":"x","tok":{"v":"a","exp":-1}}"#, "tok.exp negative"),
                                (#"{"via":"srv","obj":"x","tok":{"v":"a","max":1.5}}"#, "tok.max not an integer")] {
            assertCode(json(encryptor, source: source), "bad_descriptor", label)
        }
        assertCode(json(encryptor).replacingOccurrences(of: #","src":{"via":"direct"}"#, with: ""), "bad_descriptor", "no src")
    }

    // MARK: Media, thumbnail, lifetime

    func testMediaFields() throws {
        let encryptor = try makeEncryptor()
        let media = try FileV2Descriptor.parse(json(encryptor, extra: #","m":{"w":1920,"h":1080,"dur":5234,"wave":[0,3,9]}"#)).media
        XCTAssertEqual(media, FileV2Descriptor.Media(w: 1920, h: 1080, dur: 5234, wave: [0, 3, 9]))
        XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, extra: #","m":{}"#)).media,
                       FileV2Descriptor.Media(w: nil, h: nil, dur: nil, wave: nil))
        for (fragment, label) in [(#""m":[1]"#, "m an array"), (#""m":{"w":"1"}"#, "w a string"), (#""m":{"w":-1}"#, "w negative"),
                                  (#""m":{"dur":1.5}"#, "dur a fraction"), (#""m":{"wave":3}"#, "wave a number"),
                                  (#""m":{"wave":[1,"a"]}"#, "wave sample a string"), (#""m":{"wave":[1.5]}"#, "wave sample a fraction")] {
            assertCode(json(encryptor, extra: "," + fragment), "bad_descriptor", label)
        }
    }

    func testThumbnailIsACompleteDescriptorOfKindThumbAndNeverNests() throws {
        let encryptor = try makeEncryptor()
        let thumbEncryptor = try FileV2Encryptor(fileKey: Data(repeating: 0x55, count: 32),
                                                 fileID: Data(repeating: 0x66, count: 16), plaintextSize: 4000)
        let thumbnail = json(thumbEncryptor, kind: "thumb")
        let parsed = try FileV2Descriptor.parse(json(encryptor, extra: #","th":\#(thumbnail)"#))
        XCTAssertEqual(parsed.thumbnail?.kind, .thumb)
        XCTAssertEqual(parsed.thumbnail?.fileID, thumbEncryptor.fileID)
        XCTAssertEqual(parsed.thumbnail?.size, 4000)
        XCTAssertNil(parsed.thumbnail?.thumbnail)

        // The thumbnail's own header is validated like any other (here: a header of another key).
        let wrongKey = thumbnail.replacingOccurrences(of: b64(thumbEncryptor.fileKey), with: b64(Data(repeating: 1, count: 32)))
        assertCode(json(encryptor, extra: #","th":\#(wrongKey)"#), "commit_mismatch", "thumbnail with another key")
        // Kind must be thumb.
        assertCode(json(encryptor, extra: #","th":\#(json(thumbEncryptor, kind: "image"))"#), "bad_descriptor", "thumbnail of kind image")
        // A thumbnail has no thumbnail.
        let nested = json(thumbEncryptor, kind: "thumb", extra: #","th":\#(thumbnail)"#)
        assertCode(json(encryptor, extra: #","th":\#(nested)"#), "bad_descriptor", "thumbnail of a thumbnail")
        // Not an object, and null is absent.
        assertCode(json(encryptor, extra: #","th":"x""#), "bad_descriptor", "th a string")
        assertCode(json(encryptor, extra: #","th":[]"#), "bad_descriptor", "th an array")
        XCTAssertNil(try FileV2Descriptor.parse(json(encryptor, extra: #","th":null"#)).thumbnail)
        // A descriptor of kind thumb on its own is fine.
        XCTAssertEqual(try FileV2Descriptor.parse(thumbnail).kind, .thumb)
    }

    func testLifetimeAndExportFields() throws {
        let encryptor = try makeEncryptor()
        let parsed = try FileV2Descriptor.parse(json(encryptor, extra: #","ex":604800,"xp":0"#))
        XCTAssertEqual(parsed.ex, 604_800)
        XCTAssertEqual(parsed.xp, 0)
        for fragment in [#""ex":-1"#, #""ex":"1""#, #""xp":1.0"#, #""xp":true"#] {
            assertCode(json(encryptor, extra: "," + fragment), "bad_descriptor", fragment)
        }
    }

    func testUnknownFieldsAreIgnoredAndTheLastDuplicateWins() throws {
        let encryptor = try makeEncryptor()
        let extra = try FileV2Descriptor.parse(json(encryptor, extra: #","future":{"a":[1,2,{"b":null}]},"x":1.5"#))
        XCTAssertEqual(extra.size, 1023)
        let duplicate = json(encryptor, kind: "image", extra: #","kind":"video""#)
        XCTAssertEqual(try FileV2Descriptor.parse(duplicate).kind, .video)
    }

    // MARK: The header checks (section 12.9 step 2), with the codes of the reference receiver

    func testHeaderChecksAndTheirCodes() throws {
        let encryptor = try makeEncryptor()
        let good = json(encryptor)
        func withHeader(_ header: Data) -> String {
            good.replacingOccurrences(of: b64(encryptor.header.bytes), with: b64(header))
        }
        var magic = encryptor.header.bytes
        magic[0] ^= 1
        assertCode(withHeader(magic), "bad_header", "magic")
        var otherID = encryptor.header.bytes
        otherID[4] ^= 1
        assertCode(withHeader(otherID), "bad_header", "file_id differs from id")
        var commitment = encryptor.header.bytes
        commitment[40] ^= 1
        assertCode(withHeader(commitment), "commit_mismatch", "commitment")
        // stream_len not Padme of sz: a header built for another size, with the right commitment.
        let otherSize = try FileV2Encryptor(fileKey: encryptor.fileKey, fileID: encryptor.fileID, plaintextSize: 5000)
        assertCode(withHeader(otherSize.header.bytes), "size_mismatch", "header of another size")
        // Order: the structural checks come before the Padme check and the commitment check.
        var incoherent = otherSize.header.bytes
        incoherent[31] = 9
        assertCode(withHeader(incoherent), "bad_header", "total_chunks incoherent beats size_mismatch")
        // And the key must derive the commitment.
        let differentKey = good.replacingOccurrences(of: b64(encryptor.fileKey), with: b64(Data(repeating: 9, count: 32)))
        assertCode(differentKey, "commit_mismatch", "another key")
    }

    func testDescriptorDescriptionNeverPrintsTheKey() throws {
        let encryptor = try makeEncryptor()
        let descriptor = try FileV2Descriptor.parse(json(encryptor))
        let text = "\(descriptor) \(String(describing: descriptor)) \(String(reflecting: descriptor))"
        XCTAssertFalse(text.contains(Support.hexString(descriptor.fileKey)))
        XCTAssertFalse(text.contains(b64(descriptor.fileKey)))
        XCTAssertTrue(text.contains("kind: file"))
    }

    // MARK: JSON strictness

    func testNotJsonIsBadDescriptor() throws {
        let encryptor = try makeEncryptor()
        let good = json(encryptor)
        let cases: [(String, String)] = [
            ("", "empty"), ("null", "null"), ("[]", "array"), ("2", "number"), (#""x""#, "string"),
            (good + "x", "trailing garbage"), (good + "{}", "two values"), (good + " ", "trailing space is fine"),
            (String(good.dropLast()), "unterminated"), (good.replacingOccurrences(of: ",\"kind\"", with: ",,\"kind\""), "double comma"),
            (String(good.dropLast()) + ",}", "trailing comma"), (good.replacingOccurrences(of: "\"", with: "'"), "single quotes"),
            ("{" + #""qa_file":2"# + "/* c */}", "comment"), ("{\"qa_file\":2,\"a\":NaN}", "NaN"),
            ("{\"qa_file\":2,\"a\":Infinity}", "Infinity"), ("{\"qa_file\":2,\"a\":01}", "leading zero"),
            ("{\"qa_file\":2,\"a\":.5}", "bare fraction"), ("{\"qa_file\":2,\"a\":1.}", "trailing dot"),
            ("{\"qa_file\":2,\"a\":-}", "bare minus"), ("{\"qa_file\":2,\"a\":1e}", "empty exponent"),
            ("{\"qa_file\":2,\"a\":\"x\ny\"}", "raw newline in a string"), ("{\"qa_file\":2,\"a\":\"\\x\"}", "unknown escape"),
            ("{\"qa_file\":2,\"a\":\"\\u12\"}", "short unicode escape"), ("{\"qa_file\":2,\"a\":\"\\uZZZZ\"}", "bad unicode escape"),
            ("{\"qa_file\":2 \"a\":1}", "missing comma"), ("{\"qa_file\" 2}", "missing colon"), ("{qa_file:2}", "bare key"),
            ("{\"qa_file\":tru}", "truncated literal"), ("{\"qa_file\":True}", "capitalised literal"),
            ("\u{FEFF}" + good, "byte order mark")
        ]
        for (text, label) in cases where label != "trailing space is fine" {
            assertCode(text, "bad_descriptor", label)
        }
        assertParses(good + " ", "trailing whitespace is fine")
        assertParses("  \n\t" + good + "\r\n", "surrounding whitespace is fine")
        // Depth limit: deeply nested arrays do not blow the stack, they fail.
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        assertCode(json(encryptor, extra: #","d":\#(deep)"#), "bad_descriptor", "depth 200")
        let shallow = String(repeating: "[", count: 20) + String(repeating: "]", count: 20)
        assertParses(json(encryptor, extra: #","d":\#(shallow)"#), "depth 20")
    }

    func testJsonParserValues() throws {
        func parse(_ text: String) -> FileV2JSONValue? { FileV2JSONParser.parse(Data(text.utf8)) }
        XCTAssertEqual(parse("null"), .null)
        XCTAssertEqual(parse("true"), .bool(true))
        XCTAssertEqual(parse(" false "), .bool(false))
        XCTAssertEqual(parse("0"), .int(0))
        XCTAssertEqual(parse("-0"), .int(0))
        XCTAssertEqual(parse("-17"), .int(-17))
        XCTAssertEqual(parse("9223372036854775807"), .int(Int64.max))
        XCTAssertEqual(parse("-9223372036854775808"), .int(Int64.min))
        XCTAssertEqual(parse("9223372036854775808"), .number)
        XCTAssertEqual(parse("-9223372036854775809"), .number)
        XCTAssertEqual(parse("18446744073709551616"), .number)
        XCTAssertEqual(parse("1.0"), .number)
        XCTAssertEqual(parse("1e3"), .number)
        XCTAssertEqual(parse("1E+3"), .number)
        XCTAssertEqual(parse("-0.5e-2"), .number)
        XCTAssertEqual(parse(#""a\"b\\c\/d\b\f\n\r\t""#), .string("a\"b\\c/d\u{8}\u{C}\n\r\t"))
        XCTAssertEqual(parse(#""\u00e9\u20AC""#), .string("\u{E9}\u{20AC}"))
        // A surrogate pair is one scalar; a lone surrogate is U+FFFD.
        XCTAssertEqual(parse(#""\ud83d\ude00""#), .string("\u{1F600}"))
        XCTAssertEqual(parse(#""\ud800""#), .string("\u{FFFD}"))
        XCTAssertEqual(parse(#""\udc00""#), .string("\u{FFFD}"))
        XCTAssertEqual(parse(#""\ud800\u0041""#), .string("\u{FFFD}A"))
        XCTAssertEqual(parse(#""\ud800x""#), .string("\u{FFFD}x"))
        XCTAssertEqual(parse("\"\u{1F600}\""), .string("\u{1F600}"), "raw UTF-8 passes through")
        XCTAssertEqual(parse("[]"), .array([]))
        XCTAssertEqual(parse("{}"), .object([:]))
        XCTAssertEqual(parse(#"{"a":[1,{"b":null}],"c":"d"}"#),
                       .object(["a": .array([.int(1), .object(["b": .null])]), "c": .string("d")]))
        XCTAssertEqual(parse(#"{"a":1,"a":2}"#), .object(["a": .int(2)]), "the last duplicate wins")
        // Invalid UTF-8 never traps.
        XCTAssertNotNil(FileV2JSONParser.parse(Data([0x22, 0xFF, 0xFE, 0x22])))
        XCTAssertNil(FileV2JSONParser.parse(Data([0x7B, 0xFF])))
    }

    // MARK: Base64 strictness

    func testBase64Decoder() {
        // RFC 4648 section 10.
        let vectors: [(String, String)] = [("", ""), ("Zg==", "f"), ("Zm8=", "fo"), ("Zm9v", "foo"), ("Zm9vYg==", "foob"),
                                           ("Zm9vYmE=", "fooba"), ("Zm9vYmFy", "foobar")]
        for (encoded, plain) in vectors {
            XCTAssertEqual(FileV2Base64.decode(encoded), Data(plain.utf8), encoded)
        }
        XCTAssertEqual(FileV2Base64.decode("+/+/"), Data([0xFB, 0xFF, 0xBF]))
        for bad in ["Zg=", "Zg", "Zm9", "Zg==Zg==", "Z===", "====", "Zm9v\n", "Zm 9v", "Zm9-", "Zm9_", "Zm=v", "=Zm9", "Zm9vY", "Zg==\n"] {
            XCTAssertNil(FileV2Base64.decode(bad), "\(bad.debugDescription) must be refused")
        }
        // Round trip with the system encoder.
        for length in [0, 1, 2, 3, 4, 31, 32, 33, 64, 255] {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 11) & 0xFF) })
            XCTAssertEqual(FileV2Base64.decode(data.base64EncodedString()), data, "length \(length)")
        }
    }
}

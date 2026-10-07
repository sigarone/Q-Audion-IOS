import XCTest
import CryptoKit
@testable import QAudionEngine

/// The descriptor validator (section 12.7.2 to 12.7.5 and 12.9 steps 1 and 2) beyond the vectors of the KAT
/// (`FileV2KatTests`, `FileV2DescriptorKatTests`): the size limit, the field rules, the thumbnail rules, the header
/// checks and their error codes. The JSON profile itself (UTF-8, integers, base64, recognition) is in
/// `FileV2ProfileTests`.
final class FileV2DescriptorTests: XCTestCase {

    private typealias Support = FileV2TestSupport

    /// A real encryptor, so every descriptor built here carries a header that validates against its key.
    private func makeEncryptor(size: UInt64 = 1023, key: UInt8 = 0x42, id: UInt8 = 0x24) throws -> FileV2Encryptor {
        try FileV2Encryptor(fileKey: Data(repeating: key, count: 32), fileID: Data(repeating: id, count: 16),
                            plaintextSize: size)
    }

    private func b64(_ data: Data) -> String { data.base64EncodedString() }

    private let objectID = "343a95c1-f56d-432d-9de4-78cf3473327d"
    private let tokenValue = String(repeating: "ab", count: 32)

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
        XCTAssertEqual(descriptor.thumbnailStatus, .absent)
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
                                     (#""qa_file":null"#, "null"), (#""qa_file":[2]"#, "array"),
                                     (#""qa_file":02"#, "leading zero"), (#""qa_file":2e0"#, "exponent")] {
            // The validator checks the version itself: another version is bad_descriptor here and
            // unsupported_version only through recognition (FileV2Message).
            assertCode(good.replacingOccurrences(of: #""qa_file":2"#, with: replacement), "bad_descriptor",
                       "qa_file \(label)")
        }
        assertCode(good.replacingOccurrences(of: #""qa_file":2,"#, with: ""), "bad_descriptor", "qa_file missing")
    }

    func testIdKeyAndHeaderMustBeCanonicalBase64OfTheRightLength() throws {
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
        // Canonical form: no line break anywhere (the trailing bits and the other forms are in FileV2ProfileTests and
        // in the `base64` vectors of the KAT).
        let keyText = b64(encryptor.fileKey)
        assertCode(replacing("k", with: #""\#(keyText.prefix(8))\n\#(keyText.dropFirst(8))""#), "bad_descriptor",
                   "k with a line break")
    }

    func testSizeMustBeAnIntegerInRange() throws {
        let encryptor = try makeEncryptor()
        let good = json(encryptor)
        func withSize(_ literal: String) -> String { good.replacingOccurrences(of: #""sz":1023"#, with: #""sz":\#(literal)"#) }
        for literal in ["0", "-1", "1023.0", "1.023e3", "1e3", #""1023""#, "true", "null", "[1023]",
                        "5368709121", "9223372036854775808", "18446744073709551616", "01023", "+1023",
                        "9007199254740992"] {
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
        XCTAssertEqual(Support.utf8(try FileV2Descriptor.parse(name(accented)).name), Support.utf8(accented))
        assertCode(name(String(repeating: "\u{E9}", count: 128)), "bad_descriptor", "nm 256 bytes in 128 characters")
        XCTAssertEqual(try FileV2Descriptor.parse(mime(String(repeating: "m", count: 128))).mimeType?.utf8.count, 128)
        assertCode(mime(String(repeating: "m", count: 129)), "bad_descriptor", "mt 129 bytes")
        assertCode(json(encryptor, extra: #","nm":7"#), "bad_descriptor", "nm not a string")
        assertCode(json(encryptor, extra: #","mt":["a"]"#), "bad_descriptor", "mt not a string")
        // Absent and null are the same thing, for nm, mt and pv only.
        XCTAssertNil(try FileV2Descriptor.parse(json(encryptor, extra: #","nm":null"#)).name)
        XCTAssertNil(try FileV2Descriptor.parse(json(encryptor, extra: #","mt":null,"pv":null"#)).mimeType)
        // The name keeps the exact bytes it was written with (no normalisation).
        let decomposed = "e\u{301}.txt"
        XCTAssertEqual(Support.utf8(try FileV2Descriptor.parse(name(decomposed)).name), Support.utf8(decomposed))
    }

    func testPreviewIsCanonicalBase64OfAtMost2048Bytes() throws {
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
        let srv = #"{"via":"srv","obj":"\#(objectID)","tok":{"v":"\#(tokenValue)","exp":1760000000000,"max":100}}"#
        let parsed = try FileV2Descriptor.parse(json(encryptor, source: srv))
        XCTAssertEqual(parsed.source.via, .srv)
        XCTAssertEqual(parsed.source.obj, objectID)
        XCTAssertEqual(parsed.source.token, FileV2Descriptor.Token(v: tokenValue, exp: 1_760_000_000_000, max: 100))
        // A server source without a token is valid (it waits for a qa_file_src message).
        let noToken = try FileV2Descriptor.parse(json(encryptor, source: #"{"via":"srv","obj":"\#(objectID)"}"#))
        XCTAssertNil(noToken.source.token)
        // direct needs no object and may carry one (checked the same way, not used).
        XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, source: #"{"via":"direct","obj":"\#(objectID)"}"#)).source.obj,
                       objectID)
        let id = objectID, tv = tokenValue
        let invalidSources: [(String, String)] = [
            (#"{"via":"srv"}"#, "srv without obj"), (#"{"via":"srv","obj":""}"#, "srv with empty obj"),
            (#"{"via":"srv","obj":5}"#, "obj not a string"), (#"{"via":"srv","obj":null}"#, "obj null"),
            (#"{"via":"srv","obj":"0a1b"}"#, "obj not a uuid"),
            (#"{"via":"srv","obj":"343A95C1-F56D-432D-9DE4-78CF3473327D"}"#, "obj upper case"),
            (#"{"via":"direct","obj":"x"}"#, "direct obj is checked too"),
            (#"{"via":"ftp","obj":"\#(id)"}"#, "unknown via"),
            (#"{"via":"SRV","obj":"\#(id)"}"#, "via is case sensitive"),
            (#"{"obj":"\#(id)"}"#, "via missing"),
            (#"{"via":1}"#, "via not a string"), (#"["srv"]"#, "src an array"),
            (#""srv""#, "src a string"), ("null", "src null"),
            (#"{"via":"srv","obj":"\#(id)","tok":"t"}"#, "tok not an object"),
            (#"{"via":"srv","obj":"\#(id)","tok":null}"#, "tok null"),
            (#"{"via":"srv","obj":"\#(id)","tok":{}}"#, "tok without v"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":1,"exp":0,"max":0}}"#, "tok.v not a string"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":"ab","exp":0,"max":0}}"#, "tok.v too short"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":"\#(tv.uppercased())","exp":0,"max":0}}"#, "tok.v upper case"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":"\#(tv)","exp":-1,"max":0}}"#, "tok.exp negative"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":"\#(tv)","exp":0,"max":1.5}}"#, "tok.max not an integer"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":"\#(tv)","exp":0,"max":2147483648}}"#, "tok.max above int32"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":"\#(tv)","exp":0}}"#, "tok.max missing"),
            (#"{"via":"srv","obj":"\#(id)","tok":{"v":"\#(tv)","exp":0,"max":0,"x":{}}}"#, "tok holds an object")
        ]
        for (source, label) in invalidSources {
            assertCode(json(encryptor, source: source), "bad_descriptor", label)
        }
        // Unknown scalar members of tok (the server adds `scope`) are ignored.
        assertParses(json(encryptor, source: #"{"via":"srv","obj":"\#(objectID)","tok":{"v":"\#(tokenValue)","exp":0,"max":0,"scope":"group"}}"#),
                     "tok with an unknown scalar member")
        assertCode(json(encryptor).replacingOccurrences(of: #","src":{"via":"direct"}"#, with: ""), "bad_descriptor", "no src")
    }

    // MARK: Media, thumbnail, lifetime

    func testMediaIsCosmeticAndAMalformedOneIsIgnored() throws {
        let encryptor = try makeEncryptor()
        let media = try FileV2Descriptor.parse(json(encryptor, extra: #","m":{"w":1920,"h":1080,"dur":5234,"wave":[0,3,9]}"#)).media
        XCTAssertEqual(media, FileV2Descriptor.Media(w: 1920, h: 1080, dur: 5234, wave: [0, 3, 9]))
        XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, extra: #","m":{}"#)).media,
                       FileV2Descriptor.Media(w: nil, h: nil, dur: nil, wave: nil))
        // Well typed values are used as they are: no range check (the user interface clamps).
        XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, extra: #","m":{"w":-1,"h":4294967296}"#)).media,
                       FileV2Descriptor.Media(w: -1, h: 4_294_967_296, dur: nil, wave: nil))
        // A malformed m is IGNORED: the descriptor stays valid and m is absent.
        for (fragment, label) in [(#""m":[1]"#, "m an array"), (#""m":"x""#, "m a string"), (#""m":null"#, "m null"),
                                  (#""m":{"w":"1"}"#, "w a string"), (#""m":{"w":null}"#, "w null"),
                                  (#""m":{"dur":1.5}"#, "dur a fraction"), (#""m":{"dur":1e2}"#, "dur an exponent"),
                                  (#""m":{"w":9007199254740992}"#, "w above 2^53 - 1"), (#""m":{"wave":3}"#, "wave a number"),
                                  (#""m":{"wave":[1,"a"]}"#, "wave sample a string"), (#""m":{"wave":[1.5]}"#, "wave sample a fraction"),
                                  (#""m":{"wave":[[1]]}"#, "wave sample an array")] {
            let parsed = try FileV2Descriptor.parse(json(encryptor, extra: "," + fragment))
            XCTAssertNil(parsed.media, label)
            XCTAssertEqual(parsed.size, 1023, "\(label): the file is kept")
        }
        // A violation of the JSON profile inside m is still bad_descriptor for the whole descriptor.
        assertCode(json(encryptor, extra: #","m":{"w":1,"w":2}"#), "bad_descriptor", "duplicate member inside m")
    }

    func testThumbnailIsJudgedOnItsOwnAndNeverInvalidatesTheFile() throws {
        let encryptor = try makeEncryptor()
        let thumbEncryptor = try makeEncryptor(size: 4000, key: 0x55, id: 0x66)
        let thumbnail = json(thumbEncryptor, kind: "thumb")
        let parsed = try FileV2Descriptor.parse(json(encryptor, extra: #","th":\#(thumbnail)"#))
        XCTAssertEqual(parsed.thumbnailStatus, .valid)
        XCTAssertEqual(parsed.thumbnail?.kind, .thumb)
        XCTAssertEqual(parsed.thumbnail?.fileID, thumbEncryptor.fileID)
        XCTAssertEqual(parsed.thumbnail?.size, 4000)
        XCTAssertEqual(parsed.thumbnail?.thumbnailStatus, .absent)

        // An invalid thumbnail makes the thumbnail unusable; the file is processed.
        func assertThumbnailInvalid(_ th: String, _ label: String) throws {
            let result = try FileV2Descriptor.parse(json(encryptor, extra: #","th":\#(th)"#))
            XCTAssertEqual(result.thumbnailStatus, .invalid, label)
            XCTAssertNil(result.thumbnail, label)
            XCTAssertEqual(result.fileID, encryptor.fileID, "\(label): the file is valid")
        }
        // Its own header is validated against its own key (here: the key of another file).
        let wrongKey = thumbnail.replacingOccurrences(of: b64(thumbEncryptor.fileKey), with: b64(Data(repeating: 1, count: 32)))
        try assertThumbnailInvalid(wrongKey, "thumbnail with another key (commit_mismatch for the thumbnail only)")
        try assertThumbnailInvalid(json(thumbEncryptor, kind: "image"), "thumbnail of kind image")
        // A thumbnail has no thumbnail.
        try assertThumbnailInvalid(json(thumbEncryptor, kind: "thumb", extra: #","th":\#(thumbnail)"#), "thumbnail of a thumbnail")
        // A thumbnail is another file: its id differs from the id of the file.
        try assertThumbnailInvalid(json(encryptor, kind: "thumb"), "th.id equals id")
        try assertThumbnailInvalid(#""x""#, "th a string")
        try assertThumbnailInvalid("[]", "th an array")
        try assertThumbnailInvalid("null", "th null")
        try assertThumbnailInvalid("{}", "th an empty object")
        // The file's own errors come first and are never the thumbnail's.
        let badFileHeader = json(encryptor, extra: #","th":\#(thumbnail)"#)
            .replacingOccurrences(of: b64(encryptor.fileKey), with: b64(Data(repeating: 9, count: 32)))
        assertCode(badFileHeader, "commit_mismatch", "a bad file header with a valid th")
        // A descriptor of kind thumb on its own is fine, but it has no th: with one it is rejected.
        XCTAssertEqual(try FileV2Descriptor.parse(thumbnail).kind, .thumb)
        assertCode(json(thumbEncryptor, kind: "thumb", extra: #","th":\#(thumbnail)"#), "bad_descriptor",
                   "top-level kind thumb with th")
        // A violation of the JSON profile inside th rejects the whole descriptor.
        assertCode(json(encryptor, extra: #","th":{"qa_file":2,"qa_file":2}"#), "bad_descriptor", "duplicate member inside th")
    }

    func testLifetimeAndExportFields() throws {
        let encryptor = try makeEncryptor()
        let parsed = try FileV2Descriptor.parse(json(encryptor, extra: #","ex":604800,"xp":0"#))
        XCTAssertEqual(parsed.ex, 604_800)
        XCTAssertEqual(parsed.xp, 0)
        for (fragment, expected) in [(#""ex":-1"#, Int64(-1)), (#""ex":0"#, 0), (#""ex":2147483647"#, 2_147_483_647)] {
            XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, extra: "," + fragment)).ex, expected, fragment)
        }
        XCTAssertEqual(try FileV2Descriptor.parse(json(encryptor, extra: #","xp":1"#)).xp, 1)
        // A wrong type or an out-of-range value fails closed (a reader that tests xp != 0 would allow xp: 2).
        for fragment in [#""ex":-2"#, #""ex":2147483648"#, #""ex":"1""#, #""ex":null"#, #""ex":true"#, #""ex":-0"#,
                         #""ex":1.0"#, #""xp":2"#, #""xp":-1"#, #""xp":1.0"#, #""xp":true"#, #""xp":null"#, #""xp":"1""#] {
            assertCode(json(encryptor, extra: "," + fragment), "bad_descriptor", fragment)
        }
    }

    func testUnknownMembersAreIgnoredAndADuplicateIsRejected() throws {
        let encryptor = try makeEncryptor()
        let extra = try FileV2Descriptor.parse(json(encryptor, extra: #","future":{"a":[1,2,{"b":null}]},"x":1.5,"y":1e400"#))
        XCTAssertEqual(extra.size, 1023)
        // No "last one wins" and no "first one wins": a repeated member name is rejected, known or unknown.
        assertCode(json(encryptor, kind: "image", extra: #","kind":"video""#), "bad_descriptor", "duplicate kind")
        assertCode(json(encryptor, extra: #","a":1,"a":2"#), "bad_descriptor", "duplicate unknown member")
        assertCode(json(encryptor, source: #"{"via":"direct","via":"direct"}"#), "bad_descriptor", "duplicate via")
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
        // The fields are checked before the header: a bad field and a wrong header is bad_descriptor.
        assertCode(withHeader(commitment).replacingOccurrences(of: #""kind":"file""#, with: #""kind":"nope""#),
                   "bad_descriptor", "field error before header error")
    }

    func testDescriptorDescriptionNeverPrintsTheKey() throws {
        let encryptor = try makeEncryptor()
        let descriptor = try FileV2Descriptor.parse(json(encryptor))
        let text = "\(descriptor) \(String(describing: descriptor)) \(String(reflecting: descriptor))"
        XCTAssertFalse(text.contains(Support.hexString(descriptor.fileKey)))
        XCTAssertFalse(text.contains(b64(descriptor.fileKey)))
        XCTAssertTrue(text.contains("kind: file"))
    }

    // MARK: Not JSON

    func testNotJsonIsBadDescriptor() throws {
        let encryptor = try makeEncryptor()
        let good = json(encryptor)
        let cases: [(String, String)] = [
            ("", "empty"), ("null", "null"), ("[]", "array"), ("2", "number"), (#""x""#, "string"),
            (good + "x", "trailing garbage"), (good + "{}", "two values"),
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
        for (text, label) in cases {
            assertCode(text, "bad_descriptor", label)
        }
        assertParses(good + " ", "trailing space is fine")
        assertParses("  \n\t" + good + "\r\n", "surrounding whitespace is fine")
        // Depth limit 4: th.src.tok and th.m.wave are the deepest legitimate descriptors. Deeper nesting, in an unknown
        // member too, is rejected and never blows the stack.
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        assertCode(json(encryptor, extra: #","d":\#(deep)"#), "bad_descriptor", "depth 200")
        assertParses(json(encryptor, extra: #","d":[[[]]]"#), "three nested arrays make depth 4")
        assertCode(json(encryptor, extra: #","d":[[[[]]]]"#), "bad_descriptor", "four nested arrays make depth 5")
    }
}

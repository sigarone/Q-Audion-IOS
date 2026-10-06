import XCTest
@testable import QAudionEngine

/// The pieces of the strict profile of section 12.7 on their own, beyond the KAT vectors: the UTF-8 validator, the
/// integers of the format, the JSON parser (names compared as bytes, depth, surrogates, numbers kept as tokens), the
/// canonical base64, recognition and the control messages, and the canonical builders.
final class FileV2ProfileTests: XCTestCase {

    private typealias Support = FileV2TestSupport

    private func parse(_ text: String) -> Result<FileV2JSONObject, FileV2JSONFailure> {
        FileV2JSONParser.parse(Array(text.utf8))
    }

    private func failure(_ text: String) -> FileV2JSONFailure? { failure(bytes: Array(text.utf8)) }

    private func failure(bytes: [UInt8]) -> FileV2JSONFailure? {
        if case .failure(let reason) = FileV2JSONParser.parse(bytes) { return reason }
        return nil
    }

    // MARK: UTF-8

    func testUtf8ValidatorAcceptsExactlyTheWellFormedSequences() {
        let valid: [[UInt8]] = [[], [0x41], [0x00], [0x7F], [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80],
                                [0xE2, 0x82, 0xAC], [0xED, 0x9F, 0xBF], [0xEE, 0x80, 0x80], [0xEF, 0xBB, 0xBF],
                                [0xEF, 0xBF, 0xBD], [0xF0, 0x90, 0x80, 0x80], [0xF0, 0x9F, 0x98, 0x80],
                                [0xF4, 0x8F, 0xBF, 0xBF]]
        for bytes in valid { XCTAssertTrue(FileV2UTF8.isValid(bytes), "\(bytes)") }
        let invalid: [[UInt8]] = [[0x80], [0xBF], [0xC0, 0x80], [0xC1, 0xBF], [0xE0, 0x80, 0x80], [0xE0, 0x9F, 0xBF],
                                  [0xED, 0xA0, 0x80], [0xED, 0xBF, 0xBF], [0xF0, 0x80, 0x80, 0x80],
                                  [0xF0, 0x8F, 0xBF, 0xBF], [0xF4, 0x90, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
                                  [0xFF], [0xFE], [0xC2], [0xE2, 0x82], [0xF0, 0x9F, 0x98], [0xC2, 0x41],
                                  [0xE2, 0x82, 0x41], [0xE2, 0x41, 0xAC], [0xF0, 0x9F, 0x41, 0x80], [0x41, 0xC2]]
        for bytes in invalid { XCTAssertFalse(FileV2UTF8.isValid(bytes), "\(bytes)") }
    }

    /// Every Unicode scalar value: valid, and the same bytes as the standard library produces.
    func testUtf8ValidatorAndEncoderAgreeWithTheStandardLibraryOnEveryScalar() {
        var mismatches = 0
        for value in UInt32(0)...0x10FFFF where !(0xD800...0xDFFF).contains(value) {
            guard let scalar = Unicode.Scalar(value) else { mismatches += 1; continue }
            let expected = Array(String(Character(scalar)).utf8)
            var produced: [UInt8] = []
            FileV2UTF8.append(scalar: value, to: &produced)
            if produced != expected || !FileV2UTF8.isValid(produced) { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0)
        // The surrogates are not scalar values: their three-byte forms are invalid.
        for value in stride(from: UInt32(0xD800), through: 0xDFFF, by: 0x7F) {
            let bytes = [UInt8(0xE0 | (value >> 12)), UInt8(0x80 | ((value >> 6) & 0x3F)), UInt8(0x80 | (value & 0x3F))]
            XCTAssertFalse(FileV2UTF8.isValid(bytes), "U+\(String(value, radix: 16))")
        }
    }

    // MARK: Integers

    func testIntegersOfTheFormatArePlainDecimalOnly() {
        func integer(_ text: String) -> Int64? { FileV2JSONInteger.parse(Array(text.utf8)) }
        XCTAssertEqual(integer("0"), 0)
        XCTAssertEqual(integer("2"), 2)
        XCTAssertEqual(integer("-1"), -1)
        XCTAssertEqual(integer("1023"), 1023)
        XCTAssertEqual(integer("9007199254740991"), FileV2.maxJSONInteger)
        XCTAssertEqual(integer("-9007199254740991"), -FileV2.maxJSONInteger)
        for text in ["", "-", "+1", "01", "-0", "00", "1.0", "1e0", "1E0", "2.5", "9007199254740992", "-9007199254740992",
                     "9223372036854775807", "9223372036854775808", "18446744073709551616", String(repeating: "9", count: 400),
                     " 1", "1 ", "1_000", "0x10", "\u{661}", "\u{FF12}", "1\u{663}", "1\n"] {
            XCTAssertNil(integer(text), "\(text.debugDescription) is not an integer of the format")
        }
    }

    // MARK: JSON

    func testNamesAreComparedAsBytesWithoutNormalisation() throws {
        // The precomposed and the decomposed form of a letter are two names, and a Swift String comparison would
        // call them equal: the parser works on bytes.
        let object = try parse("{\"\u{E9}\":1,\"e\u{301}\":2}").get()
        XCTAssertEqual(object.members.count, 2)
        // The Kelvin sign U+212A is not K.
        XCTAssertEqual(try parse("{\"\u{212A}\":1,\"K\":2}").get().members.count, 2)
        // __proto__ and constructor are ordinary names.
        XCTAssertEqual(try parse(#"{"__proto__":1,"constructor":2}"#).get().members.count, 2)
        // A name written with an escape equals the same name written raw: a duplicate.
        XCTAssertEqual(failure(#"{"a":1,"\u0061":2}"#), .duplicateMember)
        XCTAssertEqual(failure(#"{"\ud83d\ude00":1,"😀":2}"#), .duplicateMember)
        XCTAssertEqual(failure("{\"\u{E9}\":1,\"\u{E9}\":2}"), .duplicateMember)
        XCTAssertEqual(failure(#"{"__proto__":1,"__proto__":2}"#), .duplicateMember)
        // At every depth.
        XCTAssertEqual(failure(#"{"a":{"b":1,"b":2}}"#), .duplicateMember)
        XCTAssertEqual(failure(#"{"a":[{"b":1,"b":2}]}"#), .duplicateMember)
        // Lookup is by bytes too.
        let kelvin = try parse("{\"\u{212A}\":1}").get()
        XCTAssertNil(kelvin.value("K"))
        XCTAssertNotNil(try parse(#"{"K":1}"#).get().value("K"))
    }

    func testDepthIsAtMostFourNestedContainers() {
        // The top-level object is depth 1; each object or array inside adds one.
        XCTAssertNil(failure(#"{"a":1}"#), "depth 1")
        XCTAssertNil(failure(#"{"a":{"b":{"c":1}}}"#), "depth 3")
        XCTAssertNil(failure(#"{"a":[[[]]]}"#), "depth 4: th.m.wave")
        XCTAssertNil(failure(#"{"a":{"b":{"c":{}}}}"#), "depth 4: th.src.tok")
        XCTAssertNil(failure(#"{"a":{"b":{"c":{"d":1}}}}"#), "still depth 4: the scalar is not a container")
        XCTAssertEqual(failure(#"{"a":{"b":{"c":{"d":{}}}}}"#), .depth)
        XCTAssertEqual(failure(#"{"a":[[[[]]]]}"#), .depth)
        XCTAssertEqual(failure(#"{"a":[{"b":[[]]}]}"#), .depth)
        XCTAssertEqual(failure("[[[[[]]]]]"), .depth)
        let deep = "{\"a\":" + String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000) + "}"
        XCTAssertEqual(failure(deep), .tooLarge, "the size limit comes first and nothing recurses")
        XCTAssertEqual(failure("{\"a\":" + String(repeating: "[", count: 500) + String(repeating: "]", count: 500) + "}"), .depth)
    }

    func testSurrogateEscapesMustBePairs() throws {
        XCTAssertEqual(failure(#"{"a":"\ud800"}"#), .loneSurrogate)
        XCTAssertEqual(failure(#"{"a":"\udc00"}"#), .loneSurrogate)
        XCTAssertEqual(failure(#"{"a":"\ud800\u0041"}"#), .loneSurrogate)
        XCTAssertEqual(failure(#"{"a":"\ud800x"}"#), .loneSurrogate)
        XCTAssertEqual(failure(#"{"a":"\udc00\ud800"}"#), .loneSurrogate)
        XCTAssertEqual(failure(#"{"a":"\ud83d"#), .loneSurrogate, "a lone surrogate before the end of the text")
        let pair = try parse(#"{"a":"\ud83d\ude00\u00e9\u20AC"}"#).get()
        guard case .string(let bytes)? = pair.value("a") else { return XCTFail("a string") }
        XCTAssertEqual(bytes, Array("\u{1F600}\u{E9}\u{20AC}".utf8))
    }

    func testNumbersStayTokensAndAreNeverConverted() throws {
        let text = "{\"a\":1e400,\"b\":-0,\"c\":\(String(repeating: "7", count: 400)),\"d\":0.5E-3,\"e\":-12}"
        let object = try parse(text).get()
        func token(_ name: String) -> [UInt8]? {
            if case .number(let bytes)? = object.value(name) { return bytes }
            return nil
        }
        XCTAssertEqual(token("a"), Array("1e400".utf8))
        XCTAssertEqual(token("b"), Array("-0".utf8))
        XCTAssertEqual(token("c"), Array(String(repeating: "7", count: 400).utf8))
        XCTAssertEqual(token("d"), Array("0.5E-3".utf8))
        XCTAssertEqual(token("e"), Array("-12".utf8))
        // The number grammar of RFC 8259.
        for bad in ["01", "1.", ".5", "-", "+1", "1e", "1e+", "0x1", "NaN", "Infinity", "-Infinity", "--1"] {
            XCTAssertNotNil(failure("{\"a\":\(bad)}"), bad)
        }
    }

    func testTheProfileAroundTheObject() {
        XCTAssertNil(failure(" \t\r\n{\"a\":1}\n "))
        XCTAssertEqual(failure("[]"), .notAnObject)
        XCTAssertEqual(failure("\"x\""), .notAnObject)
        XCTAssertEqual(failure("null"), .notAnObject)
        XCTAssertEqual(failure(""), .syntax)
        XCTAssertEqual(failure("{\"a\":1} x"), .syntax)
        XCTAssertEqual(failure("{\"a\":1}{}"), .syntax)
        XCTAssertEqual(failure("{\"a\":1,}"), .syntax)
        XCTAssertEqual(failure("\u{FEFF}{\"a\":1}"), .syntax, "a byte order mark is not JSON whitespace")
        XCTAssertEqual(failure("{\"a\":\"x\ny\"}"), .syntax, "a raw control character inside a string")
        XCTAssertEqual(failure("{\"a\":\"\\q\"}"), .syntax)
        // Invalid UTF-8 is not substituted: it is rejected, before any parsing.
        XCTAssertEqual(failure(bytes: [0x7B, 0x22, 0x61, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D]), .invalidUTF8)
        // The limit is on bytes: 8191 parse, 8192 do not.
        func sized(_ total: Int) -> [UInt8] { Array(("{\"p\":\"" + String(repeating: "x", count: total - 8) + "\"}").utf8) }
        XCTAssertEqual(sized(8191).count, 8191)
        XCTAssertNil(failure(bytes: sized(8191)), "8191 bytes")
        XCTAssertEqual(failure(bytes: sized(8192)), .tooLarge)
        XCTAssertEqual(failure(bytes: sized(8193)), .tooLarge)
    }

    // MARK: Base64

    func testBase64Decoder() {
        // RFC 4648 section 10.
        let vectors: [(String, String)] = [("", ""), ("Zg==", "f"), ("Zm8=", "fo"), ("Zm9v", "foo"), ("Zm9vYg==", "foob"),
                                           ("Zm9vYmE=", "fooba"), ("Zm9vYmFy", "foobar")]
        for (encoded, plain) in vectors {
            XCTAssertEqual(FileV2Base64.decode(encoded), Data(plain.utf8), encoded)
        }
        XCTAssertEqual(FileV2Base64.decode("+/+/"), Data([0xFB, 0xFF, 0xBF]))
        for bad in ["Zg=", "Zg", "Zm9", "Zg==Zg==", "Z===", "====", "Zm9v\n", "Zm 9v", "Zm9-", "Zm9_", "Zm=v", "=Zm9",
                    "Zm9vY", "Zg==\n", "\nZm9v", "Zm9v\r\n", "Zm\u{200B}9v", "Zg=\u{3D}=", "Zm9\u{FF1D}"] {
            XCTAssertNil(FileV2Base64.decode(bad), "\(bad.debugDescription) must be refused")
        }
        // Canonical: the unused trailing bits are zero. "Zh==" and "Zm9=" carry bits that the bytes do not have; a
        // lenient decoder reads them as "f" and "fo", but each byte string has exactly ONE accepted text.
        XCTAssertNil(FileV2Base64.decode("Zh=="), "second sextet of a 1-byte tail: low 4 bits must be zero")
        XCTAssertNil(FileV2Base64.decode("Zi=="))
        XCTAssertNil(FileV2Base64.decode("Zm9="), "third sextet of a 2-byte tail: low 2 bits must be zero")
        XCTAssertNil(FileV2Base64.decode("Zm+="))
        XCTAssertEqual(FileV2Base64.decode("Zm8="), Data("fo".utf8))
        // Round trip with the system encoder for every length from 0 to 70.
        for length in 0...70 {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 11) & 0xFF) })
            XCTAssertEqual(FileV2Base64.decode(data.base64EncodedString()), data, "length \(length)")
            XCTAssertEqual(FileV2Base64.encode(data), data.base64EncodedString())
        }
    }

    /// Canonical, exhaustively: for EVERY final group with padding, a text is accepted if and only if it is exactly the text
    /// the encoder writes for the bytes it decodes to. A lenient decoder accepts 64 texts for each 1-byte tail and 4 for
    /// each 2-byte tail; this one accepts one.
    func testBase64AcceptsOneTextPerByteString() {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        let pad = UInt8(ascii: "=")
        var acceptedOneByte = 0, acceptedTwoBytes = 0
        for first in alphabet {
            for second in alphabet {
                let oneByte: [UInt8] = [first, second, pad, pad]
                if let decoded = FileV2Base64.decode(oneByte) {
                    acceptedOneByte += 1
                    XCTAssertEqual(decoded.count, 1)
                    XCTAssertEqual(Array(decoded.base64EncodedString().utf8), oneByte)
                }
                for third in alphabet {
                    let twoBytes: [UInt8] = [first, second, third, pad]
                    if let decoded = FileV2Base64.decode(twoBytes) {
                        acceptedTwoBytes += 1
                        XCTAssertEqual(decoded.count, 2)
                        XCTAssertEqual(Array(decoded.base64EncodedString().utf8), twoBytes)
                    }
                }
            }
        }
        XCTAssertEqual(acceptedOneByte, 256, "one text for each of the 256 one-byte strings")
        XCTAssertEqual(acceptedTwoBytes, 65_536, "one text for each of the 65536 two-byte strings")
    }

    // MARK: Recognition

    func testRecognitionIsAPureBytePrefixTest() throws {
        let encryptor = try FileV2Encryptor(fileKey: Data(repeating: 1, count: 32), fileID: Data(repeating: 2, count: 16),
                                            plaintextSize: 10)
        let input = FileV2DescriptorInput(file: FileV2FileInput(encryptor: encryptor, kind: .file,
                                                                source: .init(via: .direct)))
        let body = try FileV2DescriptorBuilder.build(input)
        guard case .descriptor(let descriptor) = FileV2Message.recognize(body) else { return XCTFail("a descriptor") }
        XCTAssertEqual(descriptor.fileID, encryptor.fileID)
        XCTAssertTrue(FileV2Message.hasFileMessagePrefix(body))
        // The same text with anything in front of the prefix is chat text, whatever else it contains.
        for prefix in [" ", "\n", "\u{FEFF}", "x", "{\"x\":1,"] {
            let text = prefix + body
            guard case .text = FileV2Message.recognize(text) else { return XCTFail("text after \(prefix.debugDescription)") }
            XCTAssertFalse(FileV2Message.hasFileMessagePrefix(text))
        }
        // User text that begins with a prefix is refused as an ordinary message.
        for typed in [#"{"qa_file":"#, #"{"qa_file_src":"#, #"{"qa_file_cancel":"#, #"{"qa_file":9,"x":"hello"}"#] {
            XCTAssertTrue(FileV2Message.hasFileMessagePrefix(typed), typed)
        }
        for typed in ["hello", "", "{", #"{"qa_file""#, #"{"qa_files":2"#, #"{"qa_file_x":2"#, #" {"qa_file":2"#] {
            XCTAssertFalse(FileV2Message.hasFileMessagePrefix(typed), typed)
        }
        // A rejected, recognised body is never text.
        guard case .rejected(.descriptor, .unsupportedVersion) = FileV2Message.recognize(#"{"qa_file":3,"x":1}"#) else {
            return XCTFail("version 3")
        }
    }

    func testControlMessagesRoundTripThroughTheBuilders() throws {
        let fileID = Data((0..<16).map { UInt8($0 + 1) })
        let source = FileV2Descriptor.Source(
            via: .srv, obj: "343a95c1-f56d-432d-9de4-78cf3473327d",
            token: FileV2Descriptor.Token(v: String(repeating: "0f", count: 32), exp: 1_760_000_000_000, max: 100))
        let sourceBody = try FileV2DescriptorBuilder.buildSource(fileID: fileID, source: source)
        XCTAssertTrue(Array(sourceBody.utf8).starts(with: Array(#"{"qa_file_src":2,"id":""#.utf8)))
        guard case .source(let message) = FileV2Message.recognize(sourceBody) else { return XCTFail("a source message") }
        XCTAssertEqual(message.fileID, fileID)
        XCTAssertEqual(message.source, source)

        let cancelBody = try FileV2DescriptorBuilder.buildCancel(fileID: fileID)
        XCTAssertEqual(cancelBody, #"{"qa_file_cancel":2,"id":"AQIDBAUGBwgJCgsMDQ4PEA=="}"#)
        guard case .cancel(let cancel) = FileV2Message.recognize(cancelBody) else { return XCTFail("a cancel message") }
        XCTAssertEqual(cancel.fileID, fileID)

        // Other members are ignored; a rejected control message is `rejected` (the caller drops it silently).
        guard case .cancel = FileV2Message.recognize(#"{"qa_file_cancel":2,"id":"AQIDBAUGBwgJCgsMDQ4PEA==","why":"x"}"#) else {
            return XCTFail("unknown members are ignored")
        }
        for (text, code) in [(#"{"qa_file_cancel":2,"id":"AQID"}"#, "bad_descriptor"),
                             (#"{"qa_file_cancel":2}"#, "bad_descriptor"),
                             (#"{"qa_file_cancel":2.0,"id":"AQIDBAUGBwgJCgsMDQ4PEA=="}"#, "bad_descriptor"),
                             (#"{"qa_file_cancel":2,"id":"AQIDBAUGBwgJCgsMDQ4PEA==","id":"AQIDBAUGBwgJCgsMDQ4PEA=="}"#, "bad_descriptor"),
                             (#"{"qa_file_cancel":4,"id":"AQIDBAUGBwgJCgsMDQ4PEA=="}"#, "unsupported_version"),
                             (#"{"qa_file_src":2,"id":"AQIDBAUGBwgJCgsMDQ4PEA=="}"#, "bad_descriptor"),
                             (#"{"qa_file_src":2,"id":"AQIDBAUGBwgJCgsMDQ4PEA==","src":{"via":"srv"}}"#, "bad_descriptor"),
                             (#"{"qa_file_src":1,"id":"AQIDBAUGBwgJCgsMDQ4PEA==","src":{"via":"direct"}}"#, "unsupported_version")] {
            guard case .rejected(_, let error) = FileV2Message.recognize(text) else { return XCTFail(text) }
            XCTAssertEqual(error.code, code, text)
        }
        // The builders refuse an id of the wrong length.
        XCTAssertThrowsError(try FileV2DescriptorBuilder.buildCancel(fileID: Data(count: 15)))
        XCTAssertThrowsError(try FileV2DescriptorBuilder.buildSource(fileID: Data(count: 17), source: source))
    }

    // MARK: The canonical builder

    private func input(_ encryptor: FileV2Encryptor, kind: FileV2Descriptor.Kind = .file,
                       source: FileV2Descriptor.Source = .init(via: .direct)) -> FileV2FileInput {
        FileV2FileInput(encryptor: encryptor, kind: kind, source: source)
    }

    func testBuilderCutsAtACharacterBoundaryOnRawBytes() {
        let cut = FileV2DescriptorBuilder.cut
        XCTAssertNil(cut(nil, 255))
        XCTAssertNil(cut("", 255))
        XCTAssertEqual(cut("abc", 255), "abc")
        XCTAssertEqual(cut(String(repeating: "a", count: 300), 255).map { $0.utf8.count }, 255)
        // Two-byte characters: 255 is odd, so the cut falls inside a character and goes back one byte.
        XCTAssertEqual(cut(String(repeating: "\u{E9}", count: 200), 255).map { $0.utf8.count }, 254)
        // A four-byte character that does not fit goes whole; one that fits exactly stays.
        XCTAssertEqual(cut(String(repeating: "a", count: 253) + "\u{1F600}", 255).map { $0.utf8.count }, 253)
        XCTAssertEqual(cut(String(repeating: "a", count: 251) + "\u{1F600}", 255).map { $0.utf8.count }, 255)
        XCTAssertEqual(cut(String(repeating: "a", count: 252) + "\u{20AC}", 255).map { $0.utf8.count }, 255)
        XCTAssertEqual(cut(String(repeating: "a", count: 253) + "\u{20AC}", 255).map { $0.utf8.count }, 253)
        // The cut never splits a Unicode scalar value (it may split a grapheme cluster: that is the rule).
        XCTAssertEqual(cut("e\u{301}e\u{301}", 4).map { Array($0.unicodeScalars).count }, 3)
        XCTAssertEqual(cut(String(repeating: "\u{1F600}", count: 100), 128).map { $0.utf8.count }, 128)
        XCTAssertEqual(cut(String(repeating: "\u{1F600}", count: 100), 126).map { $0.utf8.count }, 124)
        XCTAssertNil(cut("\u{1F600}", 3), "nothing fits: absent")
    }

    func testBuilderWritesTheEscapingOfTheSpecAndNothingMore() throws {
        let encryptor = try FileV2Encryptor(fileKey: Data(repeating: 1, count: 32), fileID: Data(repeating: 2, count: 16),
                                            plaintextSize: 10)
        var file = input(encryptor)
        file.name = "a\"b\\c/d" + "\u{8}\u{C}\n\r\t" + "\u{1}\u{1F}\u{7F}" + "<>&" + "\u{2028}\u{2029}" + "\u{E9}\u{1F600}"
        let text = try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: file))
        let expected = #""nm":"a\"b\\c/d\b\f\n\r\t\u0001\u001f"# + "\u{7F}<>&\u{2028}\u{2029}\u{E9}\u{1F600}\""
        XCTAssertTrue(text.contains(expected), text)
        // The receiver gives the name back exactly.
        guard case .descriptor(let parsed) = FileV2Message.recognize(text) else { return XCTFail("a descriptor") }
        XCTAssertEqual(Support.utf8(parsed.name), Support.utf8(file.name))
    }

    func testBuilderRefusesValuesOutsideTheFieldTable() throws {
        let encryptor = try FileV2Encryptor(fileKey: Data(repeating: 1, count: 32), fileID: Data(repeating: 2, count: 16),
                                            plaintextSize: 10)
        let thumbnailEncryptor = try FileV2Encryptor(fileKey: Data(repeating: 3, count: 32),
                                                     fileID: Data(repeating: 4, count: 16), plaintextSize: 500)
        func build(_ change: (inout FileV2FileInput) -> Void) throws -> String {
            var file = input(encryptor)
            change(&file)
            return try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: file))
        }
        XCTAssertNoThrow(try build { _ in })
        let objectID = "343a95c1-f56d-432d-9de4-78cf3473327d"
        let token = FileV2Descriptor.Token(v: String(repeating: "ab", count: 32), exp: 0, max: 0)
        let refusals: [(String, (inout FileV2FileInput) -> Void)] = [
            ("id length", { $0.fileID = Data(count: 15) }),
            ("key length", { $0.fileKey = Data(count: 31) }),
            ("header length", { $0.header = Data(count: 63) }),
            ("size 0", { $0.size = 0 }),
            ("size above 5 GiB", { $0.size = FileV2.maxSize + 1 }),
            ("size that does not match the header", { $0.size = 5000 }),
            ("another key than the header's", { $0.fileKey = Data(repeating: 9, count: 32) }),
            ("preview over 2048 bytes", { $0.preview = Data(count: 2049) }),
            ("server source without an object", { $0.source = .init(via: .srv, obj: nil, token: token) }),
            ("object id in upper case", { $0.source = .init(via: .srv, obj: objectID.uppercased(), token: token) }),
            ("object id of 32 hex digits", { $0.source = .init(via: .srv, obj: String(repeating: "a", count: 32)) }),
            ("token value too short", { $0.source = .init(via: .srv, obj: objectID, token: .init(v: "ab", exp: 0, max: 0)) }),
            ("token value in upper case", { $0.source = .init(via: .srv, obj: objectID,
                                                               token: .init(v: String(repeating: "AB", count: 32), exp: 0, max: 0)) }),
            ("token exp negative", { $0.source = .init(via: .srv, obj: objectID,
                                                        token: .init(v: token.v, exp: -1, max: 0)) }),
            ("token max above int32", { $0.source = .init(via: .srv, obj: objectID,
                                                           token: .init(v: token.v, exp: 0, max: 1 << 31)) }),
            ("media integer above 2^53 - 1", { $0.media = .init(w: 1 << 53) }),
            ("wave integer below -(2^53 - 1)", { $0.media = .init(wave: [-(1 << 53)]) }),
            ("ex below -1", { $0.ex = -2 }),
            ("ex above int32", { $0.ex = 1 << 31 }),
            ("xp 2", { $0.xp = 2 }),
            ("xp -1", { $0.xp = -1 })
        ]
        for (label, change) in refusals {
            XCTAssertThrowsError(try build(change), label) { error in
                guard case FileV2Error.invalidArgument = error else { return XCTFail("\(label): \(error)") }
            }
        }
        // The thumbnail: kind thumb, another file, and no thumbnail of its own.
        var thumbnail = input(thumbnailEncryptor, kind: .thumb)
        XCTAssertNoThrow(try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: input(encryptor), thumbnail: thumbnail)))
        thumbnail.kind = .image
        XCTAssertThrowsError(try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: input(encryptor), thumbnail: thumbnail)))
        XCTAssertThrowsError(try FileV2DescriptorBuilder.build(
            FileV2DescriptorInput(file: input(encryptor), thumbnail: input(encryptor, kind: .thumb))), "th.id equals id")
        XCTAssertThrowsError(try FileV2DescriptorBuilder.build(
            FileV2DescriptorInput(file: input(encryptor, kind: .thumb), thumbnail: input(thumbnailEncryptor, kind: .thumb))),
                             "a thumbnail carries no th")
        // A closed encryptor has no key left to put in a descriptor.
        encryptor.close()
        XCTAssertThrowsError(try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: input(encryptor))))
    }

    func testBuiltDescriptorRoundTripsThroughTheReceiver() throws {
        let file = try FileV2Encryptor.makeNew(plaintextSize: 123_456)
        let thumbnail = try FileV2Encryptor.makeNew(plaintextSize: 9000)
        let objectID = "00112233-4455-4677-8899-aabbccddeeff"
        let source = FileV2Descriptor.Source(
            via: .srv, obj: objectID,
            token: FileV2Descriptor.Token(v: String(repeating: "1f", count: 32), exp: 9_007_199_254_740_991, max: 2_147_483_647))
        let fileInput = FileV2FileInput(encryptor: file, kind: .video, source: source, name: "film \u{1F3AC}.mp4",
                                        mimeType: "video/mp4", media: .init(w: 1920, h: 1080, dur: 5234, wave: [0, 3, 9]),
                                        preview: Data([1, 2, 3, 4, 5]), ex: -1, xp: 0)
        let text = try FileV2DescriptorBuilder.build(FileV2DescriptorInput(
            file: fileInput, thumbnail: FileV2FileInput(encryptor: thumbnail, kind: .thumb, source: .init(via: .direct))))
        guard case .descriptor(let parsed) = FileV2Message.recognize(text) else { return XCTFail("a descriptor") }
        XCTAssertEqual(parsed.fileID, file.fileID)
        XCTAssertEqual(parsed.fileKey, file.fileKey)
        XCTAssertEqual(parsed.header, file.header)
        XCTAssertEqual(parsed.size, 123_456)
        XCTAssertEqual(parsed.kind, .video)
        XCTAssertEqual(parsed.name, "film \u{1F3AC}.mp4")
        XCTAssertEqual(parsed.mimeType, "video/mp4")
        XCTAssertEqual(parsed.source, source)
        XCTAssertEqual(parsed.source.obj, objectID, "src.obj exactly as given")
        XCTAssertEqual(parsed.media, FileV2Descriptor.Media(w: 1920, h: 1080, dur: 5234, wave: [0, 3, 9]))
        XCTAssertEqual(parsed.preview, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(parsed.ex, -1)
        XCTAssertEqual(parsed.xp, 0)
        XCTAssertEqual(parsed.thumbnailStatus, .valid)
        XCTAssertEqual(parsed.thumbnail?.fileID, thumbnail.fileID)
        XCTAssertEqual(parsed.thumbnail?.source.via, .direct)
        XCTAssertTrue(Array(text.utf8).starts(with: Array(#"{"qa_file":2,"id":""#.utf8)))
    }
}

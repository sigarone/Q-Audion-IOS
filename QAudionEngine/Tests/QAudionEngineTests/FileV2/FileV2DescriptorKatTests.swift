import XCTest
@testable import QAudionEngine

// swiftlint:disable identifier_name

/// The strict descriptor profile of WIRE_SPEC 12.7.1 to 12.7.6, against the four sections of the shared vector file
/// that pin it: `descriptor_constants`, `recognition`, `descriptor_rules` and `builder_cases`. EVERY vector of every
/// section runs, with real assertions and pinned counts: a vector can never be dropped or filtered out without a
/// failure here. Bodies that are not valid UTF-8 (or that a text tool could alter, a byte order mark) are carried
/// as `serialized_b64` and are used as the raw BYTES they are.
///
/// Texts are compared as bytes everywhere: Swift compares `String`s by canonical equivalence, which would make a
/// precomposed and a decomposed name, or the Kelvin sign and `K`, "equal".
final class FileV2DescriptorKatTests: XCTestCase {

    private typealias Support = FileV2TestSupport

    // MARK: descriptor_constants

    func testDescriptorConstantsMatchTheLibrary() throws {
        let constants = try Support.loadKat().descriptor_constants
        XCTAssertEqual(constants.count, 16, "a constant was added to the KAT: assert it too")
        func integer(_ key: String) -> Int64? {
            if case .int(let value)? = constants[key] { return value }
            return nil
        }
        func text(_ key: String) -> [UInt8]? {
            if case .text(let value)? = constants[key] { return Array(value.utf8) }
            return nil
        }
        XCTAssertEqual(integer("DESCRIPTOR_MAX_BYTES"), Int64(FileV2.maxDescriptorBytes))
        XCTAssertEqual(integer("DESCRIPTOR_MAX_DEPTH"), Int64(FileV2.maxDescriptorDepth))
        XCTAssertEqual(integer("EX_MAX"), FileV2.maxEx)
        XCTAssertEqual(integer("EX_MIN"), FileV2.minEx)
        XCTAssertEqual(integer("MAX_JSON_INT"), FileV2.maxJSONInteger)
        XCTAssertEqual(integer("MIME_MAX_BYTES"), Int64(FileV2.maxMimeBytes))
        XCTAssertEqual(integer("NAME_MAX_BYTES"), Int64(FileV2.maxNameBytes))
        XCTAssertEqual(integer("OBJ_ID_LEN"), Int64(FileV2.objectIDLength))
        XCTAssertEqual(integer("PREVIEW_MAX_BYTES"), Int64(FileV2.maxPreviewBytes))
        XCTAssertEqual(integer("TOKEN_MAX_MAX"), FileV2.maxTokenMax)
        XCTAssertEqual(integer("TOKEN_V_HEX_LEN"), Int64(FileV2.tokenValueHexLength))
        XCTAssertEqual(integer("VERSION"), FileV2.descriptorVersion)
        XCTAssertEqual(text("PREFIX_DESCRIPTOR"), FileV2Message.descriptorPrefix)
        XCTAssertEqual(text("PREFIX_SRC"), FileV2Message.sourcePrefix)
        XCTAssertEqual(text("PREFIX_CANCEL"), FileV2Message.cancelPrefix)
        XCTAssertEqual(FileV2.maxJSONInteger, 9_007_199_254_740_991)
        XCTAssertEqual(FileV2.maxEx, 2_147_483_647)

        // The object id pattern: the library's check and the regular expression of the vector file agree.
        let pattern = try XCTUnwrap(text("OBJ_ID_PATTERN").map { String(decoding: $0, as: UTF8.self) })
        let expression = try NSRegularExpression(pattern: pattern)
        // (A trailing newline is a vector of its own, `src_obj_trailing_newline`: ICU's `$` would match before it.)
        let samples = ["343a95c1-f56d-432d-9de4-78cf3473327d", "00000000-0000-0000-0000-000000000000",
                       "343A95C1-F56D-432D-9DE4-78CF3473327D", "343a95c1f56d432d9de478cf3473327d",
                       "343a95c1-f56d-432d-9de4-78cf3473327", "343a95c1-f56d-432d-9de4-78cf3473327de",
                       "343a95c1-f56d-432d-9de4-78cf3473327g", "343a95c1-f56d4-32d-9de4-78cf3473327d",
                       "", "../../etc/passwd"]
        for sample in samples {
            let range = NSRange(sample.startIndex..., in: sample)
            let byRegex = expression.firstMatch(in: sample, options: [], range: range) != nil
            XCTAssertEqual(FileV2Descriptor.isValidObjectID(Array(sample.utf8)), byRegex, "object id \(sample.debugDescription)")
        }
    }

    // MARK: recognition

    /// The class and the outcome of a recognised body, in the words of the vectors.
    private func describe(_ message: FileV2Message) -> (kind: String, outcome: String) {
        switch message {
        case .text: return ("text", "text")
        case .descriptor: return ("descriptor", "ok")
        case .source: return ("src", "ok")
        case .cancel: return ("cancel", "ok")
        case .rejected(let kind, let error):
            switch kind {
            case .descriptor: return ("descriptor", error.code)
            case .source: return ("src", error.code)
            case .cancel: return ("cancel", error.code)
            }
        }
    }

    func testEveryRecognitionVector() throws {
        let kat = try Support.loadKat()
        XCTAssertEqual(kat.recognition.count, 79)
        var fromBase64 = 0
        var byOutcome: [String: Int] = [:]
        var byClass: [String: Int] = [:]
        for vector in kat.recognition {
            let body = try Support.bodyBytes(name: vector.name, serialized: vector.serialized,
                                             serializedB64: vector.serialized_b64)
            if vector.serialized_b64 != nil { fromBase64 += 1 }
            let result = FileV2Message.recognize(utf8: body)
            let answer = describe(result)
            XCTAssertEqual(answer.kind, vector.class, "\(vector.name): class")
            XCTAssertEqual(answer.outcome, vector.expect, "\(vector.name): \(vector.why)")
            // The prefix test alone (no parsing) is what decides "a file message, never text".
            XCTAssertEqual(FileV2Message.hasFileMessagePrefix(body), vector.class != "text",
                           "\(vector.name): prefix test")
            byOutcome[vector.expect, default: 0] += 1
            byClass[vector.class, default: 0] += 1

            // A valid file message carries what it says.
            switch result {
            case .descriptor(let descriptor): XCTAssertEqual(descriptor.size, 1023, vector.name)
            case .source(let message): XCTAssertEqual(message.fileID.count, 16, vector.name)
            case .cancel(let message): XCTAssertEqual(message.fileID.count, 16, vector.name)
            default: break
            }
        }
        XCTAssertEqual(fromBase64, 4, "bodies carried as serialized_b64")
        XCTAssertEqual(byOutcome, ["ok": 8, "text": 16, "unsupported_version": 17, "bad_descriptor": 37,
                                   "commit_mismatch": 1])
        XCTAssertEqual(byClass, ["descriptor": 45, "text": 16, "src": 11, "cancel": 7])
    }

    // MARK: descriptor_rules

    private func assertNormalized(_ descriptor: FileV2Descriptor, _ expected: FileV2Kat.Normalized, _ label: String) {
        XCTAssertEqual(descriptor.size, expected.sz, "\(label): sz")
        XCTAssertEqual(descriptor.kind.rawValue, expected.kind, "\(label): kind")
        XCTAssertEqual(Support.utf8(descriptor.name), Support.utf8(expected.nm), "\(label): nm")
        XCTAssertEqual(Support.utf8(descriptor.mimeType), Support.utf8(expected.mt), "\(label): mt")
        XCTAssertEqual(descriptor.preview?.count, expected.pv_len, "\(label): pv_len")
        XCTAssertEqual(descriptor.source.via.rawValue, expected.src.via, "\(label): src.via")
        XCTAssertEqual(Support.utf8(descriptor.source.obj), Support.utf8(expected.src.obj), "\(label): src.obj")
        if let token = expected.src.tok {
            XCTAssertEqual(Support.utf8(descriptor.source.token?.v), Support.utf8(token.v), "\(label): tok.v")
            XCTAssertEqual(descriptor.source.token?.exp, token.exp, "\(label): tok.exp")
            XCTAssertEqual(descriptor.source.token?.max, token.max, "\(label): tok.max")
        } else {
            XCTAssertNil(descriptor.source.token, "\(label): tok")
        }
        if let media = expected.media {
            XCTAssertNotNil(descriptor.media, "\(label): m is used")
            XCTAssertEqual(descriptor.media?.w, media.w, "\(label): m.w")
            XCTAssertEqual(descriptor.media?.h, media.h, "\(label): m.h")
            XCTAssertEqual(descriptor.media?.dur, media.dur, "\(label): m.dur")
            XCTAssertEqual(descriptor.media?.wave, media.wave, "\(label): m.wave")
        } else {
            XCTAssertNil(descriptor.media, "\(label): m is absent or ignored")
        }
        switch expected.thumbnail {
        case "absent":
            XCTAssertEqual(descriptor.thumbnailStatus, .absent, label)
            XCTAssertNil(descriptor.thumbnail, label)
        case "valid":
            XCTAssertEqual(descriptor.thumbnailStatus, .valid, label)
            XCTAssertEqual(descriptor.thumbnail?.kind, .thumb, label)
            XCTAssertEqual(descriptor.thumbnail?.thumbnailStatus, .absent, "\(label): a thumbnail has no th")
            XCTAssertNotEqual(descriptor.thumbnail?.fileID, descriptor.fileID, "\(label): th.id differs from id")
        case "bad_descriptor":
            // The file is valid and the thumbnail is not usable: bad_descriptor for the thumbnail only.
            XCTAssertEqual(descriptor.thumbnailStatus, .invalid, label)
            XCTAssertNil(descriptor.thumbnail, label)
        default:
            XCTFail("\(label): unknown thumbnail result \(expected.thumbnail)")
        }
        XCTAssertEqual(descriptor.ex, expected.ex, "\(label): ex")
        XCTAssertEqual(descriptor.xp, expected.xp, "\(label): xp")
    }

    func testEveryDescriptorRuleVector() throws {
        let kat = try Support.loadKat()
        XCTAssertEqual(kat.descriptor_rules.count, 254)
        var fromBase64 = 0
        var accepted = 0
        var thumbnails: [String: Int] = [:]
        var rejected: [String: Int] = [:]
        for vector in kat.descriptor_rules {
            let body = try Support.bodyBytes(name: vector.name, serialized: vector.serialized,
                                             serializedB64: vector.serialized_b64)
            if vector.serialized_b64 != nil { fromBase64 += 1 }
            if vector.expect == "ok" {
                guard let expected = vector.normalized else {
                    XCTFail("\(vector.name): an accepted vector states its normalised result")
                    continue
                }
                do {
                    let descriptor = try FileV2Descriptor.parse(utf8: body)
                    assertNormalized(descriptor, expected, vector.name)
                    thumbnails[expected.thumbnail, default: 0] += 1
                    accepted += 1
                } catch {
                    XCTFail("\(vector.name) must be accepted (\(vector.why)): \(error)")
                }
            } else {
                XCTAssertNil(vector.normalized, "\(vector.name): a rejected vector has no normalised result")
                XCTAssertThrowsError(try FileV2Descriptor.parse(utf8: body), "\(vector.name): \(vector.why)") { error in
                    XCTAssertEqual((error as? FileV2Error)?.code, vector.expect, "\(vector.name): \(vector.why)")
                }
                rejected[vector.expect, default: 0] += 1
            }
        }
        XCTAssertEqual(fromBase64, 8, "bodies carried as serialized_b64")
        XCTAssertEqual(accepted, 101)
        XCTAssertEqual(rejected, ["bad_descriptor": 150, "commit_mismatch": 2, "bad_header": 1])
        XCTAssertEqual(thumbnails, ["absent": 73, "valid": 6, "bad_descriptor": 22])
    }

    // MARK: serialized_b64

    func testEveryBodyIsEitherTextOrBase64AndTheBase64OnesAreRawBytes() throws {
        let kat = try Support.loadKat()
        let all: [(name: String, text: String?, encoded: String?)] =
            kat.recognition.map { (name: $0.name, text: $0.serialized, encoded: $0.serialized_b64) }
            + kat.descriptor_rules.map { (name: $0.name, text: $0.serialized, encoded: $0.serialized_b64) }
        XCTAssertEqual(all.count, 79 + 254)
        for body in all {
            XCTAssertTrue((body.text == nil) != (body.encoded == nil), "\(body.name): exactly one of the two forms")
        }
        func bytes(_ name: String) throws -> [UInt8] {
            let entry = try XCTUnwrap(all.first(where: { $0.name == name }), name)
            return [UInt8](try Support.bodyBytes(name: name, serialized: entry.text, serializedB64: entry.encoded))
        }
        // Not valid UTF-8: no `String` can hold them, and a substituting decoder would change them.
        let invalid = ["version_3_then_invalid_utf8", "prefix_then_invalid_utf8", "prefix_then_lone_surrogate_encoded",
                       "utf8_invalid_byte_in_nm", "utf8_truncated_sequence_in_nm", "utf8_overlong_encoding_in_nm",
                       "utf8_encoded_surrogate_in_nm", "utf8_above_max_code_point_in_nm",
                       "utf8_invalid_byte_in_unknown_member"]
        for name in invalid {
            XCTAssertFalse(FileV2UTF8.isValid(try bytes(name)), "\(name) is not valid UTF-8")
        }
        // A byte order mark: valid UTF-8 that a text tool could drop; the body keeps its three bytes.
        for name in ["bom_then_prefix", "byte_order_mark"] {
            XCTAssertEqual(Array(try bytes(name).prefix(3)), [0xEF, 0xBB, 0xBF], name)
        }
        // The same BOM character inside a string is just a character, and the body is accepted.
        XCTAssertTrue(FileV2UTF8.isValid(try bytes("nm_with_bom_character_inside_is_kept")))
        XCTAssertEqual(all.filter { $0.encoded != nil }.count, 4 + 8)
    }

    /// The pitfall the vectors pin: a decoder that substitutes U+FFFD first would turn an invalid body into a valid
    /// one. `parse(utf8:)` rejects the bytes; the same bytes through a `String` are accepted, which is why a receiver
    /// of chat messages never goes through a `String`.
    func testASubstitutingDecoderWouldHaveAcceptedTheInvalidBody() throws {
        let kat = try Support.loadKat()
        let vector = try XCTUnwrap(kat.descriptor_rules.first(where: { $0.name == "utf8_invalid_byte_in_nm" }))
        let body = try Support.bodyBytes(name: vector.name, serialized: vector.serialized,
                                         serializedB64: vector.serialized_b64)
        XCTAssertThrowsError(try FileV2Descriptor.parse(utf8: body)) {
            XCTAssertEqual(($0 as? FileV2Error)?.code, "bad_descriptor")
        }
        let substituted = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(substituted.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertNoThrow(try FileV2Descriptor.parse(substituted), "this is the lenient behaviour the profile forbids")
    }

    // MARK: builder_cases

    private func source(_ input: FileV2Kat.BuilderSource) throws -> FileV2Descriptor.Source {
        let via = try XCTUnwrap(FileV2Descriptor.Source.Via(rawValue: input.via))
        return FileV2Descriptor.Source(
            via: via, obj: input.obj,
            token: input.tok.map { FileV2Descriptor.Token(v: $0.v, exp: $0.exp, max: $0.max) })
    }

    private func fileInput(_ input: FileV2Kat.BuilderInput) throws -> FileV2FileInput {
        let keyHex = try XCTUnwrap(input.k_hex)
        let headerHex = try XCTUnwrap(input.h_hex)
        let size = try XCTUnwrap(input.sz)
        let kind = try XCTUnwrap(input.kind.flatMap { FileV2Descriptor.Kind(rawValue: $0) })
        // nm and mt come as text, or as UTF-16 code units for the platforms whose strings can hold an unpaired
        // surrogate. A Swift String cannot, so the code units are decoded the way a Swift platform decodes UTF-16 text
        // (each unpaired surrogate becomes U+FFFD) and the builder gets the resulting String.
        let name = input.nm_utf16.map { String(decoding: $0, as: UTF16.self) } ?? input.nm
        let mimeType = input.mt_utf16.map { String(decoding: $0, as: UTF16.self) } ?? input.mt
        let media = input.m.map { FileV2Descriptor.Media(w: $0.w, h: $0.h, dur: $0.dur, wave: $0.wave) }
        return FileV2FileInput(
            fileID: Support.hex(input.id_hex), fileKey: Support.hex(keyHex), header: Support.hex(headerHex), size: size,
            kind: kind, source: try source(try XCTUnwrap(input.src)), name: name, mimeType: mimeType, media: media,
            preview: input.pv_hex.map { Support.hex($0) }, ex: input.ex, xp: input.xp)
    }

    func testEveryBuilderCaseIsReproducedByteForByte() throws {
        let kat = try Support.loadKat()
        XCTAssertEqual(kat.builder_cases.count, 28)
        var byMessage: [String: Int] = [:]
        for vector in kat.builder_cases {
            let built: String
            switch vector.message {
            case "descriptor":
                let thumbnail = try vector.input.th.map { try fileInput($0) }
                XCTAssertNil(vector.input.th?.th, "\(vector.name): a thumbnail carries no th")
                built = try FileV2DescriptorBuilder.build(
                    FileV2DescriptorInput(file: try fileInput(vector.input), thumbnail: thumbnail))
            case "src":
                built = try FileV2DescriptorBuilder.buildSource(
                    fileID: Support.hex(vector.input.id_hex), source: try source(try XCTUnwrap(vector.input.src)))
            case "cancel":
                built = try FileV2DescriptorBuilder.buildCancel(fileID: Support.hex(vector.input.id_hex))
            default:
                XCTFail("\(vector.name): unknown message \(vector.message)")
                continue
            }
            byMessage[vector.message, default: 0] += 1
            XCTAssertTrue(Array(built.utf8) == Array(vector.expected.utf8),
                          "\(vector.name) (\(vector.why))\n built:    \(built)\n expected: \(vector.expected)")

            // The output of a builder is accepted by the receiver rules, and begins with the canonical prefix.
            let prefix: [UInt8]
            switch vector.message {
            case "descriptor": prefix = Array(#"{"qa_file":2,"id":"#.utf8)
            case "src": prefix = Array(#"{"qa_file_src":2,"id":"#.utf8)
            default: prefix = Array(#"{"qa_file_cancel":2,"id":"#.utf8)
            }
            XCTAssertTrue(Array(built.utf8).starts(with: prefix), "\(vector.name): prefix")
            XCTAssertFalse(built.contains(":null"), "\(vector.name): a builder never writes null")
            XCTAssertLessThan(built.utf8.count, FileV2.maxDescriptorBytes, vector.name)
            let accepted = describe(FileV2Message.recognize(utf8: Data(built.utf8)))
            XCTAssertEqual(accepted.outcome, "ok", "\(vector.name): the receiver accepts what the builder wrote")
            XCTAssertEqual(accepted.kind, vector.message, vector.name)
        }
        XCTAssertEqual(byMessage, ["descriptor": 25, "src": 2, "cancel": 1])
    }
}

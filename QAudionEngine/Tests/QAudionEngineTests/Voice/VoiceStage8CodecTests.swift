import XCTest
import Foundation
import CryptoKit
@testable import QAudionEngine

/// Stage 8: the shared fp16 converter on 10,000 values and on every binary16 pattern, the template record v3 encoder (exact
/// bytes) and decoder (every field, every vector word), the canonical re-encoding, and the 54 malformed inputs that must be
/// rejected whole.
final class VoiceStage8CodecTests: XCTestCase {
    private func stage() throws -> (json: KatJSON, rows: [Float]) {
        let json = try VoiceKat.json("stage8_codec/stage8.json")
        return (json, try VoiceKat.floats(json["vectors_file"].string))
    }

    func testFp16ConverterGivesTheStoredBinary16PatternAndFloatFor10000Values() throws {
        let (s8, _) = try stage()
        let fp = s8["fp16"]
        let n = fp["count"].int
        XCTAssertEqual(n, 10000)
        let input = try VoiceStateKat.bits(fp["input_file"].string)
        let want16 = try VoiceKat.bytes(fp["binary16_file"].string)
        let wantBack = try VoiceStateKat.bits(fp["back_file"].string)
        XCTAssertEqual(input.count, n)
        XCTAssertEqual(want16.count, 2 * n)
        for i in 0..<n {
            let h = Int(want16[2 * i]) | (Int(want16[2 * i + 1]) << 8)
            XCTAssertEqual(Fp16.fromBits(input[i]), h, "value \(i) (bits \(String(input[i], radix: 16)))")
            XCTAssertEqual(Fp16.toBits(h), wantBack[i], "back \(i)")
        }
    }

    func testDecodingEveryNonNaNBinary16PatternGivesThePinnedDigest() throws {
        let (s8, _) = try stage()
        let d = s8["fp16"]["decode_all"]
        var digest = SHA256()
        var count = 0
        for p in 0...0xFFFF {
            if ((p >> 10) & 0x1F) == 31 && (p & 0x3FF) != 0 { continue } // NaN patterns are not part of the contract
            let bits = Fp16.toBits(p)
            digest.update(data: Data([UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8(bits >> 24)]))
            count += 1
            // every finite pattern survives a trip back through the encoder
            if Fp16.isFinite(p) { XCTAssertEqual(Fp16.fromBits(bits), p, "pattern \(p)") }
        }
        XCTAssertEqual(count, d["patterns"].int)
        XCTAssertEqual(digest.finalize().map { String(format: "%02x", $0) }.joined(), d["sha256"].string)
    }

    func testSizesOfARecordByStateAndSessionCount() throws {
        let (s8, _) = try stage()
        for o in s8["sizes"].array {
            XCTAssertEqual(TemplateCodec.sizeOf(state: o["state"].int, nSessions: o["n_sessions"].int), o["size"].int)
        }
        XCTAssertEqual(TemplateCodec.sizeOf(state: TemplateState.enrolled, nSessions: 8), 4608)
        XCTAssertEqual(TemplateCodec.sizeOf(state: TemplateState.learning, nSessions: 8), 12800)
    }

    func testRecordsEncodeToTheStoredBytesAndDecodeToEveryFieldAndEveryVectorWord() throws {
        let (s8, rows) = try stage()
        let records = s8["records"].array
        XCTAssertEqual(records.count, 12)
        for r in records {
            let name = r["name"].string
            let fields = r["fields"]
            let file = try VoiceKat.bytes(r["bytes_file"].string)
            XCTAssertEqual(file.count, r["size"].int, "\(name): size")
            XCTAssertEqual(VoiceHash.sha256Hex(Data(file)), r["sha256"].string, "\(name): sha256")
            let rec = VoiceStateKat.fieldsToRecord(fields, rows)
            XCTAssertEqual(try TemplateCodec.encode(rec), file, "\(name): encoded bytes")
            let dec = try TemplateCodec.decode(file)
            VoiceStateKat.assertRecord(name, dec, fields, rows, 0.0)
            XCTAssertEqual(try TemplateCodec.encode(dec), file, "\(name): canonical re-encoding")
        }
    }

    func testMalformedInputsAreRejectedWholeEveryRuleAtLeastOnce() throws {
        let (s8, _) = try stage()
        var bases = [String: [UInt8]]()
        for r in s8["records"].array { bases[r["name"].string] = try VoiceKat.bytes(r["bytes_file"].string) }
        let malformed = s8["malformed"].array
        XCTAssertEqual(malformed.count, 54)
        var rules = Set<String>()
        for m in malformed {
            let name = m["name"].string
            var b = try XCTUnwrap(bases[m["base"].string], name)
            for op in m["ops"].array {
                switch op["op"].string {
                case "set":
                    let h = VoiceStateKat.hex(op["hex"].string)
                    b.replaceSubrange(op["offset"].int..<(op["offset"].int + h.count), with: h)
                case "truncate":
                    b = Array(b.prefix(op["length"].int))
                case "append":
                    b += VoiceStateKat.hex(op["hex"].string)
                default:
                    XCTFail("\(name): unknown op")
                }
            }
            do {
                _ = try TemplateCodec.decode(b)
                XCTFail("\(name): a malformed input was accepted")
            } catch is TemplateFormatError {
                rules.insert(m["rule"].string)
            }
        }
        XCTAssertEqual(rules, Set((1...12).map { "R\($0)" }))
    }

    func testTheEncoderRefusesWhatItCouldNotWriteCanonically() throws {
        func fresh() -> TemplateRecord {
            TemplateRecord(state: 3, modelId: [UInt8](repeating: 0, count: 16), constantsVersion: 0, frontendVersion: 1)
        }
        func refuses(_ what: String, _ rec: TemplateRecord) {
            XCTAssertThrowsError(try TemplateCodec.encode(rec), what) { XCTAssertTrue($0 is TemplateFormatError, what) }
        }
        func vector(_ index: Int, _ value: Float) -> [Float] {
            var v = [Float](repeating: 0, count: 512)
            v[index] = value
            return v
        }
        func session(route: Int = 1, centroid: [Float]?) -> TemplateSession {
            TemplateSession(speechMs: 1, dayIndex: 1, startS: 1, endS: 2, deviceTag: 3, routeClass: route, nWindows: 1, centroid: centroid)
        }
        var r = fresh(); r.state = 0; refuses("state 0", r)
        r = fresh(); r.state = 5; refuses("state 5", r)
        r = fresh(); r.anchor = vector(7, 70000); refuses("anchor with an overflowing value", r)
        r = fresh(); r.anchor = vector(7, Float.nan); refuses("anchor with a NaN", r)
        r = fresh(); r.anchor = [Float](repeating: 0, count: 511); refuses("anchor of the wrong length", r)
        r = fresh(); r.sessions.append(session(centroid: [Float](repeating: 0, count: 512))); refuses("a centroid on an Enrolled session", r)
        r = fresh(); r.state = 1; r.sessions.append(session(centroid: nil)); refuses("a Learning session without a centroid", r)
        r = fresh(); for _ in 0..<9 { r.sessions.append(session(centroid: nil)) }; refuses("nine sessions", r)
        r = fresh(); r.sessions.append(session(route: 6, centroid: nil)); refuses("route class 6", r)
        r = fresh(); r.slots[0].speechMs = 5; refuses("an empty slot with a field", r)
        r = fresh(); r.constantsVersion = 0x1_0000_0000; refuses("a constants version above u32", r)
        r = fresh(); r.modelId = [UInt8](repeating: 0, count: 15); refuses("a model id of 15 bytes", r)
        XCTAssertEqual(try TemplateCodec.encode(fresh()).count, 4608)
    }

    func testTheRecordLayoutIsTheDocumentedOne() throws {
        let (s8, _) = try stage()
        let enc = try TemplateCodec.encode(
            TemplateRecord(state: 3, modelId: [UInt8](repeating: 0, count: 16), constantsVersion: 0, frontendVersion: 1))
        XCTAssertEqual(String(decoding: enc.prefix(4), as: UTF8.self), "QAVT")
        XCTAssertEqual(Int(enc[4]) | (Int(enc[5]) << 8), 3)
        XCTAssertEqual(enc[7], 0)
        XCTAssertEqual(s8["layout"]["magic"].string, "QAVT")
        XCTAssertEqual(s8["layout"]["fixed_bytes"].int, TemplateCodec.bodyFixed)
        XCTAssertEqual(s8["layout"]["header_bytes"].int, TemplateCodec.headerBytes)
        XCTAssertEqual(s8["layout"]["slot_bytes"].int, TemplateCodec.slotBytes)
        XCTAssertEqual(s8["layout"]["session_bytes"].int, TemplateCodec.sessionBytes)
        XCTAssertEqual(s8["layout"]["file_overhead_bytes"].int, VoiceAesGcmAead.nonceBytes + VoiceAesGcmAead.tagBytes)
    }

    func testFp16TiesAndLimitsOfTheSharedConverter() {
        XCTAssertEqual(Fp16.fromFloat(65519.99), 0x7BFF) // 65504
        XCTAssertEqual(Fp16.fromFloat(65520), 0x7C00)
        XCTAssertEqual(Fp16.fromFloat(-65520), 0xFC00)
        XCTAssertEqual(Fp16.fromFloat(Float(sign: .plus, exponent: -25, significand: 1)), 0x0000) // the tie with zero goes to zero
        XCTAssertEqual(Fp16.fromFloat(3 * Float(sign: .plus, exponent: -25, significand: 1)), 0x0002) // the tie goes to the even one
        XCTAssertEqual(Fp16.fromFloat(Float(sign: .plus, exponent: -24, significand: 1)), 0x0001)
        XCTAssertEqual(Fp16.fromFloat(-0.0), 0x8000)
        XCTAssertEqual(Fp16.fromFloat(Float.nan), 0x7E00)
        XCTAssertEqual(Fp16.toFloat(0x3C00), 1)
        XCTAssertEqual(Fp16.toFloat(1), Float(sign: .plus, exponent: -24, significand: 1))
    }
}

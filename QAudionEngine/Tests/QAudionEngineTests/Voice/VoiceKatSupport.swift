import XCTest
import Foundation
@testable import QAudionEngine

/// A JSON tree that keeps integers as Int64 (the reference vectors hold times near 2^61) and floats as Double.
enum KatJSON: Decodable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([KatJSON])
    case object([String: KatJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([KatJSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: KatJSON].self))
        }
    }

    subscript(key: String) -> KatJSON {
        if case .object(let o) = self, let v = o[key] {
            return v
        }
        return .null
    }

    subscript(index: Int) -> KatJSON {
        if case .array(let a) = self, index >= 0, index < a.count {
            return a[index]
        }
        return .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var array: [KatJSON] {
        if case .array(let a) = self { return a }
        return []
    }

    var count: Int { array.count }

    var int64: Int64 {
        switch self {
        case .int(let v): return v
        case .double(let v) where v == v.rounded(): return Int64(v)
        default:
            XCTFail("not an integer: \(self)")
            return 0
        }
    }

    var int: Int { Int(int64) }

    /// An integer or a null.
    var optionalInt64: Int64? { isNull ? nil : int64 }

    var double: Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default:
            XCTFail("not a number: \(self)")
            return 0
        }
    }

    var optionalDouble: Double? { isNull ? nil : double }

    /// A boolean, or an integer 0 / 1.
    var flag: Bool {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v != 0
        default:
            XCTFail("not a flag: \(self)")
            return false
        }
    }

    var string: String {
        if case .string(let s) = self { return s }
        XCTFail("not a string: \(self)")
        return ""
    }

    var int64s: [Int64] { array.map { $0.int64 } }
    var ints: [Int] { array.map { $0.int } }
    var doubles: [Double] { array.map { $0.double } }
    var flags: [Bool] { array.map { $0.flag } }
}

/// The reference vectors that ship with the tests, and helpers to read and compare them.
enum VoiceKat {
    /// The vectors' folder: from the test bundle, else found from this source file.
    static func root(file: StaticString = #filePath) throws -> URL {
        let fm = FileManager.default
        let resourceRoot = Bundle.module.resourceURL
        let candidates: [URL?] = [
            resourceRoot?.appendingPathComponent("voice-kat", isDirectory: true),
            resourceRoot?.appendingPathComponent("Resources/voice-kat", isDirectory: true),
            Bundle.module.url(forResource: "voice-kat", withExtension: nil)
        ]
        for candidate in candidates {
            if let url = candidate, fm.fileExists(atPath: url.appendingPathComponent("index.json").path) {
                return url
            }
        }
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            let url = dir.appendingPathComponent("Resources/voice-kat", isDirectory: true)
            if fm.fileExists(atPath: url.appendingPathComponent("index.json").path) {
                return url
            }
        }
        XCTFail("voice-kat not found")
        throw CocoaError(.fileNoSuchFile)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: try root().appendingPathComponent(path))
    }

    static func json(_ path: String) throws -> KatJSON {
        try JSONDecoder().decode(KatJSON.self, from: try data(path))
    }

    /// Little-endian float32 values of a `.f32` file.
    static func floats(_ path: String) throws -> [Float] {
        let d = try data(path)
        let count = d.count / 4
        return d.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self))) }
        }
    }

    static func bytes(_ path: String) throws -> [UInt8] {
        [UInt8](try data(path))
    }

    /// 16-bit mono PCM samples and the sample rate of a WAV file with a 44-byte header.
    static func wav(_ path: String) throws -> (samples: [Int16], rate: Int) {
        let d = try data(path)
        XCTAssertGreaterThan(d.count, 44, path)
        XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF", path)
        XCTAssertEqual(String(decoding: d.subdata(in: 8..<12), as: UTF8.self), "WAVE", path)
        XCTAssertEqual(String(decoding: d.subdata(in: 36..<40), as: UTF8.self), "data", path)
        let rate = d.withUnsafeBytes { raw in
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)))
        }
        let count = (d.count - 44) / 2
        let samples = d.withUnsafeBytes { raw in
            (0..<count).map { Int16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 44 + 2 * $0, as: UInt16.self))) }
        }
        return (samples, rate)
    }

    /// The runtime bundle from the module resources, else from the source tree (so that a problem with the resource
    /// layout shows in the bundle test alone and the other vectors still run).
    static func bundle(file: StaticString = #filePath) throws -> VoiceBundle {
        if let bundle = try? VoiceBundle.loadFromModule() {
            return bundle
        }
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("Sources/QAudionEngine/Resources/voice", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(VoiceBundle.constantsFile).path) {
                return try VoiceBundle.load(directory: candidate)
            }
        }
        return try VoiceBundle.loadFromModule()
    }

    /// The comparison rule of the float values of stage 3 and the vectors.
    static func closeStats(_ got: Double, _ want: Double) -> Bool {
        abs(got - want) <= 1e-4 * abs(want) + 1e-15
    }

    /// The chunk stream of a stage 2 / stage 3 `stream_segments` list: the 512-sample chunks of each piece.
    static func chunkStream(_ segments: KatJSON, passThrough: [Int: [Float]]) throws -> [Float] {
        var out: [Float] = []
        var cache: [String: [Float]] = [:]
        for piece in segments.array {
            let offset = piece["out_offset"].int
            let count = piece["n_chunks"].int * VoiceChunker.chunkLength
            let source: [Float]
            if piece["file"].isNull {
                guard let pass = passThrough[piece["tap"].int] else {
                    XCTFail("no pass-through audio for tap \(piece["tap"].int)")
                    continue
                }
                source = pass
            } else {
                let file = piece["file"].string
                if cache[file] == nil {
                    cache[file] = try floats(file)
                }
                source = cache[file] ?? []
            }
            out.append(contentsOf: source[offset..<(offset + count)])
        }
        return out
    }

    /// float32(int16) / 32768 of every sample.
    static func scaled(_ samples: [Int16]) -> [Float] {
        samples.map { Float(Int32($0)) / 32_768.0 }
    }
}

/// A VAD that returns stored probabilities, one per chunk in order (the measurements read the stored values).
final class StoredProbabilityVad: VoiceVadModel {
    private let values: [Float]
    private var next = 0

    init(_ values: [Float]) {
        self.values = values
    }

    func reset() {}

    func step(_ chunk: [Float]) throws -> Float {
        XCTAssertEqual(chunk.count, VoiceChunker.chunkLength)
        guard next < values.count else {
            XCTFail("more chunks than stored probabilities")
            return 0
        }
        defer { next += 1 }
        return values[next]
    }
}

extension VoiceStatsSnapshot {
    /// A snapshot from its entry in the reference vectors.
    init(json j: KatJSON) {
        self.init(
            reqNs: j["req_ns"].int64,
            arriveNs: j["arrive_ns"].int64,
            oldestNs: j["oldest_ns"].int64,
            reportNs: j["report_ns"].int64,
            rxSsrc: j["rx_ssrc"].optionalInt64,
            concealed: j["concealed"].optionalInt64,
            silentConcealed: j["silent_concealed"].optionalInt64,
            concealmentEvents: j["conc_events"].optionalInt64,
            totalSamples: j["total_samples"].optionalInt64,
            insertedDecel: j["inserted_decel"].optionalInt64,
            removedAccel: j["removed_accel"].optionalInt64,
            jbDelayS: j["jb_delay_s"].optionalDouble,
            jbEmitted: j["jb_emitted"].optionalInt64,
            txEnergy: j["tx_energy"].optionalDouble,
            txDurationS: j["tx_duration_s"].optionalDouble,
            rttRemoteS: j["rtt_remote_s"].optionalDouble,
            rttPairS: j["rtt_pair_s"].optionalDouble
        )
    }
}

/// The columns of a stats track's intervals, compared with the stored ones (floats by the stage 3 rule).
func assertIntervalColumns(_ got: [VoiceStatsInterval], _ want: KatJSON, _ label: String) {
    XCTAssertEqual(got.count, want["start_ns"].count, "\(label): interval count")
    guard got.count == want["start_ns"].count else { return }
    for (i, iv) in got.enumerated() {
        let at = "\(label) interval \(i)"
        XCTAssertEqual(iv.startNs, want["start_ns"][i].int64, "\(at) start")
        XCTAssertEqual(iv.endNs, want["end_ns"][i].int64, "\(at) end")
        XCTAssertEqual(iv.isGuard, want["guard"][i].flag, "\(at) guard")
        XCTAssertEqual(iv.known, want["known"][i].flag, "\(at) known")
        XCTAssertEqual(iv.audible, want["audible"][i].int64, "\(at) audible")
        XCTAssertEqual(iv.silent, want["silent"][i].int64, "\(at) silent")
        XCTAssertEqual(iv.events, want["events"][i].int64, "\(at) events")
        XCTAssertEqual(iv.conc, want["conc"][i].flag, "\(at) conc")
        XCTAssertEqual(iv.total, want["total"][i].int64, "\(at) total")
        XCTAssertEqual(iv.stretch, want["stretch"][i].int64, "\(at) stretch")
        XCTAssertTrue(VoiceKat.closeStats(iv.jbS, want["jb_s"][i].double), "\(at) jb_s \(iv.jbS) vs \(want["jb_s"][i].double)")
        XCTAssertTrue(VoiceKat.closeStats(iv.rttS, want["rtt_s"][i].double), "\(at) rtt_s")
        XCTAssertEqual(iv.preNs, want["pre_ns"][i].int64, "\(at) pre_ns")
        XCTAssertTrue(VoiceKat.closeStats(iv.pTx, want["p_tx"][i].double), "\(at) p_tx \(iv.pTx) vs \(want["p_tx"][i].double)")
        XCTAssertEqual(iv.muted, want["muted"][i].flag, "\(at) muted")
        XCTAssertEqual(iv.txActive, want["tx_active"][i].flag, "\(at) tx_active")
    }
}

/// The windows of a run, compared with the stored ones: ranges and flags exactly, floats by the stage 3 rule.
func assertWindows(_ got: [VoiceWindowResult], _ want: KatJSON, _ label: String) {
    XCTAssertEqual(got.count, want.count, "\(label): window count")
    guard got.count == want.count else { return }
    for (i, w) in got.enumerated() {
        let e = want[i]
        let at = "\(label) window \(i)"
        XCTAssertEqual(w.n, e["n"].int, "\(at) n")
        XCTAssertEqual(w.epoch, e["epoch"].int, "\(at) epoch")
        XCTAssertEqual(w.w, e["w"].int, "\(at) w")
        XCTAssertEqual(w.disjoint, e["disjoint"].flag, "\(at) disjoint")
        XCTAssertEqual(w.ranges, e["ranges"].array.map { $0.ints }, "\(at) ranges")
        XCTAssertEqual(w.first, e["first"].int, "\(at) first")
        XCTAssertEqual(w.last, e["last"].int, "\(at) last")
        let floats: [(String, Double, Double)] = [
            ("mean_p", w.meanP, e["mean_p"].double), ("noise_P", w.noiseP, e["noise_P"].double),
            ("speech_P", w.speechP, e["speech_P"].double), ("snr_db", w.snrDb, e["snr_db"].double),
            ("clip_frac", w.clipFrac, e["clip_frac"].double), ("plc", w.plc, e["plc"].double),
            ("bw", w.bw, e["bw"].double)
        ]
        for (name, value, expected) in floats {
            XCTAssertTrue(VoiceKat.closeStats(value, expected), "\(at) \(name): \(value) vs \(expected)")
        }
        XCTAssertEqual(w.plcEvents, e["plc_events"].int, "\(at) plc_events")
        XCTAssertEqual(w.stretchEvents, e["stretch_events"].int, "\(at) stretch_events")
        XCTAssertEqual(w.concUnknown, e["conc_unknown"].flag, "\(at) conc_unknown")
        XCTAssertEqual(w.txUnknown, e["tx_unknown"].flag, "\(at) tx_unknown")
        XCTAssertEqual(w.narrowband, e["nb"].flag, "\(at) nb")
        XCTAssertEqual(w.enroll, e["enroll"].flag, "\(at) enroll")
        XCTAssertEqual(w.score, e["score"].flag, "\(at) score")
        XCTAssertEqual(w.certain, e["certain"].flag, "\(at) certain")
    }
}

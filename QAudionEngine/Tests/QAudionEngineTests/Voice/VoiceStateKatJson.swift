import XCTest
import Foundation
@testable import QAudionEngine

/// Shared by the stage 9 and stage 11 tests: the result of a call as the JSON object of the vectors, and the comparison of two
/// such trees.
extension VoiceStateKat {
    private static func int(_ v: Int) -> KatJSON { KatJSON.int(Int64(v)) }
    private static func str(_ s: String?) -> KatJSON { s.map { KatJSON.string($0) } ?? KatJSON.null }
    private static func optInt(_ v: Int?) -> KatJSON? { v.map { KatJSON.int(Int64($0)) } }
    private static func optBool(_ v: Bool?) -> KatJSON? { v.map { KatJSON.bool($0) } }
    private static func real(_ v: Double?) -> KatJSON? { v.map { KatJSON.double($0) } }
    private static func text(_ v: String?) -> KatJSON? { v.map { KatJSON.string($0) } }

    /// Adds `value` under `key` unless it is nil.
    private static func put(_ o: inout [String: KatJSON], _ key: String, _ value: KatJSON?) {
        if let value { o[key] = value }
    }

    static func buildJson(_ b: BuildInfo) -> KatJSON {
        var o = [String: KatJSON]()
        o["windows_in"] = int(b.windowsIn)
        o["taken"] = int(b.taken)
        o["dropped"] = int(b.dropped)
        put(&o, "speech_ms", optInt(b.speechMs))
        put(&o, "mean_llr", real(b.meanLlr))
        put(&o, "why", text(b.why))
        return .object(o)
    }

    static func recomputeJson(_ r: RecomputeInfo) -> KatJSON {
        var o = [String: KatJSON]()
        o["state_before"] = int(r.stateBefore)
        o["state"] = int(r.state)
        o["why"] = str(r.why)
        o["consensus"] = .array(r.consensus.map { int($0) })
        o["conflict"] = .bool(r.conflict)
        return .object(o)
    }

    static func callResultJson(_ r: CallResult) -> KatJSON {
        var o = [String: KatJSON]()
        o["effect"] = .string(r.effect)
        put(&o, "why", text(r.why))
        put(&o, "path", text(r.path))
        if let build = r.build { o["build"] = buildJson(build) }
        put(&o, "created", optBool(r.created))
        put(&o, "merge", text(r.merge))
        put(&o, "session", text(r.session))
        put(&o, "evicted", optInt(r.evicted))
        if let c = r.contributed {
            o["contributed"] = .object(["windows": int(c.windows), "speech_ms": int(c.speechMs)])
        }
        if let rc = r.recompute { o["recompute"] = recomputeJson(rc) }
        if let c = r.coverage {
            var m = [String: KatJSON]()
            m["route"] = .bool(c.route)
            m["device"] = .bool(c.device)
            m["template"] = c.template < 0 ? KatJSON.string("B") : int(c.template)
            o["coverage"] = .object(m)
        }
        if let f = r.refresh {
            var m = [String: KatJSON]()
            m["qualifying"] = .bool(f.qualifying)
            m["entered"] = .bool(f.entered)
            put(&m, "m", real(f.m))
            put(&m, "streak", optInt(f.streak))
            put(&m, "gap", optBool(f.gap))
            o["refresh"] = .object(m)
        }
        if let u = r.update {
            var m = [String: KatJSON]()
            m["updated"] = .bool(u.updated)
            m["why"] = str(u.why)
            put(&m, "w", real(u.w))
            o["update"] = .object(m)
        }
        if let s = r.slot {
            var m = [String: KatJSON]()
            m["entered"] = .bool(s.entered)
            m["why"] = str(s.why)
            put(&m, "slot", optInt(s.slot))
            put(&m, "action", text(s.action))
            put(&m, "activated", optBool(s.activated))
            if let build = s.build { m["build"] = buildJson(build) }
            o["slot"] = .object(m)
        }
        return .object(o)
    }

    /// Same keys; integers, strings and booleans exact; floats within 1e-9.
    static func assertJson(_ at: String, _ want: KatJSON, _ got: KatJSON, file: StaticString = #filePath, line: UInt = #line) {
        switch (want, got) {
        case (.object(let a), .object(let b)):
            XCTAssertEqual(Set(a.keys), Set(b.keys), "\(at): keys", file: file, line: line)
            for (k, v) in a {
                if let g = b[k] { assertJson("\(at).\(k)", v, g, file: file, line: line) }
            }
        case (.array(let a), .array(let b)):
            XCTAssertEqual(a.count, b.count, "\(at): length", file: file, line: line)
            if a.count == b.count {
                for i in a.indices { assertJson("\(at)[\(i)]", a[i], b[i], file: file, line: line) }
            }
        case (.null, .null):
            break
        case (.string(let a), .string(let b)):
            XCTAssertEqual(a, b, at, file: file, line: line)
        case (.bool(let a), .bool(let b)):
            XCTAssertEqual(a, b, at, file: file, line: line)
        case (.int(let a), .int(let b)):
            XCTAssertEqual(a, b, at, file: file, line: line)
        case (.int(let a), .double(let b)):
            XCTAssertLessThanOrEqual(abs(Double(a) - b), 1e-9, "\(at): got \(b), want \(a)", file: file, line: line)
        case (.double(let a), .int(let b)):
            XCTAssertLessThanOrEqual(abs(a - Double(b)), 1e-9, "\(at): got \(b), want \(a)", file: file, line: line)
        case (.double(let a), .double(let b)):
            XCTAssertLessThanOrEqual(abs(a - b), 1e-9, "\(at): got \(b), want \(a)", file: file, line: line)
        default:
            XCTFail("\(at): \(want) vs \(got)", file: file, line: line)
        }
    }
}

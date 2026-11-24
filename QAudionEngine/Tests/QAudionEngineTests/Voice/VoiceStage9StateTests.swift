import XCTest
import Foundation
@testable import QAudionEngine

/// Stage 9: all 88 scripted cases over one contact's record, run from the first step with the machine's own state. After every
/// step the record is compared (integers, flags and sets exact, vectors within 5e-4 of the stored binary16 value) and the result
/// object (integers, strings and booleans exact, floats within 1e-9, the same keys). The record goes through the codec between
/// steps, as a file does: the next call reads the binary16 values back.
final class VoiceStage9StateTests: XCTestCase {
    private func stage() throws -> (json: KatJSON, rows: [Float], salt: [UInt8]) {
        let json = try VoiceKat.json("stage9_state/stage9.json")
        return (json, try VoiceKat.floats(json["vectors_file"].string), VoiceStateKat.hex(json["name_salt"].string))
    }

    func testDayIndexAndDeviceTagVectors() throws {
        let (s9, _, _) = try stage()
        for o in s9["day_index"].array {
            XCTAssertEqual(VoiceTags.dayIndex(startS: o["start_s"].int, utcOffsetS: o["utc_offset_s"].int), o["day_index"].int)
        }
        for o in s9["device_tags"].array {
            XCTAssertEqual(VoiceTags.deviceTag(nameSalt: VoiceStateKat.hex(o["name_salt"].string), deviceId: o["device_id"].string),
                           o["device_tag"].int)
        }
        // a floor, also below zero
        XCTAssertEqual(VoiceTags.dayIndex(startS: -1, utcOffsetS: 0), -1)
        XCTAssertEqual(VoiceTags.dayIndex(startS: 0, utcOffsetS: -1), -1)
        XCTAssertEqual(VoiceTags.dayIndex(startS: 86_399, utcOffsetS: 0), 0)
    }

    func testEveryCaseGivesTheStoredRecordAndResultAfterEveryStep() throws {
        let (s9, rows, salt) = try stage()
        let cases = s9["cases"].array
        XCTAssertEqual(cases.count, 88)
        var steps = 0
        for c in cases {
            let name = c["name"].string
            let cfg = try constants(overlay: c["constants"])
            var rec: TemplateRecord?
            for (si, step) in c["steps"].array.enumerated() {
                let label = "\(name) step \(si) (\(step["action"].string))"
                let expected = step["expected"]
                let result: KatJSON
                switch step["action"].string {
                case "load":
                    rec = try quantize(VoiceStateKat.fieldsToRecord(step["record"], rows))
                    result = .object(["loaded": .bool(true)])
                case "reset":
                    rec = nil
                    result = .object(["deleted": .string("reset")])
                case "call":
                    let end = try VoiceTemplateState.endOfCall(rec, call(step, rows, salt), cfg)
                    rec = try end.record.map { try quantize($0) }
                    result = Self.json(end.result)
                case "sweep":
                    let sw = VoiceTemplateState.sweep(rec, nowS: step["now_s"].int, cfg)
                    rec = try sw.record.map { try quantize($0) }
                    var o: [String: KatJSON] = ["deleted": Self.str(sw.deleted)]
                    if sw.deleted == nil {
                        o["purged"] = .array(sw.purged.map { Self.int($0) })
                        o["idle_slots"] = .array(sw.idleSlots.map { Self.int($0) })
                        if let rc = sw.recompute { o["recompute"] = Self.json(rc) }
                    }
                    result = .object(o)
                case "prompt":
                    let (r, due) = VoiceTemplateState.reprompt(rec, nowS: step["now_s"].int, cfg)
                    rec = try r.map { try quantize($0) }
                    result = .object(["prompt": .bool(due)])
                case "compat":
                    let kept = rec.map {
                        VoiceTemplateState.isCompatible($0, modelId: VoiceStateKat.hex(step["model_id"].string),
                                                        frontendVersion: step["frontend_version"].int)
                    } ?? false
                    if !kept { rec = nil }
                    result = .object(["kept": .bool(kept)])
                default:
                    XCTFail("\(label): unknown action")
                    continue
                }
                VoiceStateKat.assertRecord(label, rec, expected["record"], rows, 5e-4)
                assertJson("\(label): result", expected["result"], result)
                steps += 1
            }
        }
        XCTAssertGreaterThan(steps, 200)
    }

    // MARK: inputs

    private func constants(overlay: KatJSON) throws -> VoiceStateConstants {
        if overlay.isNull { return try VoiceKat.bundle().state }
        let directory = try XCTUnwrap(VoiceBundle.moduleDirectory(), "voice bundle not found in the module resources")
        let data = try Data(contentsOf: directory.appendingPathComponent(VoiceBundle.constantsFile))
        var merged = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (section, entries) in overlay.members {
            var m = try XCTUnwrap(merged[section] as? [String: Any], "\(section) is not a section of constants.json")
            for (key, value) in entries.members {
                XCTAssertNotNil(m[key], "\(section).\(key) is not a key of constants.json")
                m[key] = value.foundationValue
            }
            merged[section] = m
        }
        return try VoiceStateConstants.parse(try JSONSerialization.data(withJSONObject: merged))
    }

    private func quantize(_ r: TemplateRecord) throws -> TemplateRecord {
        try TemplateCodec.decode(try TemplateCodec.encode(r))
    }

    private func window(_ w: KatJSON, _ rows: [Float]) -> StateWindow {
        StateWindow(
            emb: VoiceStateKat.row(rows, w["emb"]["vec"].int),
            chunks: w["chunks"].array.map { $0[0].int..<$0[1].int },
            lC: w["l_c"].optionalDouble,
            nb: w["nb"].bool)
    }

    private func call(_ step: KatJSON, _ rows: [Float], _ salt: [UInt8]) -> StateCall {
        var session: StateSession?
        if !step["session"].isNull {
            let s = step["session"]
            session = StateSession(
                speechMs: s["speech_ms"].int, centroid: VoiceStateKat.row(rows, s["centroid"]["vec"].int),
                nWindows: s["n_windows"].int, conflict: s["conflict"].bool, nb: s["nb"].int)
        }
        var outcome: StateOutcome?
        if !step["outcome"].isNull {
            let o = step["outcome"]
            outcome = StateOutcome(
                u: VoiceStateKat.row(rows, o["u"]["vec"].int), lC: o["l_c"].doubles, gateWindows: o["gate_windows"].int,
                matched: o["matched"].bool, finalMatches: o["final_matches"].bool, differsCandidate: o["differs_candidate"].bool,
                blocked: o["blocked"].bool, matchWindows: o["match_windows"].int, scoredWindows: o["scored_windows"].int,
                eligWindows: o["elig_windows"].int, authenticityElevated: o["authenticity_elevated"].bool, wasHim: o["was_him"].bool)
        }
        let windows: [StateWindow]? = step["windows"].isNull ? nil : step["windows"].array.map { window($0, rows) }
        return StateCall(
            tStartS: step["t_start_s"].int, tEndS: step["t_end_s"].int, utcOffsetS: step["utc_offset_s"].int,
            routeClass: step["route_class"].int,
            deviceTag: VoiceTags.deviceTag(nameSalt: salt, deviceId: step["device"].string),
            consent: step["consent"].bool, consentS: step["consent_s"].int, tier: step["tier"].int,
            learnBlocked: step["learn_blocked"].bool, windows: windows, session: session, outcome: outcome)
    }

    // MARK: results as JSON

    private static func str(_ s: String?) -> KatJSON { s.map { KatJSON.string($0) } ?? KatJSON.null }

    /// Adds `value` under `key` unless it is nil.
    private static func put(_ o: inout [String: KatJSON], _ key: String, _ value: KatJSON?) {
        if let value { o[key] = value }
    }

    private static func int(_ v: Int) -> KatJSON { KatJSON.int(Int64(v)) }
    private static func optInt(_ v: Int?) -> KatJSON? { v.map { KatJSON.int(Int64($0)) } }
    private static func optBool(_ v: Bool?) -> KatJSON? { v.map { KatJSON.bool($0) } }
    private static func real(_ v: Double?) -> KatJSON? { v.map { KatJSON.double($0) } }
    private static func text(_ v: String?) -> KatJSON? { v.map { KatJSON.string($0) } }

    private static func json(_ b: BuildInfo) -> KatJSON {
        var o = [String: KatJSON]()
        o["windows_in"] = int(b.windowsIn)
        o["taken"] = int(b.taken)
        o["dropped"] = int(b.dropped)
        put(&o, "speech_ms", optInt(b.speechMs))
        put(&o, "mean_llr", real(b.meanLlr))
        put(&o, "why", text(b.why))
        return .object(o)
    }

    private static func json(_ r: RecomputeInfo) -> KatJSON {
        var o = [String: KatJSON]()
        o["state_before"] = int(r.stateBefore)
        o["state"] = int(r.state)
        o["why"] = str(r.why)
        o["consensus"] = .array(r.consensus.map { int($0) })
        o["conflict"] = .bool(r.conflict)
        return .object(o)
    }

    private static func json(_ r: CallResult) -> KatJSON {
        var o = [String: KatJSON]()
        o["effect"] = .string(r.effect)
        put(&o, "why", text(r.why))
        put(&o, "path", text(r.path))
        if let build = r.build { o["build"] = json(build) }
        put(&o, "created", optBool(r.created))
        put(&o, "merge", text(r.merge))
        put(&o, "session", text(r.session))
        put(&o, "evicted", optInt(r.evicted))
        if let c = r.contributed {
            o["contributed"] = .object(["windows": int(c.windows), "speech_ms": int(c.speechMs)])
        }
        if let rc = r.recompute { o["recompute"] = json(rc) }
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
            if let build = s.build { m["build"] = json(build) }
            o["slot"] = .object(m)
        }
        return .object(o)
    }

    /// Same keys; integers, strings and booleans exact; floats within 1e-9.
    private func assertJson(_ at: String, _ want: KatJSON, _ got: KatJSON) {
        switch (want, got) {
        case (.object(let a), .object(let b)):
            XCTAssertEqual(Set(a.keys), Set(b.keys), "\(at): keys")
            for (k, v) in a {
                if let g = b[k] { assertJson("\(at).\(k)", v, g) }
            }
        case (.array(let a), .array(let b)):
            XCTAssertEqual(a.count, b.count, "\(at): length")
            if a.count == b.count { for i in a.indices { assertJson("\(at)[\(i)]", a[i], b[i]) } }
        case (.null, .null):
            break
        case (.string(let a), .string(let b)):
            XCTAssertEqual(a, b, at)
        case (.bool(let a), .bool(let b)):
            XCTAssertEqual(a, b, at)
        case (.int(let a), .int(let b)):
            XCTAssertEqual(a, b, at)
        case (.int(let a), .double(let b)):
            XCTAssertLessThanOrEqual(abs(Double(a) - b), 1e-9, "\(at): got \(b), want \(a)")
        case (.double(let a), .int(let b)):
            XCTAssertLessThanOrEqual(abs(a - Double(b)), 1e-9, "\(at): got \(b), want \(a)")
        case (.double(let a), .double(let b)):
            XCTAssertLessThanOrEqual(abs(a - b), 1e-9, "\(at): got \(b), want \(a)")
        default:
            XCTFail("\(at): \(want) vs \(got)")
        }
    }
}

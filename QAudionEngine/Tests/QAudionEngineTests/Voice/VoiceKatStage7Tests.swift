import XCTest
import Foundation
@testable import QAudionEngine

/// Stage 7: the evidence rule, the displayed state with its dwell, hold and Cannot verify, and the call-local change check, on
/// all 38 scripted event lists. Every record field is compared: exact, except `T_b`, `T_next` and `worst` (relative 1e-12:
/// they contain a natural logarithm).
final class VoiceKatStage7Tests: XCTestCase {

    /// The constants with the `{section: {key: value}}` overlay of a case applied.
    private func constants(_ base: VoiceScoringConstants, overlay: KatJSON, case name: String) -> VoiceScoringConstants {
        var c = base
        for (section, entries) in overlay.members {
            for (key, v) in entries.members {
                switch (section, key) {
                case ("evidence", "m_min"): c.evidence.mMin = v.double
                case ("evidence", "t_differs"): c.evidence.tDiffers = v.double
                case ("evidence", "t_match"): c.evidence.tMatch = v.double
                case ("call_local", "t_change"): c.callLocal.tChange = v.double
                case ("call_local", "m_min"): c.callLocal.mMin = v.double
                case ("call_local", "tail_slope"): c.callLocal.tailSlope = v.double
                case ("call_local", "neg_min"): c.callLocal.negMin = v.int
                case ("call_local", "max_block"): c.callLocal.maxBlock = v.int
                default: XCTFail("\(name): no overlay for \(section).\(key)")
                }
            }
        }
        return c
    }

    private func apply(_ set: KatJSON, to ctx: inout VoiceCallContext) {
        for (key, v) in set.members {
            switch key {
            case "consent": ctx.consent = v.flag
            case "fault":
                if v.isNull {
                    ctx.fault = nil
                } else {
                    ctx.fault = VoiceFault(rawValue: v.string)
                    XCTAssertNotNil(ctx.fault, "fault \(v.string)")
                }
            case "tier": ctx.tier = v.int
            case "route_covered": ctx.routeCovered = v.flag
            case "device_covered": ctx.deviceCovered = v.flag
            case "contact":
                ctx.contact = VoiceContactState(rawValue: v.string) ?? .enrolled
                XCTAssertNotNil(VoiceContactState(rawValue: v.string), "contact \(v.string)")
            case "display_differs": ctx.displayDiffers = v.flag
            case "display_change": ctx.displayChange = v.flag
            default: XCTFail("unknown context field \(key)")
            }
        }
    }

    private func rel(_ what: String, _ got: Double, _ want: Double) {
        XCTAssertLessThanOrEqual(abs(got - want), 1e-12 * abs(want), "\(what): got \(got), want \(want)")
    }

    private func text(_ v: KatJSON) -> String? {
        v.isNull ? nil : v.string
    }

    func testAll38CasesGiveTheStoredRecordAfterEveryEvent() throws {
        let s7 = try VoiceKat.json("stage7_evidence/stage7.json")
        let base = try VoiceScoringKat.constants()
        let cases = s7["cases"].array
        XCTAssertEqual(cases.count, 38)
        var records = 0
        for c in cases {
            let name = c["name"].string
            let mode: VoiceCheckMode
            switch c["mode"].string {
            case "verify": mode = .verify
            case "call_local": mode = .callLocal
            default:
                XCTFail("mode of \(name)")
                continue
            }
            let machine = VoiceCallMachine(constants: constants(base, overlay: c["constants"], case: name), mode: mode)
            let events = c["events"].array
            let expected = c["expected"].array
            XCTAssertEqual(events.count, expected.count, "\(name): one record per event")
            guard events.count == expected.count else { continue }
            for (i, e) in events.enumerated() {
                let kind = e["kind"].string
                let t = e["t_ns"].int64
                let rec: VoiceRecord
                switch kind {
                case "media_start": rec = machine.mediaStart(t)
                case "ctx": rec = machine.setContext(t) { apply(e["set"], to: &$0) }
                case "window": rec = try machine.window(t, x: e["x"].double, certain: e["certain"].flag)
                case "reset": rec = machine.reset(t)
                case "tick": rec = machine.tick(t, speechMs30s: e["speech_ms_30s"].int64)
                default:
                    XCTFail("\(name) #\(i): event \(kind)")
                    continue
                }
                let w = expected[i]
                let at = "\(name) #\(i) (\(kind))"
                XCTAssertEqual(w["i"].int, i, "\(at): i")
                XCTAssertEqual(w["kind"].string, kind, "\(at): kind")
                XCTAssertEqual(w["t_ns"].int64, t, "\(at): t_ns")
                XCTAssertEqual(rec.b, w["b"].int, "\(at): b")
                XCTAssertEqual(rec.blockN, w["block_n"].int, "\(at): block_n")
                XCTAssertEqual(rec.blockSum, w["block_sum"].double, "\(at): block_sum")
                XCTAssertEqual(rec.r, w["R"].double, "\(at): R")
                XCTAssertEqual(rec.recentN, w["recent_n"].int, "\(at): recent_n")
                rel("\(at): T_next", rec.tNext, w["T_next"].double)
                rel("\(at): worst", rec.worst, w["worst"].double)
                XCTAssertEqual(rec.blocked, w["blocked"].flag, "\(at): blocked")
                let wc = w["closed"]
                if wc.isNull {
                    XCTAssertNil(rec.closed, "\(at): closed")
                } else if let g = rec.closed {
                    XCTAssertEqual(g.b, wc["b"].int, "\(at): closed.b")
                    XCTAssertEqual(g.s, wc["S"].double, "\(at): closed.S")
                    XCTAssertEqual(g.neg, wc["neg"].int, "\(at): closed.neg")
                    XCTAssertEqual(g.med, wc["med"].double, "\(at): closed.med")
                    rel("\(at): closed.T_b", g.tB, wc["T_b"].double)
                    XCTAssertEqual(g.differs, wc["differs"].flag, "\(at): closed.differs")
                    XCTAssertEqual(g.weakBlock, wc["weak"].flag, "\(at): closed.weak")
                    rel("\(at): closed.worst", g.worst, wc["worst"].double)
                } else {
                    XCTFail("\(at): a block should have closed")
                }
                XCTAssertEqual(rec.cand.rawValue, w["cand"].string, "\(at): cand")
                XCTAssertEqual(rec.shown.rawValue, w["shown"].string, "\(at): shown")
                XCTAssertEqual(rec.detail?.rawValue, text(w["detail"]), "\(at): detail")
                XCTAssertEqual(rec.changed, w["changed"].flag, "\(at): changed")
                XCTAssertEqual(rec.pending, w["pending"].flag, "\(at): pending")
                XCTAssertEqual(rec.shadow, w["shadow"].flag, "\(at): shadow")
                XCTAssertEqual(rec.differed, w["differed"].flag, "\(at): differed")
                records += 1
            }
        }
        XCTAssertEqual(records, 726)
    }
}

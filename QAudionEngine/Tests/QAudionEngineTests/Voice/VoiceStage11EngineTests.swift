import XCTest
import Foundation
@testable import QAudionEngine

/// Stage 11: the engine replay. 64 cases, each a list of calls over one contact (the record of a call is the one that the
/// previous call left, passed through the codec) with ONE budget object through the case. Per call the test builds the items from
/// the tap blocks and the explicit items, feeds a `VoiceEngine` with the stub VAD (the stored probabilities of stage 2, a cost per
/// call) and the stub embedder (a scripted raw vector and virtual cost per window), closes it, and compares every output: the
/// window list, the skip counts, every transition with its instant, the exact log lines, the effects, the displayed state at the
/// end, the late counts, the flush with the answer of the state functions and the record.
final class VoiceStage11EngineTests: XCTestCase {
    private struct ScriptedFailure: Error {}

    /// The stage 2 output as the engine's VAD: the p of the k-th call; a reset changes nothing; `fail_at` throws.
    private final class ScriptVad: TimedVadModel {
        private let p: [Float]
        private let base: Int64
        private let perStep: Int64
        private let failAt: Int?
        private var k = 0
        private(set) var lastCostNs: Int64 = 0

        init(p: [Float], base: Int64, perStep: Int64, failAt: Int?) {
            self.p = p
            self.base = base
            self.perStep = perStep
            self.failAt = failAt
        }

        func reset() {}

        func step(_ chunk: [Float]) throws -> Float {
            let i = k
            k += 1
            if let f = failAt, i == f { throw ScriptedFailure() }
            lastCostNs = (base + Int64(i % 7) * perStep) * 1000
            guard i < p.count else {
                XCTFail("more VAD calls than stored probabilities")
                return 0
            }
            return p[i]
        }
    }

    /// The stub embedder of the call: a scripted raw vector and virtual cost per window serial.
    private final class ScriptEmbedder: VoiceWindowEmbedder {
        private let script: [Int: KatJSON]
        private let rows: [Float]

        init(script: [Int: KatJSON], rows: [Float]) {
            self.script = script
            self.rows = rows
        }

        func embed(window: VoiceWindowResult) throws -> VoiceEmbedding? {
            guard let e = script[window.n] else { throw ScriptedFailure() }
            if case .bool(true) = e["fail"] { throw ScriptedFailure() }
            return VoiceEmbedding(raw: VoiceStateKat.row(rows, e["row"].int), costNs: e["cost_ns"].int64)
        }
    }

    private final class Recorder: VoiceEngineListener {
        var lines: [(Int64, String)] = []
        var transitions: [VoiceTransition] = []
        var effects: [(Int64, VoiceEffect)] = []
        var windows: [VoiceWindowRecord] = []

        func onLine(_ tNs: Int64, _ line: String) { lines.append((tNs, line)) }
        func onTransition(_ transition: VoiceTransition) { transitions.append(transition) }
        func onEffect(_ tNs: Int64, _ effect: VoiceEffect) { effects.append((tNs, effect)) }
        func onWindow(_ record: VoiceWindowRecord) { windows.append(record) }
    }

    private struct Run {
        let engine: VoiceEngine
        let recorder: Recorder
    }

    private struct Keyed {
        let at: Int64
        let group: Int
        let idx: Int
        let item: VoiceEngineItem
    }

    private struct Env {
        let s11: KatJSON
        let rows: [Float]
        let salt: [UInt8]
        let bundle: VoiceBundle
        let cohort: VoiceCohort
        let baseConstants: Data
    }

    private func environment() throws -> Env {
        let s11 = try VoiceKat.json("stage11_engine/stage11.json")
        let directory = try XCTUnwrap(VoiceBundle.moduleDirectory(), "voice bundle not found in the module resources")
        return Env(
            s11: s11,
            rows: try VoiceKat.floats(s11["vectors_file"].string),
            salt: VoiceStateKat.hex(s11["name_salt"].string),
            bundle: try VoiceKat.bundle(),
            cohort: try VoiceScoringKat.cohort(),
            baseConstants: try Data(contentsOf: directory.appendingPathComponent(VoiceBundle.constantsFile)))
    }

    private var audioCache: [String: [Int16]] = [:]

    private func audio(_ name: String, _ env: Env) throws -> [Int16] {
        if let a = audioCache[name] { return a }
        let a: [Int16]
        if name == "zeros" {
            a = [Int16](repeating: 0, count: env.s11["zeros_samples"].int)
        } else {
            a = try VoiceKat.wav(name).samples
        }
        audioCache[name] = a
        return a
    }

    // MARK: the tests

    func testTheFileIsTheBundlesAndTheStubVectorsAreAllThere() throws {
        let env = try environment()
        XCTAssertEqual(env.s11["cases"].count, 64)
        XCTAssertEqual(env.s11["vector_rows"].int * VoiceStateKat.dim, env.rows.count)
        XCTAssertEqual(env.s11["zeros_samples"].int, 800_000)
    }

    func testEveryCallOfEveryCaseGivesTheStoredOutputs() throws {
        let env = try environment()
        let cases = env.s11["cases"].array
        XCTAssertEqual(cases.count, 64)
        var calls = 0
        var windows = 0
        for c in cases {
            let name = c["name"].string
            let config = try configFor(c["constants"], env)
            let budget = VoiceCpuBudget(cpu: config.engine.cpu)
            var previous: TemplateRecord?
            for (k, call) in c["calls"].array.enumerated() {
                let label = "\(name) call \(k)"
                let recIn = try startRecord(call, previous, env)
                let run: Run
                do {
                    run = try runCall(config, call, recIn, budget, env)
                } catch {
                    XCTFail("\(label): \(error)")
                    previous = nil
                    continue
                }
                guard let result = run.engine.result else {
                    XCTFail("\(label): the call was not flushed")
                    previous = nil
                    continue
                }
                assertCall(label, call["expected"], run, env)
                previous = result.record
                calls += 1
                windows += run.recorder.windows.count
            }
        }
        XCTAssertGreaterThanOrEqual(calls, 64)
        XCTAssertGreaterThan(windows, 300)
    }

    /// A call that starts while the post-call work of the previous one is still due cancels it: `requestPostCancel` before the
    /// end of the call drops the pending windows that had not started (`dropped_cancelled`) and nothing else changes. The call is
    /// still flushed into the state functions, with what was embedded.
    func testACancelRequestedBeforeTheEndOfTheCallDropsThePostCallEmbeddings() throws {
        let env = try environment()
        let c = try XCTUnwrap(env.s11["cases"].array.first { $0["name"].string == "learn_first_call" })
        let config = try configFor(c["constants"], env)
        let call = c["calls"][0]
        let want = call["expected"]["windows"].array
        let post = want.filter { $0["fate"].string == "embedded_post_call" }.map { $0["n"].int }
        XCTAssertEqual(post.count, 1, "the case has one post-call window")
        let run = try runCall(config, call, try startRecord(call, nil, env), VoiceCpuBudget(cpu: config.engine.cpu), env) { engine, item in
            if case .callEnd = item { engine.requestPostCancel() }
        }
        for w in run.recorder.windows {
            let stored = want.first { $0["n"].int == w.n }?["fate"].string
            XCTAssertEqual(w.fate?.rawValue, post.contains(w.n) ? "dropped_cancelled" : stored, "window \(w.n)")
        }
        let res = try XCTUnwrap(run.engine.result)
        XCTAssertTrue(res.cancelled)
        XCTAssertTrue(res.ran)
        XCTAssertLessThan(res.flushNs, call["expected"]["flush"]["flush_ns"].int64,
                          "the flush is at the end of the call, not after the embeddings that were dropped")
    }

    // MARK: running a call

    private func configFor(_ overlay: KatJSON, _ env: Env) throws -> VoiceEngineConfig {
        var data = env.baseConstants
        if !overlay.isNull {
            var merged = try XCTUnwrap(try JSONSerialization.jsonObject(with: env.baseConstants) as? [String: Any])
            for (section, entries) in overlay.members {
                var m = try XCTUnwrap(merged[section] as? [String: Any], "\(section) is not a section of constants.json")
                for (key, value) in entries.members {
                    XCTAssertNotNil(m[key], "\(section).\(key) is not a key of constants.json")
                    m[key] = value.foundationValue
                }
                merged[section] = m
            }
            data = try JSONSerialization.data(withJSONObject: merged)
        }
        return VoiceEngineConfig(
            constants: try VoiceConstants.decode(data), scoring: try VoiceScoringConstants.decode(data),
            state: try VoiceStateConstants.parse(data), engine: try VoiceEngineConstants.parse(data),
            tables: env.bundle.tables, cohort: env.cohort)
    }

    private func startRecord(_ call: KatJSON, _ previous: TemplateRecord?, _ env: Env) throws -> TemplateRecord? {
        let r = call["record"]
        if r.isNull { return nil }
        if !r["from"].isNull { return previous }
        let rec = VoiceStateKat.fieldsToRecord(r, env.rows)
        return try TemplateCodec.decode(try TemplateCodec.encode(rec))
    }

    private func tierInput(_ j: KatJSON) -> VoiceTierInput? {
        j.isNull ? nil : VoiceStage12TierTests.tierInput(j)
    }

    private func runCall(_ config: VoiceEngineConfig, _ call: KatJSON, _ recIn: TemplateRecord?, _ budget: VoiceCpuBudget, _ env: Env,
                         before: ((VoiceEngine, VoiceEngineItem) -> Void)? = nil) throws -> Run {
        let vadSpec = call["vad"]
        let p = try VoiceKat.floats(vadSpec["file"].string)
        XCTAssertEqual(p.count, vadSpec["n"].int)
        let cost = vadSpec["cost_us"].int64s
        let vad = ScriptVad(p: p, base: cost[0], perStep: cost[1], failAt: vadSpec["fail_at"].isNull ? nil : vadSpec["fail_at"].int)
        var script: [Int: KatJSON] = [:]
        for e in call["script"].array { script[e["n"].int] = e }
        let embedder = ScriptEmbedder(script: script, rows: env.rows)
        let model = try XCTUnwrap(VoiceModelStatus(rawValue: call["model"].string))
        let display: VoiceScoringConstants.Display? = call["display"].isNull
            ? nil
            : VoiceScoringConstants.Display(differs: call["display"]["differs"].flag, change: call["display"]["change"].flag)
        let info = VoiceCallInfo(
            callId: call["call_id"].string, ownerOn: call["owner_on"].flag, model: model, record: recIn,
            tStartS: call["t_start_s"].int, utcOffsetS: call["utc_offset_s"].int,
            deviceTag: VoiceTags.deviceTag(nameSalt: env.salt, deviceId: call["device"].string), display: display,
            ownerTemplate: call["owner_template"].isNull ? nil : VoiceStateKat.row(env.rows, call["owner_template"]["vec"].int))
        let recorder = Recorder()
        let finalizer: VoiceCallFinalizer = { rec, c in
            let end = try VoiceTemplateState.endOfCall(rec, c, config.state)
            let written = try end.record.map { try TemplateCodec.decode(try TemplateCodec.encode($0)) }
            return VoiceFinish(before: rec, end: CallEnd(record: written, result: end.result))
        }
        let engine = try VoiceEngine(
            config: config, call: info, vad: vad, embedder: embedder, budget: budget, finalizer: finalizer, listener: recorder)
        let tMedia = call["t_media_ns"].int64
        engine.feed(.mediaStart(atNs: tMedia, tNs: tMedia, tierInput: tierInput(call["tier_input"])))
        for item in try items(call, env) {
            before?(engine, item)
            engine.feed(item)
        }
        engine.close()
        return Run(engine: engine, recorder: recorder)
    }

    /// The items of a call in the order in which they are fed: by `at_ns`, at the same instant the RX blocks first in block
    /// order, then the others in the order of the list.
    private func items(_ call: KatJSON, _ env: Env) throws -> [VoiceEngineItem] {
        var out: [Keyed] = []
        var prevAt: Int64 = 0
        for seg in call["taps"].array {
            let src = try audio(seg["audio"].string, env)
            let rate = seg["rate"].int
            let first = seg["first"].int
            let blocks = seg["blocks"].ints
            let tEnd = seg["t_end_ns"].int64s
            let ticks = seg["ticks"].int64s
            let drop = Set(seg["drop"].ints)
            let late = seg["late"]
            let unreported = !seg["unreported"].isNull && seg["unreported"].flag
            var off = 0
            var dropped = 0
            for b in blocks.indices {
                if drop.contains(b) {
                    dropped += 1
                } else {
                    let extra = late["\(b)"].isNull ? Int64(0) : late["\(b)"].int64
                    let at = max(tEnd[b] + extra, prevAt) // the RX queue is in order
                    prevAt = at
                    let pcm = Array(src[(first + off)..<(first + off + blocks[b])])
                    let item = VoiceEngineItem.rx(
                        atNs: at, tNs: tEnd[b], rateHz: rate, ticks: ticks[b], pcm: pcm, dropped: (dropped != 0 && !unreported) ? dropped : 0)
                    out.append(Keyed(at: at, group: 0, idx: out.count, item: item))
                    dropped = 0
                }
                off += blocks[b]
            }
        }
        let base = out.count
        for (i, o) in call["items"].array.enumerated() {
            let at = o["at_ns"].int64
            let item: VoiceEngineItem
            switch o["kind"].string {
            case "media_start": item = .mediaStart(atNs: at, tNs: o["t_ns"].int64, tierInput: tierInput(o["tier_input"]))
            case "stats": item = .stats(atNs: at, snapshot: VoiceStatsSnapshot(json: o["snapshot"]))
            case "mute": item = .mute(atNs: at, tNs: o["t_ns"].int64, muted: o["muted"].flag)
            case "vcons":
                let v = o["vcons"]
                item = .vcons(
                    atNs: at,
                    vcons: VoiceVcons(seq: v["seq"].int, allow: v["allow"].flag, withdraw: v["withdraw"].flag, routeClass: v["route_class"].int),
                    wallS: o["wall_s"].int)
            case "route": item = .route(atNs: at, routeClass: o["route_class"].int)
            case "hold": item = .hold(atNs: at, held: o["held"].flag)
            case "path": item = .path(atNs: at, path: VoicePath(rawValue: o["path"].string) ?? .srtp)
            case "tier": item = .tier(atNs: at, input: VoiceStage12TierTests.tierInput(o["input"]))
            case "busy": item = .busy(atNs: at, who: o["who"].string, startNs: o["start_ns"].int64, endNs: o["end_ns"].int64)
            case "was_him": item = .wasHim(atNs: at)
            case "call_end": item = .callEnd(atNs: at, tNs: o["t_ns"].int64)
            case "post_cancel": item = .postCancel(atNs: at)
            default:
                XCTFail("unknown kind \(o["kind"].string)")
                continue
            }
            out.append(Keyed(at: at, group: 1, idx: base + i, item: item))
        }
        out.sort { ($0.at, $0.group, $0.idx) < ($1.at, $1.group, $1.idx) }
        return out.map { $0.item }
    }

    // MARK: comparing

    private func assertCall(_ label: String, _ want: KatJSON, _ run: Run, _ env: Env) {
        let eng = run.engine
        let rec = run.recorder
        // the window list: integers, flags, fate and instants exact; the stage 3 floats relative 1e-4; l_c absolute 1e-3
        let ww = want["windows"].array
        XCTAssertEqual(rec.windows.count, ww.count, "\(label): number of windows")
        if rec.windows.count == ww.count {
            for i in ww.indices { assertWindow("\(label) window \(i)", ww[i], rec.windows[i]) }
        }
        let skips = want["skips"]
        XCTAssertEqual(eng.skipCounts.blocks, skips["blocks"].int, "\(label): skips.blocks")
        XCTAssertEqual(eng.skipCounts.overflow, skips["overflow"].int, "\(label): skips.overflow")
        // the transitions and the lines carry the instant on the injected clock
        let tw = want["transitions"].array
        XCTAssertEqual(rec.transitions.count, tw.count, "\(label): number of transitions")
        if rec.transitions.count == tw.count {
            for i in tw.indices {
                let w = tw[i]
                let g = rec.transitions[i]
                let at = "\(label) transition \(i)"
                XCTAssertEqual(g.tNs, w["t_ns"].int64, "\(at): t_ns")
                XCTAssertEqual(g.from.rawValue, w["from"].string, "\(at): from")
                XCTAssertEqual(g.shown.rawValue, w["shown"].string, "\(at): shown")
                XCTAssertEqual(g.detail?.rawValue, w["detail"].stringValue, "\(at): detail")
                XCTAssertEqual(g.cand.rawValue, w["cand"].string, "\(at): cand")
                XCTAssertEqual(g.b, w["b"].int, "\(at): b")
            }
        }
        let wantLines = want["lines"].array.map { "\($0["t_ns"].int64) \($0["line"].string)" }
        let gotLines = rec.lines.map { "\($0.0) \($0.1)" }
        XCTAssertEqual(gotLines.joined(separator: "\n"), wantLines.joined(separator: "\n"), "\(label): lines")
        let wantEffects = want["effects"].array.map { "\($0["t_ns"].int64) \($0["effect"].string)" }
        let gotEffects = rec.effects.map { "\($0.0) \($0.1.rawValue)" }
        XCTAssertEqual(gotEffects, wantEffects, "\(label): effects")
        // the displayed state at the end of the call
        let fw = want["final"]
        guard let f = eng.finalState else {
            XCTFail("\(label): no final state")
            return
        }
        XCTAssertEqual(f.shown.rawValue, fw["shown"].string, "\(label): final.shown")
        XCTAssertEqual(f.detail?.rawValue, fw["detail"].stringValue, "\(label): final.detail")
        XCTAssertEqual(f.cand.rawValue, fw["cand"].string, "\(label): final.cand")
        XCTAssertEqual(f.b, fw["b"].int, "\(label): final.b")
        XCTAssertLessThanOrEqual(abs(f.worst - fw["worst"].double), 1e-9, "\(label): final.worst \(f.worst) vs \(fw["worst"].double)")
        XCTAssertEqual(f.blockN, fw["block_n"].int, "\(label): final.block_n")
        XCTAssertEqual(f.differed, fw["differed"].flag, "\(label): final.differed")
        XCTAssertEqual(f.scored, fw["scored"].int, "\(label): final.scored")
        XCTAssertEqual(f.unc, fw["unc"].int, "\(label): final.unc")
        XCTAssertEqual(f.speechMs, fw["speech_ms"].int64, "\(label): final.speech_ms")
        XCTAssertEqual(f.routeCovered, fw["route_covered"].flag, "\(label): final.route_covered")
        XCTAssertEqual(f.deviceCovered, fw["device_covered"].flag, "\(label): final.device_covered")
        // the inputs that reached the stats stream late or lost
        let late = want["late"]
        let lc = eng.lateCounts
        XCTAssertEqual(lc[0], late["late_rx"].int, "\(label): late_rx")
        XCTAssertEqual(lc[1], late["late_mute"].int, "\(label): late_mute")
        XCTAssertEqual(lc[2], late["late_delivery"].int, "\(label): late_delivery")
        XCTAssertEqual(lc[3], late["lost_mute"].int, "\(label): lost_mute")
        XCTAssertEqual(lc[4], late["cap"].int, "\(label): cap")
        // the flush and the record
        let fl = want["flush"]
        guard let res = eng.result else {
            XCTFail("\(label): no result")
            return
        }
        XCTAssertEqual(res.flushNs, fl["flush_ns"].int64, "\(label): flush_ns")
        XCTAssertEqual(res.cancelled, fl["cancelled"].flag, "\(label): cancelled")
        XCTAssertEqual(res.ran, fl["ran"].flag, "\(label): ran")
        XCTAssertFalse(res.failed, "\(label): the state functions threw")
        if fl["info"].isNull {
            XCTAssertNil(res.info, "\(label): info")
        } else if let info = res.info {
            VoiceStateKat.assertJson("\(label): flush.info", fl["info"], VoiceStateKat.callResultJson(info))
        } else {
            XCTFail("\(label): no info")
        }
        VoiceStateKat.assertRecord("\(label): record", res.record, want["record"], env.rows, 5e-4)
    }

    private func assertWindow(_ at: String, _ w: KatJSON, _ g: VoiceWindowRecord) {
        XCTAssertEqual(g.n, w["n"].int, "\(at): n")
        XCTAssertEqual(g.epoch, w["epoch"].int, "\(at): epoch")
        XCTAssertEqual(g.w, w["w"].int, "\(at): w")
        XCTAssertEqual(g.disjoint, w["disjoint"].flag, "\(at): disjoint")
        XCTAssertEqual(g.ranges, w["ranges"].array.map { $0.ints }, "\(at): ranges")
        XCTAssertEqual(g.first, w["first"].int, "\(at): first")
        XCTAssertEqual(g.last, w["last"].int, "\(at): last")
        let flags: [(String, Bool)] = [
            ("enroll", g.enroll), ("score", g.score), ("certain", g.certain), ("nb", g.nb), ("conc_unknown", g.concUnknown),
            ("tx_unknown", g.txUnknown)
        ]
        for (k, v) in flags { XCTAssertEqual(v, w[k].flag, "\(at): \(k)") }
        XCTAssertEqual(g.plcEvents, w["plc_events"].int, "\(at): plc_events")
        XCTAssertEqual(g.stretchEvents, w["stretch_events"].int, "\(at): stretch_events")
        XCTAssertEqual(g.routeClass, w["route_class"].int, "\(at): route_class")
        XCTAssertEqual(g.fate?.rawValue, w["fate"].string, "\(at): fate")
        XCTAssertEqual(g.tCutNs, w["t_cut_ns"].int64, "\(at): t_cut_ns")
        let floats: [(String, Double)] = [
            ("mean_p", g.meanP), ("speech_P", g.speechP), ("noise_P", g.noiseP), ("snr_db", g.snrDb), ("clip_frac", g.clipFrac),
            ("plc", g.plc), ("bw", g.bw)
        ]
        for (k, v) in floats {
            XCTAssertTrue(VoiceKat.closeStats(v, w[k].double), "\(at): \(k) \(v) vs \(w[k].double)")
        }
        XCTAssertEqual(g.embedStartNs, w["embed_start_ns"].optionalInt64, "\(at): embed_start_ns")
        XCTAssertEqual(g.embedDoneNs, w["embed_done_ns"].optionalInt64, "\(at): embed_done_ns")
        XCTAssertEqual(g.embedMs, w["embed_ms"].optionalInt64, "\(at): embed_ms")
        if let want = w["l_c"].optionalDouble {
            if let got = g.lC {
                XCTAssertLessThanOrEqual(abs(got - want), 1e-3, "\(at): l_c got \(got), want \(want)")
            } else {
                XCTFail("\(at): l_c is missing")
            }
        } else {
            XCTAssertNil(g.lC, "\(at): l_c")
        }
        XCTAssertEqual(g.cand?.rawValue, w["cand"].stringValue, "\(at): cand")
        XCTAssertEqual(g.ref, w["ref"].isNull ? nil : w["ref"].flag, "\(at): ref")
        XCTAssertEqual(g.stale, w["stale"].isNull ? false : w["stale"].flag, "\(at): stale")
    }
}

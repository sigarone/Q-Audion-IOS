import XCTest
import Foundation
@testable import QAudionEngine

/// Measurements and windows: the clips fed to the streaming front-end in tap-clock order (blocks, stats deliveries, mute
/// changes and events interleaved), the stats track alone, and the window assembler on synthetic chunk tables.
final class VoiceKatStage3Tests: XCTestCase {

    private struct TapSegment {
        var audio: [Int16]
        var rate: Int
        var blockLengths: [Int]
        var clock: [Int64]
        var ticks: [Int64]
    }

    private struct ClipEvent {
        var kind: VoiceFrontEndEvent
        var atInput: Int
    }

    private func eventKind(_ name: String) -> VoiceFrontEndEvent {
        switch name {
        case "hold": return .hold
        case "resume": return .resume
        case "route": return .route
        default: return .reset
        }
    }

    private func checkClip(_ name: String) throws {
        let bundle = try VoiceKat.bundle()
        let inputs = try VoiceKat.json("stage3_measure/clip_\(name).inputs.json")
        let expected = try VoiceKat.json("stage3_measure/clip_\(name).expected.json")
        let storedP = try VoiceKat.floats("stage2_vad/clip_\(name).p.f32")
        let storedLabels = try VoiceKat.bytes("stage2_vad/clip_\(name).label.u8")

        var segments: [TapSegment] = []
        var passThrough: [Int: [Float]] = [:]
        for (j, seg) in inputs["tap_segments"].array.enumerated() {
            let wav = try VoiceKat.wav(seg["audio_file"].string)
            XCTAssertEqual(wav.rate, seg["rate"].int)
            let first = seg["first_sample"].int
            let audio = Array(wav.samples[first..<(first + seg["n_samples"].int)])
            segments.append(TapSegment(
                audio: audio,
                rate: seg["rate"].int,
                blockLengths: seg["block_lengths"].ints,
                clock: seg["t_end_ns"].int64s,
                ticks: seg["tap_ticks_end"].int64s))
            passThrough[j] = VoiceKat.scaled(audio)
        }
        var eventsByTap: [Int: [ClipEvent]] = [:]
        for e in inputs["events"].array {
            let tap = e["tap"].int
            if e["kind"].string == "reset" && e["at_input"].int == 0 && tap > 0 {
                continue
            }
            eventsByTap[tap, default: []].append(ClipEvent(kind: eventKind(e["kind"].string), atInput: e["at_input"].int))
        }
        let snapshots = inputs["stats"]["snapshots"].array.map { VoiceStatsSnapshot(json: $0) }
        let mutes = inputs["mutes"].array.map { VoiceMute(tNs: $0["t_ns"].int64, muted: $0["muted"].flag) }

        var records: [VoiceChunkRecord] = []
        var windows: [VoiceWindowResult] = []
        let engine = VoiceFrontEnd(bundle: bundle, vad: StoredProbabilityVad(storedP))
        engine.onChunk = { records.append($0) }
        engine.onWindow = { windows.append($0) }

        var nextSnapshot = 0
        var nextMute = 0
        func deliverStats(before limit: Int64?) {
            while nextSnapshot < snapshots.count {
                let snapshot = snapshots[nextSnapshot]
                if let bound = limit, snapshot.arriveNs >= bound {
                    break
                }
                while nextMute < mutes.count && mutes[nextMute].tNs <= snapshot.arriveNs {
                    engine.onMute(tNs: mutes[nextMute].tNs, muted: mutes[nextMute].muted)
                    nextMute += 1
                }
                engine.onStats(snapshot)
                nextSnapshot += 1
            }
        }

        for (j, seg) in segments.enumerated() {
            let events = (eventsByTap[j] ?? []).sorted { $0.atInput < $1.atInput }
            var position = 0
            for (b, length) in seg.blockLengths.enumerated() {
                deliverStats(before: seg.clock[b])
                while nextMute < mutes.count && mutes[nextMute].tNs <= seg.clock[b] {
                    engine.onMute(tNs: mutes[nextMute].tNs, muted: mutes[nextMute].muted)
                    nextMute += 1
                }
                let start = position
                let end = position + length
                if b == 0 {
                    for e in events where e.atInput == 0 {
                        engine.onEvent(e.kind)
                    }
                }
                engine.registerTapBlock(count: length, rateHz: seg.rate, tNs: seg.clock[b], tapTicks: seg.ticks[b])
                var cursor = start
                var positions: [Int] = []
                for e in events where e.atInput > start && e.atInput <= end && !positions.contains(e.atInput) {
                    positions.append(e.atInput)
                }
                for pos in positions {
                    try engine.push(seg.audio[cursor..<pos])
                    cursor = pos
                    for e in events where e.atInput == pos {
                        if e.kind == .reset {
                            XCTAssertEqual(engine.inputPosition, pos, "clip \(name): reset position")
                        }
                        engine.onEvent(e.kind)
                    }
                }
                try engine.push(seg.audio[cursor..<end])
                position = end
            }
        }
        deliverStats(before: nil)
        while nextMute < mutes.count {
            engine.onMute(tNs: mutes[nextMute].tNs, muted: mutes[nextMute].muted)
            nextMute += 1
        }
        let releasedBeforeEnd = records.count
        engine.finish()
        XCTAssertGreaterThan(releasedBeforeEnd, records.count / 2, "clip \(name): chunks are released while the call runs")

        XCTAssertEqual(engine.mediaStartNs, expected["t_media_ns"].int64, "clip \(name) media start")

        // Chunks.
        let columns = expected["chunks"]
        XCTAssertEqual(records.count, columns["idx"].count, "clip \(name) chunk count")
        let count = min(records.count, columns["idx"].count)
        let stream = try VoiceKat.chunkStream(inputs["stream_segments"], passThrough: passThrough)
        XCTAssertEqual(stream.count, records.count * VoiceChunker.chunkLength, "clip \(name) stream length")
        for i in 0..<count {
            let r = records[i]
            let at = "clip \(name) chunk \(i)"
            XCTAssertEqual(r.index, columns["idx"][i].int, "\(at) idx")
            XCTAssertEqual(r.t0Ns, columns["t0_ns"][i].int64, "\(at) t0")
            XCTAssertEqual(r.t1Ns, columns["t1_ns"][i].int64, "\(at) t1")
            XCTAssertTrue(VoiceKat.closeStats(r.power, columns["P"][i].double), "\(at) P")
            XCTAssertEqual(r.clip, columns["clip"][i].int, "\(at) clip")
            XCTAssertEqual(r.nin, columns["nin"][i].int, "\(at) nin")
            XCTAssertEqual(r.epoch, columns["epoch"][i].int, "\(at) epoch")
            XCTAssertEqual(r.excluded, columns["excl"][i].flag, "\(at) excl")
            XCTAssertEqual(r.txUnknown, columns["tx_unknown"][i].flag, "\(at) tx_unknown")
            XCTAssertEqual(r.concUnknown, columns["conc_unknown"][i].flag, "\(at) conc_unknown")
            XCTAssertEqual(r.touchConcealment, columns["touch_conc"][i].flag, "\(at) touch_conc")
            XCTAssertEqual(r.touchStretch, columns["touch_stretch"][i].flag, "\(at) touch_stretch")
            XCTAssertEqual(r.label, Int(storedLabels[i]), "\(at) label")
            var worst: Float = 0
            let base = i * VoiceChunker.chunkLength
            for k in 0..<VoiceChunker.chunkLength {
                worst = max(worst, abs(r.samples[k] - stream[base + k]))
            }
            XCTAssertLessThanOrEqual(worst, 1e-5, "\(at) samples")
        }

        assertIntervalColumns(engine.statsTrack.intervals, expected["intervals"], "clip \(name)")
        assertWindows(windows, expected["windows"], "clip \(name)")
    }

    func testClipA() throws { try checkClip("a") }
    func testClipB() throws { try checkClip("b") }
    func testClipC() throws { try checkClip("c") }
    func testClipD() throws { try checkClip("d") }
    func testClipE() throws { try checkClip("e") }
    func testClipF() throws { try checkClip("f") }
    func testClipH() throws { try checkClip("h") }

    // MARK: stats vector

    private func runs(of flags: [Bool]) -> [[Int]] {
        var out: [[Int]] = []
        var start: Int?
        for (i, value) in flags.enumerated() {
            if value && start == nil {
                start = i
            }
            if !value, let first = start {
                out.append([first, i - first])
                start = nil
            }
        }
        if let first = start {
            out.append([first, flags.count - first])
        }
        return out
    }

    /// Every case of the stats vector, delivered in order (a tap block at or before a delivery goes first); each probe
    /// chunk is read the moment its flags are final, and the final intervals are compared at the end.
    func testStatsVector() throws {
        let gates = try VoiceKat.bundle().constants.gates
        let doc = try VoiceKat.json("stage3_measure/stats_cases.json")
        let mediaStart = doc["t_media_ns"].int64
        let chunkNs = doc["chunk_ns"].int64
        let probes = doc["n_chunks"].int
        XCTAssertEqual(doc["cases"].count, 44)

        for testCase in doc["cases"].array {
            let name = testCase["name"].string
            let stream = VoiceStatsStream(gates: gates)
            var blocks: [(t: Int64, ticks: Int64)] = []
            for run in testCase["tap"].array {
                for j in 0..<run["n"].int {
                    blocks.append((
                        t: run["t_ns"].int64 + Int64(j) * run["period_ns"].int64,
                        ticks: run["ticks"].int64 + Int64(j) * run["step"].int64))
                }
            }
            blocks = blocks.enumerated().sorted { a, b in
                a.element.t != b.element.t ? a.element.t < b.element.t : a.offset < b.offset
            }.map { $0.element }
            for m in testCase["mutes"].array {
                stream.addMute(tNs: m["t_ns"].int64, muted: m["muted"].flag)
            }

            var excluded = [Bool](repeating: false, count: probes)
            var txUnknown = excluded
            var concUnknown = excluded
            var touchConcealment = excluded
            var touchStretch = excluded
            var next = 0
            func drain() {
                while next < probes {
                    let t0 = mediaStart + Int64(next) * chunkNs
                    let t1 = t0 + chunkNs
                    if !stream.isConcealmentFinal(t1: t1) || !stream.isTxFinal(t1: t1) {
                        return
                    }
                    let tx = stream.track.txFlags(t0: t0, t1: t1, mediaStart: mediaStart)
                    let conc = stream.track.concFlags(t0: t0, t1: t1, mediaStart: mediaStart)
                    excluded[next] = tx.excluded
                    txUnknown[next] = tx.unknown
                    concUnknown[next] = conc.unknown
                    touchConcealment[next] = conc.concealment
                    touchStretch[next] = conc.stretch
                    next += 1
                }
            }

            var b = 0
            for snapshotJson in testCase["snapshots"].array {
                let snapshot = VoiceStatsSnapshot(json: snapshotJson)
                while b < blocks.count && blocks[b].t <= snapshot.arriveNs {
                    stream.addTapBlock(tNs: blocks[b].t, ticks: blocks[b].ticks)
                    b += 1
                    drain()
                }
                stream.addSnapshot(snapshot)
                drain()
            }
            while b < blocks.count {
                stream.addTapBlock(tNs: blocks[b].t, ticks: blocks[b].ticks)
                b += 1
                drain()
            }
            let releasedBeforeEnd = next
            stream.finish()
            drain()
            XCTAssertEqual(next, probes, "case \(name): every probe chunk is released")
            if name == "steady" {
                XCTAssertEqual(releasedBeforeEnd, probes, "the steady case releases every probe before the call ends")
            }

            let want = testCase["expected"]
            assertIntervalColumns(stream.track.intervals, want["intervals"], "case \(name)")
            let flags = want["chunks"]
            XCTAssertEqual(runs(of: excluded), flags["excl"].array.map { $0.ints }, "case \(name) excl")
            XCTAssertEqual(runs(of: txUnknown), flags["tx_unknown"].array.map { $0.ints }, "case \(name) tx_unknown")
            XCTAssertEqual(runs(of: concUnknown), flags["conc_unknown"].array.map { $0.ints }, "case \(name) conc_unknown")
            XCTAssertEqual(runs(of: touchConcealment), flags["touch_conc"].array.map { $0.ints }, "case \(name) touch_conc")
            XCTAssertEqual(runs(of: touchStretch), flags["touch_stretch"].array.map { $0.ints }, "case \(name) touch_stretch")
        }
    }

    // MARK: window vector

    func testWindowVector() throws {
        let bundle = try VoiceKat.bundle()
        let constants = bundle.constants
        let fbank = VoiceFbank(tables: bundle.tables, constants: constants.fbank)
        let doc = try VoiceKat.json("stage3_measure/windows_vector.json")
        let chunkNs = doc["chunk_ns"].int64
        var sources: [String: [Float]] = [:]
        for key in ["wb", "nb"] {
            sources[key] = try VoiceKat.floats(doc["sources"][key].string)
        }
        XCTAssertEqual(doc["cases"].count, 7)

        for testCase in doc["cases"].array {
            let name = testCase["name"].string
            var given: [VoiceStatsInterval] = []
            for iv in testCase["intervals"].array {
                given.append(VoiceStatsInterval(
                    key: 0,
                    startNs: iv["start_ns"].int64,
                    endNs: iv["end_ns"].int64,
                    known: iv["known"].flag,
                    isGuard: false,
                    audible: iv["audible"].int64,
                    silent: iv["silent"].int64,
                    events: iv["events"].int64,
                    total: iv["total"].int64,
                    stretch: iv["stretch"].int64))
            }
            let track = VoiceStatsTrack(intervals: given, gates: constants.gates)
            let events = testCase["events"].array.map { $0["at_chunk"].int }.sorted()

            let assembler = VoiceWindowAssembler(constants: constants, fbank: fbank)
            var windows: [VoiceWindowResult] = []
            var index = 0
            var epoch = 0
            var nextEvent = 0
            for run in testCase["runs"].array {
                for j in 0..<run["n"].int {
                    while nextEvent < events.count && events[nextEvent] <= index {
                        epoch += 1
                        nextEvent += 1
                    }
                    let t0 = run["t0_ns"].int64 + Int64(j) * chunkNs
                    let label = run["label"].int
                    let excl = run["excl"].flag
                    let accepted = label == 1 && !excl
                    var samples: [Float] = []
                    if !run["src"].isNull {
                        let chunk = run["src_chunk"].int + j
                        let source = sources[run["src"].string] ?? []
                        samples = Array(source[(chunk * 512)..<(chunk * 512 + 512)])
                    }
                    let record = VoiceChunkRecord(
                        index: index,
                        t0Ns: t0,
                        t1Ns: t0 + chunkNs,
                        power: run["P"].double * pow(run["P_mul"].double, Double(j)),
                        clip: run["clip"].int,
                        nin: run["nin"].int,
                        epoch: epoch,
                        probability: run["p"].double,
                        label: label,
                        excluded: excl,
                        txUnknown: run["tx_unknown"].flag,
                        concUnknown: run["conc_unknown"].flag,
                        touchConcealment: false,
                        touchStretch: false,
                        samples: samples,
                        overlaps: accepted ? track.overlappingKnown(t0: t0, t1: t0 + chunkNs) : [])
                    if let window = assembler.push(record) {
                        windows.append(window)
                    }
                    index += 1
                }
            }
            XCTAssertEqual(index, testCase["n_chunks"].int, "case \(name) chunk count")
            assertWindows(windows, testCase["expected"]["windows"], "case \(name)")
        }
    }
}

import XCTest
import Foundation
@testable import QAudionEngine

/// Measurements and windows: the clips fed to the streaming front-end in tap-clock order (blocks, stats deliveries, mute
/// changes and events interleaved), the stats stream alone on every case of the stats vector, and the window assembler on
/// synthetic chunk tables.
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
        var atChunk: Int
    }

    /// One input of the timeline of a clip: tap-clock time, kind (RX blocks, then mute changes, then deliveries at the same
    /// time) and the order of the lists.
    private struct TimelineItem {
        var tNs: Int64
        var priority: Int
        var seq: Int
        var run: () -> Void
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
        var rateChangeAtChunk: [Int: Int] = [:]
        for e in inputs["events"].array {
            let tap = e["tap"].int
            if e["kind"].string == "reset" && e["at_input"].int == 0 && tap > 0 {
                rateChangeAtChunk[tap] = e["at_chunk"].int
                continue
            }
            eventsByTap[tap, default: []].append(ClipEvent(
                kind: eventKind(e["kind"].string), atInput: e["at_input"].int, atChunk: e["at_chunk"].int))
        }
        let snapshots = inputs["stats"]["snapshots"].array.map { VoiceStatsSnapshot(json: $0) }
        let mutes = inputs["mutes"].array.map { VoiceMute(tNs: $0["t_ns"].int64, muted: $0["muted"].flag) }

        var records: [VoiceChunkRecord] = []
        var windows: [VoiceWindowResult] = []
        var intervals: [VoiceStatsInterval] = []
        let engine = VoiceFrontEnd(bundle: bundle, vad: StoredProbabilityVad(storedP))
        engine.onChunk = { records.append($0) }
        engine.onWindow = { windows.append($0) }
        engine.statsStream.intervalListener = { intervals.append($0) }

        // The whole call as one timeline by tap-clock time: at the same time RX blocks, then mute changes, then deliveries.
        var timeline: [TimelineItem] = []
        var seq = 0
        for (j, seg) in segments.enumerated() {
            let events = (eventsByTap[j] ?? []).sorted { $0.atInput < $1.atInput }
            var eventIndex = 0
            var position = 0
            for (b, length) in seg.blockLengths.enumerated() {
                let start = position
                let end = position + length
                var atStart: [ClipEvent] = []
                while eventIndex < events.count && events[eventIndex].atInput <= start {
                    atStart.append(events[eventIndex])
                    eventIndex += 1
                }
                var inside: [ClipEvent] = []
                while eventIndex < events.count && events[eventIndex].atInput < end {
                    inside.append(events[eventIndex])
                    eventIndex += 1
                }
                var trailing: [ClipEvent] = []
                if b == seg.blockLengths.count - 1 {
                    while eventIndex < events.count {
                        trailing.append(events[eventIndex])
                        eventIndex += 1
                    }
                }
                let rate = seg.rate
                let tNs = seg.clock[b]
                let ticks = seg.ticks[b]
                let audio = seg.audio
                timeline.append(TimelineItem(tNs: tNs, priority: 0, seq: seq) {
                    for e in atStart {
                        XCTAssertEqual(engine.nextChunkIndex, e.atChunk, "clip \(name): at_chunk of an event at input \(e.atInput)")
                        engine.onEvent(e.kind)
                    }
                    if b == 0 && j > 0 {
                        XCTAssertEqual(
                            engine.nextChunkIndex, rateChangeAtChunk[j], "clip \(name): at_chunk of the rate change of tap segment \(j)")
                    }
                    engine.registerTapBlock(count: length, rateHz: rate, tNs: tNs, tapTicks: ticks)
                    var cursor = start
                    for e in inside {
                        if e.atInput > cursor {
                            engine.push(audio[cursor..<e.atInput])
                            cursor = e.atInput
                        }
                        XCTAssertEqual(engine.nextChunkIndex, e.atChunk, "clip \(name): at_chunk of an event at input \(e.atInput)")
                        if e.kind == .reset {
                            XCTAssertEqual(engine.inputPosition, e.atInput, "clip \(name): reset position")
                        }
                        engine.onEvent(e.kind)
                    }
                    if end > cursor {
                        engine.push(audio[cursor..<end])
                    }
                    for e in trailing {
                        XCTAssertEqual(engine.nextChunkIndex, e.atChunk, "clip \(name): at_chunk of an event at input \(e.atInput)")
                        engine.onEvent(e.kind)
                    }
                })
                seq += 1
                position = end
            }
        }
        for m in mutes {
            timeline.append(TimelineItem(tNs: m.tNs, priority: 1, seq: seq) {
                engine.onMute(tNs: m.tNs, muted: m.muted)
            })
            seq += 1
        }
        for s in snapshots {
            timeline.append(TimelineItem(tNs: s.arriveNs, priority: 2, seq: seq) {
                engine.onStats(s)
            })
            seq += 1
        }
        timeline.sort { a, b in
            if a.tNs != b.tNs { return a.tNs < b.tNs }
            if a.priority != b.priority { return a.priority < b.priority }
            return a.seq < b.seq
        }
        for item in timeline {
            item.run()
        }
        let releasedBeforeEnd = records.count
        engine.finish(endNs: inputs["end_ns"].int64)
        XCTAssertGreaterThan(releasedBeforeEnd, records.count / 2, "clip \(name): chunks are released while the call runs")
        XCTAssertFalse(engine.isInactive)

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
            XCTAssertEqual(r.overdue, columns["overdue"][i].flag, "\(at) overdue")
            XCTAssertEqual(r.releaseNs, columns["release_ns"][i].int64, "\(at) release_ns")
            XCTAssertEqual(r.label, Int(storedLabels[i]), "\(at) label")
            var worst: Float = 0
            let base = i * VoiceChunker.chunkLength
            for k in 0..<VoiceChunker.chunkLength {
                worst = max(worst, abs(r.samples[k] - stream[base + k]))
            }
            XCTAssertLessThanOrEqual(worst, 1e-5, "\(at) samples")
        }

        assertIntervalColumns(intervals, expected["intervals"], "clip \(name)")
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

    /// Every case of the stats vector (76), fed as the contract says: RX blocks, mute changes and deliveries by tap-clock
    /// time (at the same time in that order), the end of the call last, and, for a case with `late` entries, the inputs that
    /// reach the engine late or never behind the ones the worker has fed by then. After every input the chunks that were
    /// released are collected; for each the five flags, `overdue` and the clock at its release are compared. A case without
    /// an input that really arrives late also compares the intervals and the dropped deliveries with the stored ones.
    func testStatsVector() throws {
        let gates = try VoiceKat.bundle().constants.gates
        let doc = try VoiceKat.json("stage3_measure/stats_cases.json")
        let mediaStart = doc["t_media_ns"].int64
        let chunkNs = doc["chunk_ns"].int64
        let holdNs = doc["reorder_hold_ns"].int64
        XCTAssertEqual(holdNs, 100_000_000)
        XCTAssertEqual(doc["cases"].count, 76)
        var lateCases = 0

        for testCase in doc["cases"].array {
            let name = testCase["name"].string
            let probes = testCase["n_chunks"].int
            let endNs = testCase["end_ns"].int64
            let snapshots = testCase["snapshots"].array.map { VoiceStatsSnapshot(json: $0) }

            let stream = VoiceStatsStream(gates: gates)
            var intervals: [VoiceStatsInterval] = []
            stream.intervalListener = { intervals.append($0) }
            var dropped: [String] = []
            stream.dropListener = { snapshot, rule in
                if rule != "late" && rule != "cap" {
                    let index = snapshots.firstIndex { $0.arriveNs == snapshot.arriveNs } ?? -1
                    dropped.append("\(index):\(rule)")
                }
            }
            stream.setMediaStart(mediaStart)
            // Every probe chunk is registered from the start: it cannot be final before its end.
            for i in 0..<probes {
                let t0 = mediaStart + Int64(i) * chunkNs
                if t0 + chunkNs <= endNs {
                    stream.addChunk(index: i, t0Ns: t0, t1Ns: t0 + chunkNs)
                }
            }
            var released = [VoiceChunkFlags?](repeating: nil, count: probes)
            func poll() {
                while let f = stream.pollFinal() {
                    XCTAssertNil(released[f.index], "case \(name): chunk \(f.index) released twice")
                    released[f.index] = f
                }
            }
            for step in VoiceStatsFeed.sequence(testCase, snapshots: snapshots, mediaStartNs: mediaStart, holdNs: holdNs) {
                VoiceStatsFeed.feed(stream, step)
                poll()
            }
            stream.finish(endNs: endNs)
            poll()

            let want = testCase["expected"]
            let late = stream.lateRxCount + stream.lateMuteCount + stream.lateDeliveryCount + stream.lostMuteCount
            if !testCase["late"].isNull {
                lateCases += 1
            } else {
                XCTAssertEqual(late, 0, "case \(name): nothing is late in a case without late entries")
            }
            if late == 0 {
                assertIntervalColumns(intervals, want["intervals"], "case \(name)")
                let wantDropped = want["dropped"].array.map { "\($0[0].int):\($0[1].string)" }
                XCTAssertEqual(dropped, wantDropped, "case \(name): dropped")
            }
            XCTAssertEqual(stream.capDroppedCount, 0, "case \(name): the cap decides nothing in the vector")

            guard released.allSatisfy({ $0 != nil }) else {
                XCTFail("case \(name): a chunk never became final")
                continue
            }
            let all = released.compactMap { $0 }
            let flags = want["chunks"]
            XCTAssertEqual(runs(of: all.map { $0.excluded }), flags["excl"].array.map { $0.ints }, "case \(name) excl")
            XCTAssertEqual(runs(of: all.map { $0.txUnknown }), flags["tx_unknown"].array.map { $0.ints }, "case \(name) tx_unknown")
            XCTAssertEqual(runs(of: all.map { $0.concUnknown }), flags["conc_unknown"].array.map { $0.ints }, "case \(name) conc_unknown")
            XCTAssertEqual(runs(of: all.map { $0.touchConcealment }), flags["touch_conc"].array.map { $0.ints }, "case \(name) touch_conc")
            XCTAssertEqual(runs(of: all.map { $0.touchStretch }), flags["touch_stretch"].array.map { $0.ints }, "case \(name) touch_stretch")
            XCTAssertEqual(runs(of: all.map { $0.overdue }), flags["overdue"].array.map { $0.ints }, "case \(name) overdue")

            // The clock at which each chunk was released: runs [first chunk, count, release_ns].
            var wantRelease = [Int64](repeating: -1, count: probes)
            for run in flags["release_ns"].array {
                let first = run[0].int
                for i in first..<(first + run[1].int) {
                    wantRelease[i] = run[2].int64
                }
            }
            for i in 0..<probes {
                XCTAssertEqual(all[i].releaseNs, wantRelease[i], "case \(name): release_ns of chunk \(i)")
            }
        }
        XCTAssertEqual(lateCases, 21, "the late cases of the vector")
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
                    let overdue = run["overdue"].flag
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
                        // A chunk released as overdue contributes no interval to the window ratios.
                        overlaps: accepted && !overdue ? track.overlappingKnown(t0: t0, t1: t0 + chunkNs) : [],
                        overdue: overdue)
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

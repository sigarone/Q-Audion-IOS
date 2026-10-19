import XCTest
@testable import QAudionEngine

/// What the engine does with a hole in the audio and with its stress history, against the rules of the
/// specification (docs/voice-analysis-spec.md, sections 2 and 8):
///
///  - a SHORT gap (< 2 s) that falls in the MIDDLE of a step discards the partial 10 ms frame and the frames
///    of the unfinished step, restarts the 100 ms grid and keeps every history;
///  - the long-gap threshold is exactly 96,000 samples, with the literals of the specification;
///  - the stress inputs are the f0 and the mean-removed rms of the VOICED steps only, the last 25, cleared by
///    a long gap and by `reset()`, kept over a short gap.
///
/// The vectors put their gaps on a step boundary, so none of this is pinned there.
final class VoiceAnalysisGapTests: XCTestCase {

    // MARK: - Helpers

    private final class Output {
        var raw: [VoiceAnalysisResult] = []
        var display: [VoiceAnalysisResult] = []
    }

    private func makeEngine() -> (engine: VoiceAnalysisEngine, output: Output) {
        let engine = VoiceAnalysisEngine()
        let output = Output()
        engine.onResult = { output.raw.append($0) }
        engine.onDisplay = { output.display.append($0) }
        return (engine, output)
    }

    private func signal(_ segments: [[String: Any]]) -> [Int16] {
        VoiceDspVectorGenerator.build(["segments": segments]).pcm
    }

    private func vowel(_ seconds: Double, f0: Any, rms: Double) -> [String: Any] {
        ["type": "voice", "dur_s": seconds, "f0": f0, "vowel": "a", "rms": rms]
    }

    private func feed(_ engine: VoiceAnalysisEngine, _ pcm: ArraySlice<Int16>, chunk: Int = 480) {
        var i = pcm.startIndex
        while i < pcm.endIndex {
            let j = min(pcm.endIndex, i + chunk)
            engine.processFrame(VoiceDspVectorGenerator.data(pcm[i..<j]))
            i = j
        }
    }

    /// Every field of a result in one array, to compare two results for exact equality.
    private func fields(_ r: VoiceAnalysisResult) -> [Double] {
        func flag(_ b: Bool) -> Double { b ? 1 : 0 }
        return [
            Double(r.pitch.f0Hz), flag(r.pitch.voiced), Double(r.pitch.rms), flag(r.pitch.f0Valid),
            Double(r.pitch.periodicity),
            Double(r.stress.score), Double(r.stress.jitter), Double(r.stress.shimmer), flag(r.stress.valid),
            Double(r.voiceHealth.hnr), Double(r.voiceHealth.breathiness), flag(r.voiceHealth.hnrValid),
            Double(r.speechRate.syllablesPerSec), Double(r.speechRate.pauseRatio),
            flag(r.speechRate.isSpeaking), flag(r.speechRate.valid),
            Double(r.formants.f1), Double(r.formants.f2), flag(r.formants.f1Found), flag(r.formants.f2Found),
            Double(r.confidence),
        ]
    }

    // MARK: - A short gap in the middle of a step

    /// The loud voice that every scenario starts with: 4 s, 40 steps, level about -26 dBFS.
    private lazy var loudVoice: [Int16] = signal([vowel(4.0, f0: 120.0, rms: 0.05)])
    /// A loud burst that a short gap cuts: it never completes a step.
    private lazy var burst: [Int16] = signal([["type": "noise", "dur_s": 0.2, "seed": 7, "rms": 0.3]])

    /// The engine fed [loud voice, burst cut by a gap, `after`] against the engine fed [loud voice, gap,
    /// `after`]. The burst never completed a step, so nothing of it may survive the gap: from the gap on, the two
    /// must give EXACTLY the same results (raw and display, every field). Returns both runs.
    private func runWithAndWithoutTheCutBurst(burstSamples: Int, after: [Int16])
        -> (cut: Output, clean: Output)? {
        let x = makeEngine()
        feed(x.engine, loudVoice[...])
        feed(x.engine, burst[0..<burstSamples])
        x.engine.markDiscontinuity(missingSamples: 24_000)
        feed(x.engine, after[...])

        let y = makeEngine()
        feed(y.engine, loudVoice[...])
        y.engine.markDiscontinuity(missingSamples: 24_000)
        feed(y.engine, after[...])

        let label = "burst of \(burstSamples) samples"
        let steps = 40 + after.count / 4_800
        XCTAssertEqual(x.output.raw.count, steps, label)
        XCTAssertEqual(y.output.raw.count, steps, label)
        XCTAssertEqual(x.output.display.count, steps, label)
        XCTAssertEqual(y.output.display.count, steps, label)
        guard x.output.raw.count == steps, y.output.raw.count == steps, x.output.display.count == steps,
              y.output.display.count == steps else { return nil }
        for i in 40..<steps {
            XCTAssertEqual(fields(x.output.raw[i]), fields(y.output.raw[i]), "\(label), raw step \(i + 1)")
            XCTAssertEqual(fields(x.output.display[i]), fields(y.output.display[i]),
                           "\(label), display step \(i + 1)")
        }
        return (x.output, y.output)
    }

    /// 300: only a partial 10 ms frame. 2230: 4 complete frames and a partial one. 4799: 9 complete frames and
    /// a partial one, one sample short of the step.
    private let cutBursts = [300, 2_230, 4_799]

    /// A loud burst cut by a short gap, then a quiet voice. Whatever the engine kept of the burst, a partial 10
    /// ms frame or complete frames of the unfinished step, would enter the envelope of the speech rate: the
    /// loud frame sets the level of the last 6 s and the quiet voice that follows would look inactive.
    func testAShortGapInTheMiddleOfAStepLeavesNoTraceOfTheUnfinishedStep() {
        let quiet = signal([vowel(3.0, f0: 120.0, rms: 0.01)])
        XCTAssertEqual(loudVoice.count, 192_000, "40 steps")
        XCTAssertEqual(quiet.count, 144_000, "30 steps")
        for burstSamples in cutBursts {
            let label = "burst of \(burstSamples) samples"
            guard let run = runWithAndWithoutTheCutBurst(burstSamples: burstSamples, after: quiet) else { continue }
            // And the results are the right ones, not just equal: the quiet voice is 14 dB under the loud one
            // and within the 25 dB of activity, so it is speaking at every step, and the histories of the
            // first 4 s are all still there at the first step after the gap.
            let first = run.cut.raw[40]
            XCTAssertTrue(first.pitch.voiced, label)
            XCTAssertTrue(first.voiceHealth.hnrValid, "the HNR history is kept over a short gap, \(label)")
            XCTAssertTrue(first.stress.valid, "the stress history is kept over a short gap, \(label)")
            XCTAssertTrue(first.speechRate.valid, "the 6 s envelope is kept over a short gap, \(label)")
            for i in 40..<70 {
                XCTAssertTrue(run.cut.raw[i].speechRate.isSpeaking,
                              "step \(i + 1): the quiet voice is within 25 dB of the loud one, \(label)")
            }
        }
    }

    /// The 10 ms framing restarts with the gap. After it come 4700 samples of silence, a click of 90 samples
    /// (inside the 10th frame of the first step, samples 4320 to 4799) and silence again: only the first step
    /// hears the click. With a partial frame of the cut burst kept across the gap the frames would be shifted
    /// and the click would fall into the 11th frame, which belongs to the second step.
    func testAShortGapInTheMiddleOfAStepRestartsTheTenMillisecondFraming() {
        let click: [String: Any] = ["type": "noise", "dur_s": 90.0 / 48_000.0, "seed": 3, "rms": 0.1]
        let before: [String: Any] = ["type": "silence", "dur_s": 4_700.0 / 48_000.0]
        let rest: [String: Any] = ["type": "silence", "dur_s": Double(48_000 - 4_790) / 48_000.0]
        // Digital silence is -100 dB; the click is about -27 dB, within 25 dB of the loud voice before the gap
        // (about -26 dB), so only the frames that hold the click are active.
        let after = signal([before, click, rest])
        XCTAssertEqual(after.count, 48_000)
        for burstSamples in cutBursts {
            let label = "burst of \(burstSamples) samples"
            guard let run = runWithAndWithoutTheCutBurst(burstSamples: burstSamples, after: after) else { continue }
            XCTAssertTrue(run.cut.raw[40].speechRate.isSpeaking, "the click is in the first step, \(label)")
            for i in 41..<50 {
                XCTAssertFalse(run.cut.raw[i].speechRate.isSpeaking, "step \(i + 1) is silence, \(label)")
            }
        }
    }

    // MARK: - The long-gap threshold

    /// A voice at 120 Hz for 4 s, a gap of `missing` samples, then a voice at 200 Hz for 1 s: every result.
    private func runAcrossAGap(of missing: Int) -> Output? {
        let before = signal([vowel(4.0, f0: 120.0, rms: 0.05)])
        let run = makeEngine()
        feed(run.engine, before[...])
        XCTAssertEqual(run.output.raw.count, 40)
        run.engine.markDiscontinuity(missingSamples: missing)
        feed(run.engine, secondVoice[...])
        guard run.output.raw.count == 50, run.output.display.count == 50 else {
            XCTFail("expected 50 results, got \(run.output.raw.count)")
            return nil
        }
        return run.output
    }

    private lazy var secondVoice: [Int16] = signal([vowel(1.0, f0: 200.0, rms: 0.05)])

    /// 95,999 samples (one short of 2 s) is a short gap: every history survives. 96,000 is a long one:
    /// everything is cleared, as by `reset()`, so the engine then gives exactly what a new engine gives on the
    /// same audio. The numbers are the literals of the specification, not the engine's own constant, so that
    /// changing the constant fails here.
    func testTheLongGapThresholdIsExactly96000Samples() {
        let fresh = makeEngine()
        feed(fresh.engine, secondVoice[...])
        XCTAssertEqual(fresh.output.raw.count, 10)

        guard let short = runAcrossAGap(of: 95_999) else { return }
        XCTAssertTrue(short.raw[40].pitch.voiced)
        XCTAssertTrue(short.raw[40].voiceHealth.hnrValid, "95,999 samples keep the HNR history")
        XCTAssertTrue(short.raw[40].stress.valid, "95,999 samples keep the stress history")
        XCTAssertTrue(short.raw[40].speechRate.valid, "95,999 samples keep the speech-rate envelope")
        XCTAssertGreaterThan(abs(short.display[40].pitch.f0Hz - short.raw[40].pitch.f0Hz), 10,
                             "95,999 samples keep the display history: the value shown still has the old voice in it")
        XCTAssertNotEqual(fields(short.raw[40]), fields(fresh.output.raw[0]), "not a new engine")

        guard let long = runAcrossAGap(of: 96_000), fresh.output.raw.count == 10 else { return }
        XCTAssertTrue(long.raw[40].pitch.voiced)
        XCTAssertFalse(long.raw[40].voiceHealth.hnrValid, "96,000 samples clear the HNR history")
        XCTAssertFalse(long.raw[40].stress.valid, "96,000 samples clear the stress history")
        XCTAssertFalse(long.raw[40].speechRate.valid, "96,000 samples clear the speech-rate envelope")
        XCTAssertEqual(long.display[40].pitch.f0Hz, long.raw[40].pitch.f0Hz, "96,000 samples clear the display history")
        // Every field of every step after it, raw and display, is that of a new engine: the formant histories
        // and the display window are cleared too, not only the ones checked above.
        for i in 0..<10 {
            XCTAssertEqual(fields(long.raw[40 + i]), fields(fresh.output.raw[i]), "raw step \(i + 1) after the gap")
            XCTAssertEqual(fields(long.display[40 + i]), fields(fresh.output.display[i]),
                           "display step \(i + 1) after the gap")
        }
    }

    // MARK: - Stress inputs

    /// The model of section 8, written independently of the engine: the f0 and the mean-removed rms of the
    /// voiced steps only (taken from the engine's own raw results), the last 25 of them.
    private struct StressModel {
        var f0: [Double] = []
        var rms: [Double] = []

        mutating func clear() { f0.removeAll(); rms.removeAll() }

        mutating func add(_ r: VoiceAnalysisResult) {
            f0.append(Double(r.pitch.f0Hz))
            rms.append(Double(r.pitch.rms))
            if f0.count > 25 { f0.removeFirst() }
            if rms.count > 25 { rms.removeFirst() }
        }

        /// Mean absolute difference of successive values over their mean.
        static func relativeDifference(_ v: [Double]) -> Double {
            var sum = 0.0
            for i in 1..<v.count { sum += abs(v[i] - v[i - 1]) }
            let mean = v.reduce(0, +) / Double(v.count)
            return mean > 1e-6 ? sum / Double(v.count - 1) / mean : 0
        }
    }

    private enum Event {
        case shortGap(Int)
        case longGap(Int)
        case reset
    }

    /// Voiced and unvoiced steps with a moving f0 and a moving level, with a short gap, a long gap and two
    /// resets in the middle of steps. Every result is checked against the model.
    func testTheStressInputsAreTheVoicedStepsOnlyTheLast25ClearedByALongGapAndByReset() {
        let f0Pattern: [Double] = [112, 131, 119, 146, 108, 138, 125, 151, 115, 133, 122, 142]
        func steps(shift: Int) -> [String: Any] {
            var list: [[Double]] = []
            for k in 0..<f0Pattern.count { list.append([0.15, f0Pattern[(k + shift) % f0Pattern.count]]) }
            return ["steps": list]
        }
        let levels: [Double] = [0.05, 0.09, 0.06, 0.12, 0.04, 0.08]
        var segments: [[String: Any]] = []
        for k in 0..<8 {
            segments.append(vowel(1.8, f0: steps(shift: k), rms: levels[k % levels.count]))
            segments.append(["type": "silence", "dur_s": 0.3 + 0.1 * Double(k % 3)])
        }
        let pcm = signal(segments)
        XCTAssertGreaterThan(pcm.count, 700_000)

        // (sample index, event): none of them on a step boundary.
        let events: [(at: Int, event: Event)] = [
            (130_000 + 777, .shortGap(24_000)),
            (260_000 + 1_234, .longGap(96_000)),
            (390_000 + 321, .reset),
            (480_000 + 2_000, .shortGap(0)),
            (560_000 + 55, .reset),
            (640_000 + 4_000, .longGap(1_000_000)),
        ]

        let engine = VoiceAnalysisEngine()
        var model = StressModel()
        var voiced = 0
        var voicedSinceClear = 0
        var mismatches: [String] = []
        var checkedAfterClear = 0
        var stepIndex = 0
        engine.onResult = { r in
            stepIndex += 1
            if r.pitch.voiced {
                model.add(r)
                voiced += 1
                voicedSinceClear += 1
            }
            let count = model.f0.count
            let expectValid = r.pitch.voiced && count >= 3
            if r.stress.valid != expectValid {
                mismatches.append("step \(stepIndex): valid \(r.stress.valid), expected \(expectValid) "
                                  + "(\(count) voiced values in the history)")
                return
            }
            if expectValid {
                if voicedSinceClear <= 6 { checkedAfterClear += 1 }
                let jitter = StressModel.relativeDifference(model.f0)
                let shimmer = StressModel.relativeDifference(model.rms)
                if abs(Double(r.stress.jitter) - jitter) > 1e-5 + 1e-4 * jitter {
                    mismatches.append("step \(stepIndex): jitter \(r.stress.jitter), expected \(jitter)")
                }
                if abs(Double(r.stress.shimmer) - shimmer) > 1e-5 + 1e-4 * shimmer {
                    mismatches.append("step \(stepIndex): shimmer \(r.stress.shimmer), expected \(shimmer)")
                }
            } else {
                if r.stress.jitter != 0 || r.stress.shimmer != 0 {
                    mismatches.append("step \(stepIndex): jitter and shimmer must be 0 while not valid")
                }
            }
        }

        var position = 0
        for item in events {
            feed(engine, pcm[position..<item.at])
            position = item.at
            switch item.event {
            case .shortGap(let missing):
                engine.markDiscontinuity(missingSamples: missing)
            case .longGap(let missing):
                model.clear()
                voicedSinceClear = 0
                engine.markDiscontinuity(missingSamples: missing)
            case .reset:
                model.clear()
                voicedSinceClear = 0
                engine.reset()
            }
        }
        feed(engine, pcm[position...])

        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) mismatches, first ones:\n"
                      + mismatches.prefix(12).joined(separator: "\n"))
        XCTAssertGreaterThan(voiced, 120, "enough voiced steps to fill the 25-step history more than once")
        // The model must have been exercised right after every clearing event: at least a few readings in the
        // first voiced steps after them (and, by the `valid` check above, none before the third).
        XCTAssertGreaterThan(checkedAfterClear, 8)
    }

    /// Unvoiced steps add nothing to the history and do not shorten it: a long silence between two stretches
    /// of voice leaves the stress of the second stretch continuing the first.
    func testUnvoicedStepsLeaveTheStressHistoryAlone() {
        let f0: [String: Any] = ["steps": [[0.1, 110.0], [0.1, 140.0], [0.1, 120.0], [0.1, 150.0]]]
        let pcm = signal([vowel(1.0, f0: f0, rms: 0.08),
                          ["type": "silence", "dur_s": 1.5],
                          vowel(1.0, f0: f0, rms: 0.08)])
        let run = makeEngine()
        feed(run.engine, pcm[...])
        var model = StressModel()
        var unvoiced = 0
        for r in run.output.raw {
            if r.pitch.voiced {
                model.add(r)
                if model.f0.count >= 3 {
                    XCTAssertTrue(r.stress.valid)
                    let want = StressModel.relativeDifference(model.f0)
                    XCTAssertEqual(Double(r.stress.jitter), want, accuracy: 1e-5 + 1e-4 * want)
                }
            } else {
                unvoiced += 1
                XCTAssertFalse(r.stress.valid)
            }
        }
        XCTAssertGreaterThan(unvoiced, 10, "the silence produced unvoiced steps")
        XCTAssertGreaterThan(model.f0.count, 10)
    }
}

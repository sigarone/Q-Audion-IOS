import XCTest
@testable import QAudionEngine

final class VoiceAnalysisEngineTests: XCTestCase {
    private var engine: VoiceAnalysisEngine!

    override func setUp() {
        super.setUp()
        engine = VoiceAnalysisEngine()
    }

    private func sine(_ samples: Int) -> Data {
        TestAudioHelpers.makeSinePCM(frequency: 200, sampleCount: samples)
    }

    // MARK: - Cadence: one analysis per 100 ms of audio, at the exact sample

    func testCallbackFiresAfter100msOfAudio() {
        var receivedResult: VoiceAnalysisResult?
        engine.onResult = { receivedResult = $0 }
        for _ in 0..<5 { engine.processFrame(sine(960)) }          // 5 x 20 ms
        XCTAssertNotNil(receivedResult, "Should receive a result after 100ms of 20ms frames")
    }

    func testCallbackNotFiredBeforeTheFirst100ms() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }
        for _ in 0..<4 { engine.processFrame(sine(960)) }          // 80 ms
        XCTAssertEqual(callbackCount, 0, "Callback should not fire before 100 ms of audio")
        engine.processFrame(sine(959))                              // 99.98 ms
        XCTAssertEqual(callbackCount, 0, "one sample short of 100 ms")
        engine.processFrame(sine(1))
        XCTAssertEqual(callbackCount, 1, "exactly 4800 samples")
    }

    func testDisabledEngineDoesNotCallback() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }
        engine.onDisplay = { _ in callbackCount += 1 }
        engine.setEnabled(false)
        for _ in 0..<20 { engine.processFrame(sine(960)) }
        XCTAssertEqual(callbackCount, 0, "Disabled engine should never fire callback")
    }

    func testIsEnabledReflectsState() {
        XCTAssertTrue(engine.isEnabled, "Engine should be enabled by default")
        engine.setEnabled(false)
        XCTAssertFalse(engine.isEnabled)
        engine.setEnabled(true)
        XCTAssertTrue(engine.isEnabled)
    }

    func testTenCallsOf20msGiveTwoAnalyses() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }
        for _ in 0..<10 { engine.processFrame(sine(960)) }          // 200 ms
        XCTAssertEqual(callbackCount, 2, "at the 100 ms and the 200 ms marks")
    }

    func test60msChunksFireAtTheExact100msMarks() {
        // 60 ms buffers land on 60, 120, 180, 240 ms: the 100 ms and 200 ms analyses fall INSIDE the
        // second and the fourth buffer, and run at their exact sample (not at the end of the buffer).
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }
        engine.processFrame(sine(2_880))
        XCTAssertEqual(callbackCount, 0, "60 ms is short of the 100 ms mark")
        engine.processFrame(sine(2_880))
        XCTAssertEqual(callbackCount, 1, "the 100 ms mark is inside the second buffer")
        engine.processFrame(sine(2_880))
        XCTAssertEqual(callbackCount, 1)
        engine.processFrame(sine(2_880))
        XCTAssertEqual(callbackCount, 2, "the 200 ms mark is inside the fourth buffer")
    }

    func test10msChunksFireOnceper100ms() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }
        for _ in 0..<9 { engine.processFrame(sine(480)) }
        XCTAssertEqual(callbackCount, 0)
        engine.processFrame(sine(480))
        XCTAssertEqual(callbackCount, 1)
    }

    func testAChunkOfSeveralStepsDeliversEveryResultInOrder() {
        var results: [VoiceAnalysisResult] = []
        var displays: [VoiceAnalysisResult] = []
        engine.onResult = { results.append($0) }
        engine.onDisplay = { displays.append($0) }
        // 520 ms in one buffer: the analyses at 100, 200, 300, 400 and 500 ms.
        engine.processFrame(sine(24_960))
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(displays.count, 5)
        XCTAssertTrue(results.last?.pitch.voiced ?? false)
    }

    func testSingleSampleChunksWork() {
        var count = 0
        engine.onResult = { _ in count += 1 }
        let one = sine(1)
        for _ in 0..<4_800 { engine.processFrame(one) }
        XCTAssertEqual(count, 1)
    }

    func testAnOddTrailingByteIsIgnored() {
        var results: [VoiceAnalysisResult] = []
        engine.onResult = { results.append($0) }
        var pcm = sine(4_800)
        pcm.append(0x7F)
        engine.processFrame(pcm)
        XCTAssertEqual(results.count, 1)
        engine.processFrame(Data([0x01]))
        XCTAssertEqual(results.count, 1)
    }

    func testEmptyBufferIsIgnored() {
        var count = 0
        engine.onResult = { _ in count += 1 }
        engine.processFrame(Data())
        XCTAssertEqual(count, 0)
    }

    // MARK: - Content of a result

    func testResultContainsAllFields() {
        var receivedResult: VoiceAnalysisResult?
        engine.onResult = { receivedResult = $0 }
        for _ in 0..<5 { engine.processFrame(sine(960)) }
        guard let result = receivedResult else { return XCTFail("Expected a result") }
        XCTAssertGreaterThan(result.pitch.rms, 0, "RMS should be positive")
        XCTAssertGreaterThanOrEqual(result.confidence, 0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
        XCTAssertTrue(result.pitch.voiced)
        XCTAssertEqual(result.pitch.voiced, result.pitch.f0Valid, "one flag")
        XCTAssertGreaterThan(result.pitch.periodicity, 0.9)
    }

    func testNoCallbackWhenNoneSet() {
        for _ in 0..<5 { engine.processFrame(sine(960)) }
        // Should not crash
    }

    func testTheResultOfALiveVoiceIsAMeasurement() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.0)
        guard let last = SyntheticVoice.run(x, chunkMs: 10).results.last else { return XCTFail("no result") }
        XCTAssertTrue(last.pitch.f0Valid)
        XCTAssertEqual(Double(last.pitch.f0Hz), 120, accuracy: 3.6)
        XCTAssertTrue(last.formants.f1Found)
        XCTAssertTrue(last.formants.f2Found)
        XCTAssertTrue(last.voiceHealth.hnrValid)
        XCTAssertFalse(last.speechRate.valid, "one second of a steady vowel is not two seconds of speaking time")
        XCTAssertTrue(last.stress.valid, "ten voiced steps are enough history for jitter and shimmer")
    }

    func testJitterAndShimmerAreNotAReadingUntilThreeVoicedSteps() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.6)
        let results = SyntheticVoice.run(x, chunkMs: 10).results
        XCTAssertGreaterThanOrEqual(results.count, 5)
        for r in results.prefix(2) {
            XCTAssertFalse(r.stress.valid)
            XCTAssertEqual(r.stress.jitter, 0)
            XCTAssertEqual(r.stress.shimmer, 0)
        }
        XCTAssertTrue(results[2].stress.valid)
    }

    /// For every step the raw result comes first and the value to show second (a consumer that pairs them, or
    /// that reads the raw counters before it draws, relies on it).
    func testTheRawResultIsDeliveredBeforeTheDisplayValueOfTheSameStep() {
        var order: [String] = []
        engine.onResult = { _ in order.append("result") }
        engine.onDisplay = { _ in order.append("display") }
        engine.processFrame(sine(24_000))                           // 5 steps in one buffer
        XCTAssertEqual(order, ["result", "display", "result", "display", "result", "display",
                               "result", "display", "result", "display"])
    }

    /// The callbacks are read and replaced under the engine lock and no callback runs with the lock held: a callback
    /// can replace both of them (and read them back) without deadlock, and each step calls the callbacks that were in
    /// place when the step was taken.
    func testACallbackCanReplaceTheCallbacksWhileItRuns() {
        var order: [String] = []
        let engine: VoiceAnalysisEngine = self.engine
        engine.onDisplay = { _ in order.append("display-1") }
        engine.onResult = { _ in
            order.append("result-1")
            engine.onResult = { _ in order.append("result-2") }
            engine.onDisplay = { _ in order.append("display-2") }
            XCTAssertNotNil(engine.onResult)
            XCTAssertNotNil(engine.onDisplay)
        }
        engine.processFrame(sine(9_600))                            // two steps
        XCTAssertEqual(order, ["result-1", "display-1", "result-2", "display-2"])
        engine.onResult = nil
        engine.onDisplay = nil
        XCTAssertNil(engine.onResult)
        engine.processFrame(sine(4_800))                            // a step with no callback is no error
        XCTAssertEqual(order.count, 4)
    }

    // MARK: - Display window

    func testTheDisplayValueIsTheMeanOfTheLastTenResults() {
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 2.0)
        var raw: [VoiceAnalysisResult] = []
        var shown: [VoiceAnalysisResult] = []
        engine.onResult = { raw.append($0) }
        engine.onDisplay = { shown.append($0) }
        var offset = 0
        while offset + 480 <= x.count {
            engine.processFrame(SyntheticVoice.pcm(x, from: offset, count: 480))
            offset += 480
        }
        XCTAssertEqual(raw.count, shown.count)
        XCTAssertGreaterThan(raw.count, 15)
        for i in [0, 4, 9, 14, raw.count - 1] {
            let window = Array(raw[max(0, i - 9)...i])
            let expected = VoiceAnalysisSmoothing.average(of: window)
            XCTAssertEqual(shown[i].pitch.f0Hz, expected?.pitch.f0Hz)
            XCTAssertEqual(shown[i].voiceHealth.hnr, expected?.voiceHealth.hnr)
            XCTAssertEqual(shown[i].pitch.rms, expected?.pitch.rms)
        }
    }

    // MARK: - Voice word

    /// Digital silence of `steps` analysis steps (100 ms each) at 48 kHz, 16-bit.
    private func silence(_ steps: Int) -> Data {
        Data(count: steps * 4_800 * 2)
    }

    /// The word of the tone row follows the results, not the voiced flag of the display value: after 6 unvoiced
    /// results the last 10 hold only 4 voiced ones, so the display flag is already false while the word still
    /// says voice. Silence comes with the 20th unvoiced result in a row, and a voiced result ends it at once
    /// (docs/voice-analysis-spec.md, section 12.6).
    func testTheVoiceWordHoldsOverAPauseAndTurnsToSilenceAfterTwoSeconds() {
        var shown: [VoiceAnalysisResult] = []
        engine.onDisplay = { shown.append($0) }
        engine.processFrame(sine(24_000))                           // 5 voiced steps
        XCTAssertEqual(shown.map { $0.voiceWord }, [VoiceWord](repeating: .voice, count: 5))

        engine.processFrame(silence(6))
        XCTAssertEqual(shown.count, 11)
        XCTAssertFalse(shown[10].pitch.voiced, "the majority flag of the display value is already false")
        XCTAssertEqual(shown[10].voiceWord, .voice, "the word holds over the pause")

        engine.processFrame(silence(13))                            // 19 unvoiced results in a row
        XCTAssertEqual(shown.count, 24)
        XCTAssertEqual(shown.last?.voiceWord, .voice, "1.9 s without voice is not silence")

        engine.processFrame(silence(1))                             // the 20th
        XCTAssertEqual(shown.last?.voiceWord, .silence)
        engine.processFrame(silence(1))
        XCTAssertEqual(shown.last?.voiceWord, .silence)

        engine.processFrame(sine(4_800))
        XCTAssertEqual(shown.last?.voiceWord, .voice, "a voiced result shows the voice word at once")
    }

    /// Before any voice there is no word for 19 results; the 20th unvoiced one turns it to silence.
    func testTheVoiceWordIsAbsentUntilVoiceOrTwoSeconds() {
        var words: [VoiceWord] = []
        engine.onDisplay = { words.append($0.voiceWord) }
        engine.processFrame(silence(19))
        XCTAssertEqual(words, [VoiceWord](repeating: .noWord, count: 19))
        engine.processFrame(silence(1))
        XCTAssertEqual(words.last, .silence)
    }

    /// A reset and a gap of 2 s or more clear what was heard; a shorter gap keeps it.
    func testAResetAndALongGapClearTheVoiceWordAndAShortGapKeepsIt() {
        var words: [VoiceWord] = []
        engine.onDisplay = { words.append($0.voiceWord) }
        engine.processFrame(sine(4_800))
        XCTAssertEqual(words.last, .voice)

        engine.reset()
        engine.processFrame(silence(1))
        XCTAssertEqual(words.last, .noWord, "nothing has been heard since the reset")

        engine.processFrame(sine(4_800))
        engine.markDiscontinuity(missingSamples: 95_999)
        engine.processFrame(silence(1))
        XCTAssertEqual(words.last, .voice, "a gap shorter than 2 s keeps what was heard")

        engine.markDiscontinuity(missingSamples: 96_000)
        engine.processFrame(silence(1))
        XCTAssertEqual(words.last, .noWord, "a gap of 2 s or more clears it")
    }

    /// The word belongs to the value to show: a raw result does not carry one.
    func testARawResultCarriesNoVoiceWord() {
        var raw: [VoiceAnalysisResult] = []
        engine.onResult = { raw.append($0) }
        engine.processFrame(sine(24_000))
        XCTAssertEqual(raw.count, 5)
        XCTAssertTrue(raw.allSatisfy { $0.voiceWord == .noWord })
    }

    // MARK: - Reset, gaps and re-enabling

    func testResetDropsTheAudioWindowAndRestartsTheCadence() {
        var results: [VoiceAnalysisResult] = []
        engine.onResult = { results.append($0) }
        engine.processFrame(sine(4_800))
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results.last?.pitch.voiced ?? false, "voiced before the reset")

        engine.reset()
        results.removeAll()
        engine.processFrame(sine(4_799))
        XCTAssertEqual(results.count, 0, "100 ms after the reset, not sooner")
        engine.processFrame(sine(1))
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].voiceHealth.hnrValid, "nothing of the previous call survives the reset")
    }

    func testAShortGapRestartsTheGridButKeepsTheHistories() {
        var results: [VoiceAnalysisResult] = []
        engine.onResult = { results.append($0) }
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.0)
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 4_800 * 3 + 2_000))   // 3 steps + 2000 samples
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.last?.voiceHealth.hnrValid ?? false)

        engine.markDiscontinuity(missingSamples: 24_000)          // 500 ms missing
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 4_799))
        XCTAssertEqual(results.count, 3, "the next analysis comes 100 ms after the audio resumes")
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 1))
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results[3].voiceHealth.hnrValid, "the HNR history survived a gap shorter than 2 s")
    }

    func testAGapOfTwoSecondsOrMoreClearsEverything() {
        var results: [VoiceAnalysisResult] = []
        engine.onResult = { results.append($0) }
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.0)
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 4_800 * 3))
        XCTAssertTrue(results.last?.voiceHealth.hnrValid ?? false)

        // The literals of the specification (docs/voice-analysis-spec.md, section 2), not the engine's own
        // constant: changing the constant must fail here. (VoiceAnalysisGapTests checks every history on both
        // sides of the line.)
        engine.markDiscontinuity(missingSamples: 95_999)
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 4_800))
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results[3].voiceHealth.hnrValid, "1.99998 s is still a short gap")

        engine.markDiscontinuity(missingSamples: 96_000)
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 4_800))
        XCTAssertEqual(results.count, 5)
        XCTAssertFalse(results[4].voiceHealth.hnrValid, "2 s or more: HNR history cleared")
    }

    func testADiscontinuityOfUnknownLengthCountsAsShort() {
        var results: [VoiceAnalysisResult] = []
        engine.onResult = { results.append($0) }
        let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.0)
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 4_800 * 3))
        engine.markDiscontinuity(missingSamples: 0)
        engine.processFrame(SyntheticVoice.pcm(x, from: 0, count: 4_800))
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results[3].voiceHealth.hnrValid)
    }

    func testADiscontinuityBeforeAnyAudioChangesNothing() {
        var results: [VoiceAnalysisResult] = []
        engine.onResult = { results.append($0) }
        engine.markDiscontinuity(missingSamples: 0)
        engine.markDiscontinuity(missingSamples: 1_000_000)
        engine.processFrame(sine(4_800))
        XCTAssertEqual(results.count, 1)
    }

    func testReEnablingTheEngineResumesCallbacksOnAFreshGrid() {
        var callbackCount = 0
        engine.onResult = { _ in callbackCount += 1 }
        engine.processFrame(sine(3_000))
        engine.setEnabled(false)
        for _ in 0..<5 { engine.processFrame(sine(960)) }
        XCTAssertEqual(callbackCount, 0)

        engine.setEnabled(true)
        engine.processFrame(sine(4_799))
        XCTAssertEqual(callbackCount, 0, "audio that was not consumed while disabled does not count")
        engine.processFrame(sine(1))
        XCTAssertEqual(callbackCount, 1, "Re-enabled engine should resume callbacks")
    }
}

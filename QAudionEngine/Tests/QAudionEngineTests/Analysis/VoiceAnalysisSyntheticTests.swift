import XCTest
@testable import QAudionEngine

/// Ground-truth tests of the voice analysis. A synthetic vowel with a known f0,
/// known formants, a known SNR or a known syllable rate goes through the REAL
/// engine entry point (`processFrame`) in 10, 20 and 60 ms chunks, and the
/// readings are compared with what was put in. These are the tests that fail if
/// the method is wrong: the old tracker put F1 at 2-5 kHz, the old HNR followed
/// the loudness, and the old speech rate grew without bound.
final class VoiceAnalysisSyntheticTests: XCTestCase {

    private let chunkings = [10, 20, 60]

    private func percent(_ value: Double, _ truth: Double) -> Double {
        100.0 * (value - truth) / truth
    }

    // MARK: - Pitch

    func testPitchIsAccurateOnLowAndHighVoices() {
        for (name, vowel) in [("a", SyntheticVoice.a), ("i", SyntheticVoice.i), ("u", SyntheticVoice.u)] {
            for f0 in [100.0, 220.0] {
                let x = SyntheticVoice.vowel(f0: f0, vowel, seconds: 1.2)
                for ms in chunkings {
                    let results = SyntheticVoice.run(x, chunkMs: ms).results
                    XCTAssertGreaterThan(results.count, 4, "/\(name)/ \(f0) Hz, \(ms) ms chunks")
                    for r in results.dropFirst(3) {
                        XCTAssertTrue(r.pitch.voiced, "/\(name)/ \(f0) Hz, \(ms) ms chunks")
                        XCTAssertTrue(r.pitch.f0Valid)
                        XCTAssertEqual(percent(Double(r.pitch.f0Hz), f0), 0, accuracy: 3.0,
                                       "/\(name)/ \(f0) Hz, \(ms) ms chunks: no octave error, within 3 %")
                    }
                }
            }
        }
    }

    // MARK: - Formants

    func testFormantsMatchTheVowelAtLowAndHighPitch() {
        // (vowel, truth, F1 resolvable at f0 = 220?, F2 resolvable at f0 = 220?)
        // F1 must lie at least 2.5 x f0 = 550 Hz up to be placed, so only /a/ has one. /a/ has no F2 at
        // 220 Hz: its first resonance above F1 is a 380 Hz-wide pole on the 4th harmonic, which the method
        // cannot measure and does not skip (the real F2 behind it is not promoted in its place).
        let cases: [(String, SyntheticVoice.Vowel, Bool, Bool)] = [
            ("a", SyntheticVoice.a, true, false), ("i", SyntheticVoice.i, false, true),
            ("u", SyntheticVoice.u, false, true),
        ]
        for (name, vowel, f1ResolvableAt220, f2ResolvableAt220) in cases {
            for f0 in [100.0, 220.0] {
                let x = SyntheticVoice.vowel(f0: f0, vowel, seconds: 1.2)
                for ms in chunkings {
                    let label = "/\(name)/ f0=\(Int(f0)), \(ms) ms chunks"
                    let results = SyntheticVoice.run(x, chunkMs: ms).results
                    XCTAssertGreaterThan(results.count, 4, label)
                    for r in results.dropFirst(3) {
                        let f = r.formants
                        if f0 == 100.0 || f2ResolvableAt220 {
                            XCTAssertTrue(f.f2Found, "F2 found, \(label)")
                            XCTAssertEqual(percent(Double(f.f2), vowel.f2), 0, accuracy: 12.0, "F2, \(label)")
                        } else {
                            XCTAssertFalse(f.f2Found, "F2 withheld, \(label)")
                            XCTAssertEqual(f.f2, 0, "a formant that is not found is exactly 0, \(label)")
                        }
                        if f0 == 100.0 || f1ResolvableAt220 {
                            XCTAssertTrue(f.f1Found, "F1 found, \(label)")
                            XCTAssertEqual(percent(Double(f.f1), vowel.f1), 0, accuracy: 12.0, "F1, \(label)")
                        } else {
                            // A 270-300 Hz resonance between the first two harmonics of a 220 Hz
                            // voice cannot be placed (the fit lands on a harmonic, +20 % off):
                            // the engine must say "not found", not report the wrong number.
                            XCTAssertFalse(f.f1Found, "F1 withheld, \(label)")
                            XCTAssertEqual(f.f1, 0, "a formant that is not found is exactly 0, \(label)")
                        }
                    }
                }
            }
        }
    }

    func testFormantsAreNotSeededOrCarriedOver() {
        // A voiced vowel followed by silence: once the voice stops, no formant is
        // reported, not even the last one.
        var x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 0.6)
        x += [Double](repeating: 0, count: 48_000)
        let run = SyntheticVoice.run(x, chunkMs: 10)
        let tail = run.results.suffix(4)
        XCTAssertFalse(tail.isEmpty)
        for r in tail {
            XCTAssertFalse(r.pitch.voiced)
            XCTAssertFalse(r.formants.f1Found)
            XCTAssertFalse(r.formants.f2Found)
            XCTAssertFalse(r.formants.f3Found)
            XCTAssertEqual(r.formants.f1, 0)
            XCTAssertEqual(r.formants.f2, 0)
        }
    }

    // MARK: - HNR

    func testHnrOfACleanVowelIsHigh() {
        for ms in chunkings {
            let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.5)
            let results = SyntheticVoice.run(x, chunkMs: ms).results
            guard let last = results.last else { return XCTFail("no result") }
            XCTAssertTrue(last.voiceHealth.hnrValid, "\(ms) ms chunks")
            XCTAssertGreaterThan(last.voiceHealth.hnr, 20, "clean vowel, \(ms) ms chunks")
        }
    }

    func testHnrIsInvalidUntilThreeVoicedWindows() {
        for ms in chunkings {
            let x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.0)
            let results = SyntheticVoice.run(x, chunkMs: ms).results
            XCTAssertGreaterThan(results.count, 3)
            for r in results.prefix(2) {
                XCTAssertFalse(r.voiceHealth.hnrValid, "\(ms) ms chunks")
                XCTAssertEqual(r.voiceHealth.hnr, 0)
            }
            XCTAssertTrue(results[2].voiceHealth.hnrValid, "third voiced window, \(ms) ms chunks")
        }
    }

    func testHnrDropsWithNoiseAndTracksTheSnr() {
        for ms in chunkings {
            let clean = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.5)
            guard let cleanHnr = SyntheticVoice.run(clean, chunkMs: ms).results.last?.voiceHealth else {
                return XCTFail("no result")
            }
            // 10 dB SNR: at least 6 dB lower than the clean vowel.
            let noisy = SyntheticVoice.addNoise(clean, snrDb: 10)
            guard let noisyHnr = SyntheticVoice.run(noisy, chunkMs: ms).results.last?.voiceHealth else {
                return XCTFail("no result")
            }
            XCTAssertTrue(noisyHnr.hnrValid)
            XCTAssertLessThanOrEqual(noisyHnr.hnr, cleanHnr.hnr - 6, "10 dB SNR, \(ms) ms chunks")
            // Known values: the HNR is measured on the 48 kHz window, so white noise over the whole band at
            // SNR s reads about s.
            for snr in [20.0, 10.0, 0.0] {
                let n = SyntheticVoice.addNoise(clean, snrDb: snr)
                guard let h = SyntheticVoice.run(n, chunkMs: ms).results.last?.voiceHealth else {
                    return XCTFail("no result")
                }
                XCTAssertEqual(Double(h.hnr), snr, accuracy: 1.5, "SNR \(snr) dB, \(ms) ms chunks")
            }
        }
    }

    func testHnrDoesNotFollowTheLoudness() {
        // The same noisy vowel at RMS 0.2 and at RMS 0.02 (x0.5 and x0.05 of a 0.4 reference).
        // The old estimate read 0 / 14 / 21 dB at RMS 0.01 / 0.05 / 0.2.
        for ms in chunkings {
            let loud = SyntheticVoice.addNoise(SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.5, rms: 0.2),
                                               snrDb: 10)
            let quiet = loud.map { $0 * 0.1 }
            guard let hl = SyntheticVoice.run(loud, chunkMs: ms).results.last?.voiceHealth,
                  let hq = SyntheticVoice.run(quiet, chunkMs: ms).results.last?.voiceHealth else {
                return XCTFail("no result")
            }
            XCTAssertTrue(hl.hnrValid)
            XCTAssertTrue(hq.hnrValid)
            XCTAssertEqual(Double(hl.hnr), Double(hq.hnr), accuracy: 1.0, "\(ms) ms chunks")
        }
    }

    // MARK: - Speech rate

    func testSpeechRateReadsTheSyllableRate() {
        let base = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 8, rms: 0.15)
        for rate in [4.0, 6.0] {
            let x = SyntheticVoice.syllabic(base, rate: rate)
            for ms in chunkings {
                let run = SyntheticVoice.run(x, chunkMs: ms)
                let label = "\(rate) syl/s, \(ms) ms chunks"
                // Invalid during the first 2 s of audio.
                for (r, stamp) in zip(run.results, run.stamps) where stamp <= 2 * 48_000 {
                    XCTAssertFalse(r.speechRate.valid, "invalid in the first 2 s, \(label)")
                    XCTAssertEqual(r.speechRate.syllablesPerSec, 0, label)
                }
                // After 6 s of audio it reads the true rate.
                let late = run.results.suffix(run.results.count - run.results.count * 6 / 8)
                XCTAssertFalse(late.isEmpty, label)
                for r in late {
                    XCTAssertTrue(r.speechRate.valid, label)
                    XCTAssertEqual(Double(r.speechRate.syllablesPerSec), rate, accuracy: 0.6, label)
                    XCTAssertGreaterThan(r.speechRate.pauseRatio, 0.1, "the 400 ms pauses show up, \(label)")
                    XCTAssertLessThan(r.speechRate.pauseRatio, 0.4, label)
                }
            }
        }
    }

    func testSpeechRateDoesNotGrowOverALongCall() {
        // The old counter never windowed its count: it grew with the length of the call.
        let base = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 24, rms: 0.15)
        let x = SyntheticVoice.syllabic(base, rate: 4)
        let run = SyntheticVoice.run(x, chunkMs: 20)
        guard let last = run.results.last else { return XCTFail("no result") }
        XCTAssertTrue(last.speechRate.valid)
        XCTAssertEqual(Double(last.speechRate.syllablesPerSec), 4.0, accuracy: 0.6)
        XCTAssertLessThanOrEqual(last.speechRate.syllablesPerSec, 12)
    }

    // MARK: - Nothing to measure

    func testSilenceAndWhiteNoiseMeasureNothing() {
        let silence = [Double](repeating: 0, count: 48_000 * 3)
        let noise = SyntheticVoice.whiteNoise(seconds: 3, rms: 0.1)
        for (label, x) in [("silence", silence), ("white noise", noise)] {
            for ms in chunkings {
                let results = SyntheticVoice.run(x, chunkMs: ms).results
                XCTAssertGreaterThan(results.count, 20, "\(label), \(ms) ms chunks")
                for r in results {
                    let tag = "\(label), \(ms) ms chunks"
                    XCTAssertFalse(r.pitch.voiced, tag)
                    XCTAssertFalse(r.pitch.f0Valid, tag)
                    XCTAssertEqual(r.pitch.f0Hz, 0, tag)
                    XCTAssertFalse(r.formants.f1Found, tag)
                    XCTAssertFalse(r.formants.f2Found, tag)
                    XCTAssertFalse(r.formants.f3Found, tag)
                    XCTAssertFalse(r.voiceHealth.hnrValid, tag)
                    XCTAssertEqual(r.voiceHealth.hnr, 0, tag)
                    XCTAssertFalse(r.speechRate.valid, tag)
                    XCTAssertEqual(r.speechRate.syllablesPerSec, 0, tag)
                    XCTAssertEqual(r.confidence, 0, tag)
                }
            }
        }
    }

    // MARK: - Chunk size and reset

    func testTheChunkSizeDoesNotChangeTheReading() {
        let x = SyntheticVoice.vowel(f0: 180, SyntheticVoice.a, seconds: 1.5)
        var lasts: [VoiceAnalysisResult] = []
        for ms in chunkings {
            guard let last = SyntheticVoice.run(x, chunkMs: ms).results.last else { return XCTFail("no result") }
            lasts.append(last)
        }
        for r in lasts.dropFirst() {
            XCTAssertEqual(Double(r.pitch.f0Hz), Double(lasts[0].pitch.f0Hz), accuracy: 1.5)
            XCTAssertEqual(Double(r.formants.f1), Double(lasts[0].formants.f1), accuracy: 25)
            XCTAssertEqual(Double(r.formants.f2), Double(lasts[0].formants.f2), accuracy: 40)
            XCTAssertEqual(Double(r.voiceHealth.hnr), Double(lasts[0].voiceHealth.hnr), accuracy: 2.0)
        }
    }

    func testResetClearsEveryTrackerBetweenCalls() {
        let engine = VoiceAnalysisEngine()
        let vowel = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 1.2)
        let first = SyntheticVoice.run(vowel, chunkMs: 20, engine: engine)
        XCTAssertTrue(first.results.last?.voiceHealth.hnrValid ?? false, "warmed up before the reset")

        engine.reset()
        // 0.2 s of the next call: the window is refilled from scratch and the HNR
        // history, the formant history and the speech-rate history start over.
        let next = SyntheticVoice.run(Array(vowel.prefix(9_600)), chunkMs: 20, engine: engine)
        XCTAssertEqual(next.results.count, 2, "cadence restarts: 100 ms and 200 ms")
        for r in next.results {
            XCTAssertFalse(r.voiceHealth.hnrValid, "HNR history is gone after a reset")
            XCTAssertFalse(r.speechRate.valid)
        }
        XCTAssertEqual(next.stamps.first, 4_800, "first analysis 100 ms after the reset, not sooner")
    }

    func testInvalidReadingsNeverCarryAValue() {
        // A mix of voice and silence: wherever a flag is false its value is exactly 0.
        var x = SyntheticVoice.vowel(f0: 140, SyntheticVoice.u, seconds: 0.8)
        x += [Double](repeating: 0, count: 24_000)
        x += SyntheticVoice.vowel(f0: 140, SyntheticVoice.i, seconds: 0.5)
        for ms in chunkings {
            for r in SyntheticVoice.run(x, chunkMs: ms).results {
                if !r.pitch.f0Valid { XCTAssertEqual(r.pitch.f0Hz, 0) }
                if !r.voiceHealth.hnrValid { XCTAssertEqual(r.voiceHealth.hnr, 0) }
                if !r.formants.f1Found { XCTAssertEqual(r.formants.f1, 0) }
                if !r.formants.f2Found { XCTAssertEqual(r.formants.f2, 0) }
                if !r.formants.f3Found { XCTAssertEqual(r.formants.f3, 0) }
                if !r.speechRate.valid {
                    XCTAssertEqual(r.speechRate.syllablesPerSec, 0)
                    XCTAssertEqual(r.speechRate.pauseRatio, 0)
                }
                XCTAssertFalse(r.formants.f4Found, "F4 is not measured")
            }
        }
    }
}

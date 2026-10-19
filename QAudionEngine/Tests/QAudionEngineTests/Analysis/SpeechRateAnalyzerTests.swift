import XCTest
@testable import QAudionEngine

final class SpeechRateAnalyzerTests: XCTestCase {
    private var analyzer: SpeechRateAnalyzer!

    override func setUp() {
        super.setUp()
        analyzer = SpeechRateAnalyzer()
    }

    /// Feed `x` the way the engine does: the mean square of every 10 ms frame, ten frames per
    /// analysis step (one step per 100 ms of audio). Returns the last reading.
    @discardableResult
    private func drive(_ x: [Double], voiced: Bool = true, analyzer custom: SpeechRateAnalyzer? = nil)
        -> SpeechRateAnalyzer.Reading? {
        let target = custom ?? analyzer!
        var last: SpeechRateAnalyzer.Reading?
        var energies = [Double](repeating: 0, count: VoiceDsp.framesPerStep)
        var offset = 0
        while offset + VoiceDsp.hopSamples <= x.count {
            for f in 0..<VoiceDsp.framesPerStep {
                var sum = 0.0
                for k in 0..<VoiceDsp.frameSamples {
                    let v = x[offset + f * VoiceDsp.frameSamples + k]
                    sum += v * v
                }
                energies[f] = sum / Double(VoiceDsp.frameSamples)
            }
            last = energies.withUnsafeBufferPointer {
                target.analyze(frameEnergies: $0.baseAddress!, count: VoiceDsp.framesPerStep, voiced: voiced)
            }
            offset += VoiceDsp.hopSamples
        }
        return last
    }

    private func syllables(rate: Double, seconds: Double) -> [Double] {
        SyntheticVoice.syllabic(SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: seconds, rms: 0.15), rate: rate)
    }

    func testSilenceIsNotValidAndNotSpeaking() {
        let r = drive([Double](repeating: 0, count: 48_000 * 4), voiced: false)
        XCTAssertEqual(r?.valid, false)
        XCTAssertEqual(r?.syllablesPerSec, 0)
        XCTAssertEqual(r?.pauseRatio, 0)
        XCTAssertEqual(r?.isSpeaking, false)
    }

    func testRateIsReadFromSyllableNuclei() {
        // 7.5 s: the end of the signal is inside a syllable block, not in its pause.
        let r = drive(syllables(rate: 5, seconds: 7.5))
        XCTAssertEqual(r?.valid, true)
        XCTAssertEqual(r?.syllablesPerSec ?? 0, 5.0, accuracy: 0.6)
        XCTAssertEqual(r?.isSpeaking, true)
    }

    func testNotValidDuringTheFirstTwoSecondsOfSpeech() {
        let r = drive(syllables(rate: 4, seconds: 1.5))
        XCTAssertEqual(r?.valid, false)
        XCTAssertEqual(r?.syllablesPerSec, 0)
        XCTAssertEqual(r?.pauseRatio, 0)
        XCTAssertEqual(r?.isSpeaking, true, "speaking is known even before the rate is")
    }

    func testUnvoicedLoudSoundCountsNoSyllables() {
        // Loud, modulated, but never voiced: not speech, so no nuclei and no validity.
        let x = SyntheticVoice.syllabic(SyntheticVoice.whiteNoise(seconds: 8, rms: 0.1), rate: 4)
        let r = drive(x, voiced: false)
        XCTAssertEqual(r?.valid, false)
        XCTAssertEqual(r?.syllablesPerSec, 0)
    }

    func testCountIsWindowedToSixSeconds() {
        // 8 s of syllables then 12 s of silence: the rate must fall out of the last 6 s
        // (the old counter kept every syllable ever heard).
        drive(syllables(rate: 4, seconds: 8))
        let r = drive([Double](repeating: 0, count: 48_000 * 12), voiced: false)
        XCTAssertEqual(r?.syllablesPerSec, 0)
        XCTAssertEqual(r?.valid, false, "no speaking time left in the last 6 s")
    }

    func testAPauseLongerThan300msIsCountedAndAShorterOneIsNot() {
        // 8 s of a steady voice with one gap of silence. A 250 ms gap is part of speech (pauseRatio 0),
        // a 400 ms one is a pause (pauseRatio near 0.4/6).
        func withGap(_ gapSeconds: Double) -> [Double] {
            var x = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 8, rms: 0.15)
            let start = 48_000 * 4
            for k in start..<(start + Int(gapSeconds * 48_000)) { x[k] = 0 }
            return x
        }
        XCTAssertEqual(drive(withGap(0.25), analyzer: SpeechRateAnalyzer())?.pauseRatio ?? -1, 0, accuracy: 1e-9)
        let long = drive(withGap(0.4), analyzer: SpeechRateAnalyzer())
        XCTAssertEqual(long?.valid, true)
        XCTAssertEqual(long?.pauseRatio ?? 0, 0.4 / 6.0, accuracy: 0.03)
    }

    func testResetClearsState() {
        drive(syllables(rate: 4, seconds: 8))
        analyzer.reset()
        let r = drive(syllables(rate: 4, seconds: 1.0))
        XCTAssertEqual(r?.valid, false, "after reset, two seconds of speaking time must be seen again")
    }
}

import XCTest
@testable import QAudionEngine

/// W-VOICEUISMOOTH (2026-08-29) — the display-side averaging that made the
/// Guardian ribbon readable. See `VoiceAnalysisSmoothing`'s own doc for why
/// this is a presentation filter and never a detection input.
final class VoiceAnalysisSmoothingTests: XCTestCase {

    private func sample(f0: Float, voiced: Bool, conf: Float,
                        speaking: Bool = false) -> VoiceAnalysisResult {
        VoiceAnalysisResult(
            pitch: .init(f0Hz: f0, voiced: voiced, rms: f0 / 1000),
            stress: .init(score: conf, jitter: 0, shimmer: 0),
            voiceHealth: .init(hnr: f0, breathiness: 0),
            speechRate: .init(syllablesPerSec: 0, pauseRatio: 0, isSpeaking: speaking),
            formants: .init(f1: f0, f2: 0, f3: 0, f4: 0),
            confidence: conf)
    }

    /// Empty window returns nil so the caller keeps its previous value on
    /// screen rather than blanking the ribbon between windows.
    func test_emptyWindow_returnsNil() {
        XCTAssertNil(VoiceAnalysisSmoothing.average(of: []))
    }

    /// A single sample must survive untouched — the first value of a call is
    /// published immediately, and averaging one thing is that thing.
    func test_singleSample_isUnchanged() {
        let one = sample(f0: 220, voiced: true, conf: 0.75)
        let out = VoiceAnalysisSmoothing.average(of: [one])
        XCTAssertEqual(out?.pitch.f0Hz, 220)
        XCTAssertEqual(out?.confidence, 0.75)
        XCTAssertEqual(out?.pitch.voiced, true)
    }

    func test_continuousValues_areArithmeticMean() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 100, voiced: true, conf: 0.2),
            sample(f0: 200, voiced: true, conf: 0.4),
            sample(f0: 300, voiced: true, conf: 0.6),
        ])
        XCTAssertEqual(out?.pitch.f0Hz ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(out?.confidence ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(out?.voiceHealth.hnr ?? 0, 200, accuracy: 0.001)
    }

    /// One voiced frame inside a second of silence must NOT light the
    /// indicator — any-true would reintroduce exactly the flicker this
    /// smoothing exists to remove.
    func test_isolatedVoicedFrame_doesNotWinMajority() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 0, voiced: false, conf: 0),
            sample(f0: 0, voiced: false, conf: 0),
            sample(f0: 200, voiced: true, conf: 0.9),
        ])
        XCTAssertEqual(out?.pitch.voiced, false)
    }

    /// Symmetrically, one unvoiced gap mid-sentence must not blank it.
    func test_isolatedGap_doesNotClearMajority() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 200, voiced: true, conf: 0.8, speaking: true),
            sample(f0: 0, voiced: false, conf: 0.1, speaking: false),
            sample(f0: 210, voiced: true, conf: 0.8, speaking: true),
        ])
        XCTAssertEqual(out?.pitch.voiced, true)
        XCTAssertEqual(out?.speechRate.isSpeaking, true)
    }

    /// An exact tie is not a majority: 2-of-4 leaves the indicator off,
    /// which is the conservative direction for a presence signal.
    func test_evenSplit_isNotMajority() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 200, voiced: true, conf: 0.5),
            sample(f0: 200, voiced: true, conf: 0.5),
            sample(f0: 0, voiced: false, conf: 0.5),
            sample(f0: 0, voiced: false, conf: 0.5),
        ])
        XCTAssertEqual(out?.pitch.voiced, false)
    }
}

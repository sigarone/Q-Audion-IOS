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

    // ─── W-VOICEMEANVOICED (2026-08-29) ──────────────────────────────────
    //
    // The regression this file itself introduced. `ConfidenceIndicator`
    // returns exactly 0 for an unvoiced frame, so averaging silence in made
    // the readout report "what fraction of the second was speech" instead of
    // "how trustworthy is the voice": half silence + a confident 0.8 showed
    // 0.4. Reported live 2026-08-29.

    func test_confidence_ignoresSilentFramesRatherThanAveragingTheirZeros() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 0, voiced: false, conf: 0),
            sample(f0: 0, voiced: false, conf: 0),
            sample(f0: 200, voiced: true, conf: 0.8),
            sample(f0: 200, voiced: true, conf: 0.8),
        ])
        XCTAssertEqual(out?.confidence ?? 0, 0.8, accuracy: 0.001)
    }

    /// Pitch is undefined during silence too — averaging its zeros in halved
    /// the reported f0 for the same reason.
    func test_pitch_isAveragedOverVoicedFramesOnly() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 0, voiced: false, conf: 0),
            sample(f0: 220, voiced: true, conf: 0.9),
        ])
        XCTAssertEqual(out?.pitch.f0Hz ?? 0, 220, accuracy: 0.001)
    }

    /// A level IS meaningful across silence, so rms keeps the full window —
    /// restricting it would over-report loudness on a quiet second.
    func test_rms_stillAveragesTheWholeWindow() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 0, voiced: false, conf: 0),      // rms 0
            sample(f0: 1000, voiced: true, conf: 0.9),  // rms 1.0
        ])
        XCTAssertEqual(out?.pitch.rms ?? 0, 0.5, accuracy: 0.001)
    }

    /// An entirely silent second must still report 0, not nil and not a
    /// carried-over value: that is the honest answer, and it matches what the
    /// analysis itself produced for every frame in it.
    func test_fullySilentWindow_reportsZeroConfidence() {
        let out = VoiceAnalysisSmoothing.average(of: [
            sample(f0: 0, voiced: false, conf: 0),
            sample(f0: 0, voiced: false, conf: 0),
        ])
        XCTAssertEqual(out?.confidence ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(out?.pitch.voiced, false)
    }
}

import XCTest
@testable import QAudionEngine

/// The frozen opening spectrum of a call, behind the voice check wave: when it
/// freezes, from what, what it ignores, and that a new call starts clean.
final class VoiceReferenceEnvelopeTests: XCTestCase {
    private let bands = VoiceReferenceEnvelope.bandCount

    private func frame(_ value: Float) -> [Float] {
        [Float](repeating: value, count: bands)
    }

    func testThereIsNoReferenceBeforeTheOpeningFramesHaveBeenSeen() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 4)
        XCTAssertNil(envelope.reference)
        for _ in 0..<3 {
            XCTAssertFalse(envelope.feed(frame(0.5)))
            XCTAssertNil(envelope.reference)
        }
    }

    func testTheReferenceIsTheBandwiseAverageOfTheOpeningFrames() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 4)
        XCTAssertFalse(envelope.feed(frame(0.0)))
        XCTAssertFalse(envelope.feed(frame(0.2)))
        XCTAssertFalse(envelope.feed(frame(0.4)))
        XCTAssertTrue(envelope.feed(frame(0.6)), "the frame that completes the opening freezes it")
        guard let reference = envelope.reference else {
            return XCTFail("the reference should exist after the opening frames")
        }
        XCTAssertEqual(reference.count, bands)
        for value in reference {
            XCTAssertEqual(value, 0.3, accuracy: 1e-6)
        }
    }

    func testBandsAreAveragedIndependently() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 2)
        var low = frame(0)
        var high = frame(0)
        low[3] = 0.2
        high[3] = 0.6
        high[7] = 1.0
        envelope.feed(low)
        envelope.feed(high)
        XCTAssertEqual(envelope.reference?[3] ?? -1, 0.4, accuracy: 1e-6)
        XCTAssertEqual(envelope.reference?[7] ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(envelope.reference?[0] ?? -1, 0, accuracy: 1e-6)
    }

    /// Freezing is the point: a reference that kept averaging would absorb
    /// whoever talks next and the two curves would always agree.
    func testTheReferenceStaysFrozenWhateverComesNext() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 2)
        envelope.feed(frame(0.2))
        envelope.feed(frame(0.4))
        let frozen = envelope.reference
        XCTAssertNotNil(frozen)
        for _ in 0..<10 {
            XCTAssertFalse(envelope.feed(frame(1.0)), "only the first completion reports a freeze")
        }
        XCTAssertEqual(envelope.reference, frozen)
    }

    func testFramesOfTheWrongSizeAreIgnoredNotPadded() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 2)
        XCTAssertFalse(envelope.feed([Float](repeating: 0.5, count: bands - 1)))
        XCTAssertFalse(envelope.feed([Float](repeating: 0.5, count: bands + 1)))
        XCTAssertFalse(envelope.feed([]))
        envelope.feed(frame(0.5))
        XCTAssertNil(envelope.reference, "the ignored frames did not count towards the opening")
        envelope.feed(frame(0.5))
        XCTAssertNotNil(envelope.reference)
    }

    func testAFrameWithANonFiniteValueIsDroppedWhole() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 2)
        var bad = frame(0.5)
        bad[10] = .nan
        XCTAssertFalse(envelope.feed(bad))
        var infinite = frame(0.5)
        infinite[39] = .infinity
        XCTAssertFalse(envelope.feed(infinite))
        envelope.feed(frame(0.2))
        XCTAssertNil(envelope.reference, "dropped frames did not count towards the opening")
        envelope.feed(frame(0.4))
        guard let reference = envelope.reference else {
            return XCTFail("the reference should exist after two good frames")
        }
        for value in reference {
            XCTAssertEqual(value, 0.3, accuracy: 1e-6, "nothing of the dropped frames leaked into the average")
        }
    }

    func testResetStartsTheNextCallFromScratch() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 2)
        envelope.feed(frame(0.9))
        envelope.feed(frame(0.9))
        XCTAssertNotNil(envelope.reference)
        envelope.reset()
        XCTAssertNil(envelope.reference)
        XCTAssertFalse(envelope.feed(frame(0.1)), "the count starts again from zero")
        XCTAssertTrue(envelope.feed(frame(0.3)))
        guard let reference = envelope.reference else {
            return XCTFail("the reference should exist after two frames of the new call")
        }
        for value in reference {
            XCTAssertEqual(value, 0.2, accuracy: 1e-6, "nothing of the previous call is left in the average")
        }
    }

    /// Reset in the middle of the opening drops the frames averaged so far too.
    func testResetDuringTheOpeningDropsTheFramesAlreadySeen() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 2)
        envelope.feed(frame(1.0))
        envelope.reset()
        envelope.feed(frame(0.2))
        envelope.feed(frame(0.4))
        XCTAssertEqual(envelope.reference?[0] ?? -1, 0.3, accuracy: 1e-6)
    }

    func testTheDefaultOpeningIsSixtyFramesAboutFourSeconds() {
        XCTAssertEqual(VoiceReferenceEnvelope.defaultReferenceFrames, 60)
        XCTAssertEqual(VoiceReferenceEnvelope.bandCount, 40)
        let envelope = VoiceReferenceEnvelope()
        for _ in 0..<59 {
            XCTAssertFalse(envelope.feed(frame(0.5)))
        }
        XCTAssertNil(envelope.reference)
        XCTAssertTrue(envelope.feed(frame(0.5)))
        XCTAssertNotNil(envelope.reference)
    }

    /// The envelope ignores any frame that is not `bandCount` bands, so if the
    /// analyser ever emitted another size the reference would silently never
    /// freeze and the wave would stay on the trend. This ties the constant to
    /// what `SpectrumExtractor` really produces (with the settings the call
    /// integration uses: its default initialiser), for a voiced frame and for a
    /// silent one, and to the envelope really accepting such a frame.
    func testBandCountIsWhatTheSpectrumExtractorEmits() {
        let sampleRate = 48_000
        let extractor = SpectrumExtractor()

        // 20 ms of a 440 Hz tone, loud enough to pass the silence gate.
        let omega: Double = 2 * Double.pi * 440 / Double(sampleRate)
        let tone: [Int16] = (0..<960).map { index in
            let sample: Double = 8_000 * sin(omega * Double(index))
            return Int16(sample)
        }
        let voiced = extractor.compute(tone, sampleRate: sampleRate)
        XCTAssertEqual(voiced.count, VoiceReferenceEnvelope.bandCount)
        XCTAssertTrue(voiced.contains { $0 > 0 }, "the tone passed the silence gate, so the bands carry energy")
        XCTAssertTrue(voiced.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })

        let silent = extractor.compute([Int16](repeating: 0, count: 960), sampleRate: sampleRate)
        XCTAssertEqual(silent.count, VoiceReferenceEnvelope.bandCount)

        let envelope = VoiceReferenceEnvelope(referenceFrames: 1)
        XCTAssertTrue(envelope.feed(voiced), "a frame the analyser really emits is not ignored for its size")
        XCTAssertEqual(envelope.reference?.count, VoiceReferenceEnvelope.bandCount)
    }

    /// The count of frames to average can never be zero or negative: that would
    /// divide by zero or never freeze.
    func testAnOpeningOfZeroFramesIsTreatedAsOne() {
        let envelope = VoiceReferenceEnvelope(referenceFrames: 0)
        XCTAssertTrue(envelope.feed(frame(0.7)))
        XCTAssertEqual(envelope.reference?[0] ?? -1, 0.7, accuracy: 1e-6)
    }
}

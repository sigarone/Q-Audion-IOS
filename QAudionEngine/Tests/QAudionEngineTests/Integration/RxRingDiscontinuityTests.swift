import XCTest
@testable import QAudionEngine

/// Audio that the bounded RX ring drops under load is missing for the voice analysis, and the analysis has to
/// be told how much before the audio that follows the gap (docs/voice-analysis-spec.md, section 2).
///
/// The ring holds 10 buffers and drops the oldest. To make it overflow deterministically the test blocks the
/// analysis queue inside the callback of a result (the callback runs on that queue, outside the engine
/// lock), feeds 11 buffers while it is blocked so that the first of them is dropped, and releases the queue.
/// What the analysis does afterwards shows what it was told:
///  - a gap shorter than 2 s restarts its 100 ms grid and keeps its histories;
///  - a gap of 2 s or more clears everything, so the count of dropped samples has to be exact (samples, not
///    bytes).
///
/// Wired into CI: `engine-tests.yml` runs the whole `QAudionEngineTests` target.
final class RxRingDiscontinuityTests: XCTestCase {

    /// The capacity of `QAudionCallIntegration.rxRingCapacity`. If it changes, the test no longer overflows
    /// the ring and fails on the first assertion, which says so.
    private let ringCapacity = 10

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [VoiceAnalysisResult] = []
        func add(_ result: VoiceAnalysisResult) -> Int {
            lock.lock(); defer { lock.unlock() }
            items.append(result)
            return items.count
        }
        var all: [VoiceAnalysisResult] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    /// Feeds `firstSamples` of `signal` and blocks the analysis queue in the callback of result number
    /// `blockOnResult`. While it is blocked it feeds one buffer of `droppedSamples` silent samples and then
    /// `ringCapacity` buffers of `bufferSamples` samples of the signal, so the ring drops the first one. Then
    /// it releases the queue, waits for the analysis to finish and returns every result.
    private func results(signal: [Double], firstSamples: Int, blockOnResult: Int,
                         droppedSamples: Int, bufferSamples: Int) -> [VoiceAnalysisResult] {
        let integration = QAudionCallIntegration()
        integration.backgroundFlag = AppBackgroundFlag()
        let recorder = Recorder()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        integration.getVoiceAnalysis().onResult = { result in
            if recorder.add(result) == blockOnResult {
                entered.signal()
                _ = release.wait(timeout: .now() + 30)
            }
        }

        integration.feedNativeAudioSrtpRxPcm(SyntheticVoice.pcm(signal, from: 0, count: firstSamples))
        guard entered.wait(timeout: .now() + 30) == .success else {
            release.signal()
            XCTFail("the analysis never reached result \(blockOnResult)")
            return recorder.all
        }
        // The analysis queue is now inside the callback: nothing is taken from the ring.
        integration.feedNativeAudioSrtpRxPcm(SyntheticVoice.pcm([Double](repeating: 0, count: droppedSamples)))
        var offset = firstSamples
        for _ in 0..<ringCapacity {
            integration.feedNativeAudioSrtpRxPcm(SyntheticVoice.pcm(signal, from: offset, count: bufferSamples))
            offset += bufferSamples
        }
        release.signal()
        integration.drainAnalysisForTesting()
        return recorder.all
    }

    private lazy var vowel: [Double] = SyntheticVoice.vowel(f0: 120, SyntheticVoice.a, seconds: 3.0)

    /// A drop shorter than 2 s restarts the 100 ms grid at the first buffer that is left, as a short
    /// discontinuity does, so the next analysis comes 4800 samples after that buffer starts. Without the
    /// report, the grid would carry on across the hole and fire 2600 samples into it.
    func testADropRestartsTheGridAtTheBufferThatIsLeft() {
        // 7000 samples: the first analysis falls at 4800, inside the buffer, and the callback blocks there.
        // After it: a dropped buffer of 300 samples and ten buffers of 300 samples = 3000 samples.
        let all = results(signal: vowel, firstSamples: 7_000, blockOnResult: 1,
                          droppedSamples: 300, bufferSamples: 300)
        XCTAssertEqual(all.count, 1,
                       "3000 samples after the gap are short of 4800: no second analysis yet. Two results "
                        + "means the drop was not reported (or the ring capacity is no longer \(ringCapacity)).")
    }

    /// The histories survive a drop shorter than 2 s. 60,000 samples are 1.25 s; counted as bytes they would
    /// read as 2.5 s and clear everything.
    func testADropShorterThanTwoSecondsKeepsTheHistories() {
        let all = results(signal: vowel, firstSamples: 15_000, blockOnResult: 3,
                          droppedSamples: 60_000, bufferSamples: 480)
        XCTAssertEqual(all.count, 4, "the analysis after the gap comes 4800 samples after it")
        guard all.count == 4 else { return }
        XCTAssertTrue(all[2].voiceHealth.hnrValid, "the third voiced analysis has a valid HNR")
        XCTAssertTrue(all[3].voiceHealth.hnrValid, "a gap of 1.25 s keeps the HNR history")
    }

    /// 96,000 samples (2 s) clear everything, like `reset()`.
    func testADropOfTwoSecondsClearsEverything() {
        let all = results(signal: vowel, firstSamples: 15_000, blockOnResult: 3,
                          droppedSamples: 96_000, bufferSamples: 480)
        XCTAssertEqual(all.count, 4)
        guard all.count == 4 else { return }
        XCTAssertTrue(all[2].voiceHealth.hnrValid)
        XCTAssertFalse(all[3].voiceHealth.hnrValid, "a gap of 2 s clears the history: one voiced step is not three")
    }
}

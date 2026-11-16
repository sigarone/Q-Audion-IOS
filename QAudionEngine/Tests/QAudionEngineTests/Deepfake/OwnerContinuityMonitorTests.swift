import XCTest
@testable import QAudionEngine

/// Counts `onStateChanged` deliveries (they fire on the monitor's own queue).
private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [OwnerContinuityMonitor.State] = []
    func record(_ s: OwnerContinuityMonitor.State) { lock.lock(); _states.append(s); lock.unlock() }
    var states: [OwnerContinuityMonitor.State] { lock.lock(); defer { lock.unlock() }; return _states }
}

/// Reports a settable number of milliseconds of speech for every window.
private final class StubSpeechDetector: WindowSpeechDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int
    init(ms: Int) { self.ms = ms }
    func set(_ value: Int) { lock.lock(); ms = value; lock.unlock() }
    func speechMs(pcm16k: [Float]) -> Int { lock.lock(); defer { lock.unlock() }; return ms }
}

/// An embedder that never gives an embedding.
private final class NoEmbedding: SpeakerEmbedding {
    static let embeddingDimension = DeterministicTestEmbedder.embeddingDimension
    func embed(pcm16kMono: [Float]) throws -> [Float] { throw CamPlusSpeakerEmbedder.CamPlusError.runtimeUnavailable }
}

final class OwnerContinuityMonitorTests: XCTestCase {

    /// 20 ms frames in one window of the monitor: 4 s.
    private let windowFrames = 200

    private func makeMonitor(
        registered: Bool,
        embedder: any SpeakerEmbedding = DeterministicTestEmbedder(),
        speech: StubSpeechDetector = StubSpeechDetector(ms: 4_000)
    ) -> (OwnerContinuityMonitor, StateRecorder) {
        let verifier = SpeakerVerifier(embedder: embedder)
        if registered {
            var template = [Float](repeating: 0, count: DeterministicTestEmbedder.embeddingDimension)
            template[0] = 1
            verifier.importTemplate(template)
        }
        let monitor = OwnerContinuityMonitor(verifier: verifier, speechDetector: speech)
        let recorder = StateRecorder()
        monitor.onStateChanged = { recorder.record($0) }
        return (monitor, recorder)
    }

    /// 20 ms of a 440 Hz tone at 48 kHz, Int16 mono little-endian.
    private func toneFrame(phase: Int) -> Data {
        var out = Data(capacity: 960 * 2)
        for i in 0..<960 {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(phase + i) / 48_000))
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    func testUnregisteredMonitorQueuesNothingPerChunkAndNotifiesOnce() {
        let (monitor, recorder) = makeMonitor(registered: false)
        monitor.start()
        monitor.drainForTesting()
        let frame = toneFrame(phase: 0)
        for _ in 0..<500 { monitor.feed(pcmFrame: frame) }
        monitor.drainForTesting()

        XCTAssertEqual(monitor.currentState(), .inactive)
        XCTAssertEqual(monitor.enqueuedChunkCount, 1, "only the first chunk after start may be queued")
        XCTAssertEqual(recorder.states, [.inactive], "the unchanged inactive state is delivered once")
    }

    func testRepeatedStateIsNotDeliveredAgainAndChangesAreDeliveredOnce() {
        let (monitor, recorder) = makeMonitor(registered: false)
        monitor.start()
        monitor.drainForTesting()

        for _ in 0..<5 { monitor.applyStateForTesting(.inactive) }
        XCTAssertEqual(recorder.states, [.inactive])

        let verified = OwnerContinuityMonitor.State.scored(score: 0.8, level: .verified)
        monitor.applyStateForTesting(verified)
        XCTAssertEqual(recorder.states, [.inactive, verified])
        XCTAssertEqual(monitor.currentState(), verified)

        let uncertain = OwnerContinuityMonitor.State.scored(score: 0.55, level: .uncertain)
        monitor.applyStateForTesting(uncertain)
        monitor.applyStateForTesting(.inactive)
        monitor.applyStateForTesting(.inactive)
        XCTAssertEqual(recorder.states, [.inactive, verified, uncertain, .inactive])
        XCTAssertEqual(monitor.currentState(), .inactive)
    }

    /// A scored state is delivered once per evaluated window even when two windows give the very same state: the
    /// consumer reads an external value at delivery time (the app sends `.mismatch` to the peer only once
    /// `shouldAlert()` is true, i.e. from the third consecutive mismatch window), so dropping the third
    /// identical `.scored(mismatch)` would leave the peer at `.uncertain`. Only `.inactive` is de-duplicated.
    func testIdenticalScoredWindowsAreDeliveredEveryTime() {
        let (monitor, recorder) = makeMonitor(registered: false)
        monitor.start()
        monitor.drainForTesting()
        let mismatch = OwnerContinuityMonitor.State.scored(score: 0.31, level: .mismatch)
        for _ in 0..<3 { monitor.applyStateForTesting(mismatch) }
        XCTAssertEqual(recorder.states, [mismatch, mismatch, mismatch], "one callback per evaluated window")

        let verified = OwnerContinuityMonitor.State.scored(score: 0.8, level: .verified)
        monitor.applyStateForTesting(verified)
        monitor.applyStateForTesting(verified)
        XCTAssertEqual(recorder.states.count, 5)
    }

    func testRepeatedInactiveIsDeliveredOnceButAgainAfterAScoredState() {
        let (monitor, recorder) = makeMonitor(registered: false)
        monitor.start()
        monitor.drainForTesting()
        for _ in 0..<4 { monitor.applyStateForTesting(.inactive) }
        XCTAssertEqual(recorder.states, [.inactive])
        monitor.applyStateForTesting(.scored(score: 0.7, level: .verified))
        monitor.applyStateForTesting(.inactive)
        monitor.applyStateForTesting(.inactive)
        XCTAssertEqual(recorder.states.count, 3)
    }

    func testRegisteredMonitorQueuesEveryChunkAndScoresAfterWindow() {
        let (monitor, recorder) = makeMonitor(registered: true)
        monitor.start()
        monitor.drainForTesting()
        // The window is 4 s: one frame short of it gives no score, the frame that completes it gives one.
        for n in 0..<(windowFrames - 1) { monitor.feed(pcmFrame: toneFrame(phase: n * 960)) }
        monitor.drainForTesting()
        XCTAssertEqual(scoredCount(recorder), 0, "less than a window is not scored")
        monitor.feed(pcmFrame: toneFrame(phase: (windowFrames - 1) * 960))
        monitor.drainForTesting()

        XCTAssertEqual(monitor.enqueuedChunkCount, windowFrames)
        XCTAssertEqual(scoredCount(recorder), 1, "one window of audio gives exactly one score")
        if case .scored = monitor.currentState() {} else { XCTFail("expected a scored state") }
    }

    /// A window without speech is no score: nothing is delivered and the streak is untouched, however many such
    /// windows pass; the next window with speech scores as usual.
    func testAWindowWithoutSpeechIsNotScored() {
        let speech = StubSpeechDetector(ms: 0)
        let (monitor, recorder) = makeMonitor(registered: true, speech: speech)
        monitor.start()
        monitor.drainForTesting()
        for n in 0..<(3 * windowFrames) { monitor.feed(pcmFrame: toneFrame(phase: n * 960)) }
        monitor.drainForTesting()
        XCTAssertEqual(scoredCount(recorder), 0)
        XCTAssertFalse(monitor.shouldAlert())

        speech.set(OwnerContinuityMonitor.minSpeechMs)
        for n in 0..<windowFrames { monitor.feed(pcmFrame: toneFrame(phase: n * 960)) }
        monitor.drainForTesting()
        XCTAssertEqual(scoredCount(recorder), 1)
    }

    /// A window the embedder gives no embedding for is no score either, so a model that is unavailable cannot walk the
    /// smoothed value down to a Mismatch alert.
    func testAWindowWithNoEmbeddingIsNotScored() {
        let (monitor, recorder) = makeMonitor(registered: true, embedder: NoEmbedding())
        monitor.start()
        monitor.drainForTesting()
        for n in 0..<(4 * windowFrames) { monitor.feed(pcmFrame: toneFrame(phase: n * 960)) }
        monitor.drainForTesting()
        XCTAssertEqual(scoredCount(recorder), 0)
        XCTAssertFalse(monitor.shouldAlert())
        XCTAssertEqual(monitor.currentState(), .inactive)
    }

    private func scoredCount(_ recorder: StateRecorder) -> Int {
        recorder.states.filter { if case .scored = $0 { return true } else { return false } }.count
    }

    func testRestartFromScoredStateAnnouncesInactiveOnce() {
        let (monitor, recorder) = makeMonitor(registered: true)
        monitor.start()
        monitor.drainForTesting()
        let verified = OwnerContinuityMonitor.State.scored(score: 0.8, level: .verified)
        monitor.applyStateForTesting(verified)

        monitor.start()
        monitor.drainForTesting()
        XCTAssertEqual(monitor.currentState(), .inactive)
        XCTAssertEqual(recorder.states, [verified, .inactive])
    }

    func testFirstStateAfterRestartIsDeliveredEvenIfEqualToTheLastOne() {
        let (monitor, recorder) = makeMonitor(registered: false)
        monitor.start()
        monitor.drainForTesting()
        monitor.feed(pcmFrame: toneFrame(phase: 0))
        monitor.drainForTesting()
        XCTAssertEqual(recorder.states, [.inactive])

        monitor.start()
        monitor.drainForTesting()
        monitor.feed(pcmFrame: toneFrame(phase: 0))
        monitor.feed(pcmFrame: toneFrame(phase: 960))
        monitor.drainForTesting()
        XCTAssertEqual(recorder.states, [.inactive, .inactive])
    }
}

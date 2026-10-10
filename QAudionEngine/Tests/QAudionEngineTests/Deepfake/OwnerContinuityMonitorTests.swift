import XCTest
@testable import QAudionEngine

/// Counts `onStateChanged` deliveries (they fire on the monitor's own queue).
private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [OwnerContinuityMonitor.State] = []
    func record(_ s: OwnerContinuityMonitor.State) { lock.lock(); _states.append(s); lock.unlock() }
    var states: [OwnerContinuityMonitor.State] { lock.lock(); defer { lock.unlock() }; return _states }
}

final class OwnerContinuityMonitorTests: XCTestCase {

    private func makeMonitor(registered: Bool) -> (OwnerContinuityMonitor, StateRecorder) {
        let verifier = SpeakerVerifier(embedder: DeterministicTestEmbedder())
        if registered {
            var template = [Float](repeating: 0, count: DeterministicTestEmbedder.embeddingDimension)
            template[0] = 1
            verifier.importTemplate(template)
        }
        let monitor = OwnerContinuityMonitor(verifier: verifier)
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
        // 3 s window at 20 ms per frame = 150 frames.
        for n in 0..<150 { monitor.feed(pcmFrame: toneFrame(phase: n * 960)) }
        monitor.drainForTesting()

        XCTAssertEqual(monitor.enqueuedChunkCount, 150)
        let scored = recorder.states.filter { if case .scored = $0 { return true } else { return false } }
        XCTAssertEqual(scored.count, 1, "one window of audio gives exactly one score")
        if case .scored = monitor.currentState() {} else { XCTFail("expected a scored state") }
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

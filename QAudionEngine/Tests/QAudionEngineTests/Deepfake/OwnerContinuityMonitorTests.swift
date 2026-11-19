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
    private func toneFrame(phase: Int, hz: Double = 440) -> Data {
        var out = Data(capacity: 960 * 2)
        for i in 0..<960 {
            let v = Int16(8000 * sin(2 * Double.pi * hz * Double(phase + i) / 48_000))
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

    /// A window the embedder gives no embedding for is no score either: nothing is delivered and the smoothed value and
    /// the streak stay as they are.
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

    // MARK: - Learning from calls

    private struct LearningRig {
        let monitor: OwnerContinuityMonitor
        let recorder: StateRecorder
        let templates: VoiceprintStore
        let progress: MemoryOwnerVoiceProgress
        let speech: StubSpeechDetector
    }

    private func makeLearningRig(userId: @escaping () -> String = { "u1" }) -> LearningRig {
        let templates = VoiceprintStore(backing: InMemoryVoiceprintBacking())
        let progress = MemoryOwnerVoiceProgress()
        let speech = StubSpeechDetector(ms: 4_000)
        let monitor = OwnerContinuityMonitor(
            verifier: SpeakerVerifier(embedder: DeterministicTestEmbedder()),
            speechDetector: speech,
            learner: OwnerVoiceLearner(templates: templates, progress: progress))
        monitor.userIdProvider = userId
        let recorder = StateRecorder()
        monitor.onStateChanged = { recorder.record($0) }
        return LearningRig(monitor: monitor, recorder: recorder, templates: templates, progress: progress, speech: speech)
    }

    /// One call: `start`, `windows` windows of tone from the local microphone, `stop` (which hands the windows over).
    private func runCall(_ rig: LearningRig, windows: Int) {
        rig.monitor.start()
        rig.monitor.drainForTesting()
        for _ in 0..<windows {
            for n in 0..<windowFrames { rig.monitor.feed(pcmFrame: toneFrame(phase: n * 960)) }
        }
        rig.monitor.stop()
        rig.monitor.drainForTesting()
    }

    /// One call whose windows are tones of the given frequencies, in order.
    private func runCall(_ rig: LearningRig, tones: [Double]) {
        rig.monitor.start()
        rig.monitor.drainForTesting()
        for hz in tones {
            for n in 0..<windowFrames { rig.monitor.feed(pcmFrame: toneFrame(phase: n * 960, hz: hz)) }
        }
        rig.monitor.stop()
        rig.monitor.drainForTesting()
    }

    private func learnedTemplateRig() -> LearningRig {
        let rig = makeLearningRig()
        runCall(rig, windows: 6)
        runCall(rig, windows: 6)
        XCTAssertEqual(rig.progress.record?.windows.count, 12)
        return rig
    }

    /// With a template, windows of another voice are not kept for the next fusion.
    func testWindowsThatMismatchTheTemplateAreNotCollected() {
        let rig = learnedTemplateRig()
        runCall(rig, tones: [1_000, 1_000, 1_000])
        XCTAssertEqual(rig.progress.record?.windows.count, 12)
    }

    /// One mismatch among good windows (a noise burst) costs only that window, wherever it falls.
    func testOneMismatchAmongGoodWindowsStillContributesTheGoodOnes() {
        let rig = learnedTemplateRig()
        runCall(rig, tones: [440, 440, 1_000])
        XCTAssertEqual(rig.progress.record?.windows.count, 14)
        runCall(rig, tones: [1_000, 440, 440])
        XCTAssertEqual(rig.progress.record?.windows.count, 16)
    }

    /// A call that is mostly mismatch (2 or more, at least a third of the windows judged) contributes nothing.
    func testAMostlyMismatchedCallContributesNothing() {
        let rig = learnedTemplateRig()
        runCall(rig, tones: [440, 1_000, 1_000])
        XCTAssertEqual(rig.progress.record?.windows.count, 12)
    }

    /// Windows after the cap are not judged for learning: a mismatch there does not cost the batch.
    func testAMismatchAfterTheCapKeepsTheBatch() {
        let rig = learnedTemplateRig()
        runCall(rig, tones: [440, 440, 440, 440, 440, 440, 1_000, 1_000, 1_000])
        XCTAssertEqual(rig.progress.record?.windows.count, 18)
    }

    /// Before the first template there is nothing to compare with: every window is kept, whoever speaks.
    func testTheFirstLearningWithoutATemplateKeepsEveryWindow() {
        let rig = makeLearningRig()
        runCall(rig, tones: [1_000, 440, 1_000])
        XCTAssertEqual(rig.progress.record?.windows.count, 3)
    }

    /// A person who never enrolled by hand gets a template from two ordinary calls, with the state `.inactive`
    /// throughout (nothing is asked and nothing is announced), and the call after that is scored against it. A call
    /// keeps at most 6 windows.
    func testATemplateIsLearnedFromCallsAndScoredFromTheNextOne() throws {
        let rig = makeLearningRig()
        runCall(rig, windows: 7)
        XCTAssertEqual(rig.progress.record?.windows.count, OwnerVoiceLearning.maxWindowsPerCall)
        XCTAssertNil(rig.templates.load(contactId: VoiceprintStore.deviceOwnerId), "6 windows of one call are below MIN")

        runCall(rig, windows: 6)
        XCTAssertNotNil(rig.templates.load(contactId: VoiceprintStore.deviceOwnerId), "12 windows of 2 calls reach MIN")
        XCTAssertEqual(scoredCount(rig.recorder), 0, "learning is silent")
        XCTAssertEqual(rig.monitor.currentState(), .inactive)
        XCTAssertFalse(rig.monitor.shouldAlert())

        runCall(rig, windows: 1)
        XCTAssertEqual(scoredCount(rig.recorder), 1, "with a template the window is scored")
        guard case .scored(_, let level) = rig.monitor.currentState() else { return XCTFail("expected a scored state") }
        XCTAssertEqual(level, .verified)
    }

    /// Only windows that hold speech are learned from: the gate that keeps them out of the score keeps them out of
    /// the template.
    func testWindowsWithoutSpeechAreNotLearnedFrom() {
        let rig = makeLearningRig()
        rig.speech.set(0)
        runCall(rig, windows: 3)
        XCTAssertEqual(rig.progress.record?.windows.count, 0)

        rig.speech.set(OwnerContinuityMonitor.minSpeechMs - 1)
        runCall(rig, windows: 2)
        XCTAssertEqual(rig.progress.record?.windows.count, 0, "just under the gate is no speech")

        rig.speech.set(OwnerContinuityMonitor.minSpeechMs)
        runCall(rig, windows: 2)
        XCTAssertEqual(rig.progress.record?.windows.count, 2)
    }

    /// A different account on the same phone starts fresh: the first account's template is not scored against the
    /// second account's voice and is not inherited.
    func testADifferentAccountIsNotScoredAgainstTheFirstOnesTemplate() {
        var account = "u1"
        let rig = makeLearningRig(userId: { account })
        runCall(rig, windows: 6)
        runCall(rig, windows: 6)
        runCall(rig, windows: 1)
        XCTAssertEqual(scoredCount(rig.recorder), 1)

        account = "u2"
        runCall(rig, windows: 1)
        XCTAssertEqual(scoredCount(rig.recorder), 1, "nothing is scored for the new account")
        XCTAssertEqual(rig.monitor.currentState(), .inactive)
        XCTAssertNil(rig.templates.load(contactId: VoiceprintStore.deviceOwnerId))
        XCTAssertEqual(rig.progress.record?.userId, "u2")
        XCTAssertEqual(rig.progress.record?.windows.count, 1)
    }

    /// Without an account nothing is learned and nothing is written.
    func testNothingIsLearnedWithoutAnAccount() {
        let rig = makeLearningRig(userId: { "" })
        runCall(rig, windows: 3)
        XCTAssertNil(rig.progress.data)
        XCTAssertNil(rig.templates.load(contactId: VoiceprintStore.deviceOwnerId))
        XCTAssertEqual(rig.monitor.currentState(), .inactive)
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

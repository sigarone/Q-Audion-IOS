import XCTest
import Foundation
@testable import QAudionEngine

/// The call wiring of the contact-voice check, without models, keychain or audio: the session, its latch, the process and the
/// poll, against fake services. The tests wait on the queue of the session (a barrier), never on time.
final class VoiceCallSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VoiceFeature.reset()
    }

    override func tearDown() {
        VoiceFeature.reset()
        super.tearDown()
    }

    // MARK: fakes

    private final class StubVad: TimedVadModel {
        var lastCostNs: Int64 { 1_000 }
        func reset() {}
        func step(_ chunk: [Float]) throws -> Float { 0 }
    }

    private final class StubEmbedder: VoiceWindowEmbedder {
        func embed(window: VoiceWindowResult) throws -> VoiceEmbedding? { nil }
    }

    private final class FakeServices: VoiceServices {
        let config: VoiceEngineConfig
        let lock = NSLock()
        var prepareCalls = 0
        var loadCalls = 0
        var tagDevices: [String] = []
        var updates: [String] = []
        var deletes: [String] = []
        var finished = 0
        var threadsWereBackground = true
        var record: TemplateRecord?
        private(set) var budget: VoiceCpuBudget?

        init(config: VoiceEngineConfig) {
            self.config = config
        }

        private func note() {
            if Thread.isMainThread { threadsWereBackground = false }
        }

        func prepare() -> VoicePrepared? {
            lock.lock()
            defer { lock.unlock() }
            note()
            prepareCalls += 1
            if budget == nil { budget = VoiceCpuBudget(cpu: config.engine.cpu) }
            return VoicePrepared(config: config, vad: StubVad(), embedder: StubEmbedder(), model: .ok)
        }

        func loadRecord(contactId: String, cfg: VoiceStateConstants) throws -> TemplateRecord? {
            lock.lock()
            defer { lock.unlock() }
            note()
            loadCalls += 1
            return record
        }

        func deviceTag(deviceId: String) throws -> Int {
            lock.lock()
            defer { lock.unlock() }
            tagDevices.append(deviceId)
            return 7
        }

        func update(contactId: String, cfg: VoiceStateConstants, _ body: (TemplateRecord?) throws -> TemplateRecord?) throws {
            lock.lock()
            defer { lock.unlock() }
            note()
            updates.append(contactId)
            _ = try body(record)
        }

        func deleteRecord(contactId: String) throws {
            lock.lock()
            defer { lock.unlock() }
            deletes.append(contactId)
        }

        func callFinished() {
            lock.lock()
            finished += 1
            lock.unlock()
        }
    }

    private final class ManualTicker: VoiceTicker {
        var handler: (() -> Void)?
        var stopped = false
        func start(everyMs: Int, queue: DispatchQueue, handler: @escaping () -> Void) { self.handler = handler }
        func stop() { stopped = true }
        func fire(on queue: DispatchQueue) { queue.sync { self.handler?() } }
    }

    private final class FakeSource: VoiceStatsSource {
        var polls = 0
        var next: VoicePollResult = .unavailable
        func pollOnce(_ deliver: @escaping (VoicePollResult) -> Void) {
            polls += 1
            deliver(next)
        }
    }

    private func services() throws -> FakeServices {
        let bundle = try VoiceKat.bundle()
        return FakeServices(config: VoiceEngineConfig(bundle: bundle, cohort: try VoiceScoringKat.cohort()))
    }

    private func binding(device: String? = "dev-1", contact: String = "contact-1") -> VoiceCallBinding {
        VoiceCallBinding(callId: "11111111-2222-3333-4444-555555555555", contactId: contact, peerDeviceId: device,
                         tStartS: 1_790_000_000, utcOffsetS: 3_600)
    }

    private func makeSession(_ fake: FakeServices, _ process: VoiceProcess, binding b: VoiceCallBinding? = nil,
                             ticker: ManualTicker = ManualTicker(), protectedData: ProtectedDataFlag = ProtectedDataFlag())
        -> (VoiceCallSession, ManualTicker) {
        let session = VoiceCallSession(
            binding: b ?? binding(), process: process, ticker: { ticker }, protectedData: protectedData)
        return (session, ticker)
    }

    // MARK: the flag is off

    func testWithTheFlagOffNothingIsCreatedAndNothingIsTouched() throws {
        let fake = try services()
        let process = VoiceProcess(services: fake)
        XCTAssertFalse(VoiceFeature.isEnabled)
        XCTAssertNil(process.beginCall(binding()))
        process.cancelPostCallWork()
        process.reportBusy(who: "guardian", startNs: 0, endNs: 10)
        let value = VoiceBusy.measure("owner") { 41 + 1 }
        XCTAssertEqual(value, 42)
        VoiceCallWiring.callStarting()
        XCTAssertEqual(fake.prepareCalls, 0)
        XCTAssertEqual(fake.loadCalls, 0)
        XCTAssertTrue(fake.updates.isEmpty)
        XCTAssertNil(fake.budget, "nothing reports to a budget that was never made")
    }

    func testASessionThatIsStartedWithTheFlagOffDoesNothing() throws {
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let (session, _) = makeSession(fake, process)
        session.mediaStart()
        session.queue.sync {}
        XCTAssertEqual(fake.prepareCalls, 0, "the engine is not built while the flag is off")
        XCTAssertNil(session.withEngine { $0 })
    }

    // MARK: the engine of a call

    func testMediaStartBuildsTheEngineOnABackgroundQueueWithTheDeviceOfThisCall() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let (session, ticker) = makeSession(fake, process, binding: binding(device: "dev-of-this-call"))
        session.mediaStart()
        session.queue.sync {}
        XCTAssertNotNil(session.withEngine { $0 })
        XCTAssertEqual(fake.tagDevices, ["dev-of-this-call"])
        XCTAssertEqual(fake.loadCalls, 1)
        XCTAssertTrue(fake.threadsWereBackground, "the models and the store are never reached from the main thread")
        XCTAssertNotNil(ticker.handler, "the poll is running")
        // A second call has its own binding: nothing is read from the first.
        let (other, _) = makeSession(fake, process, binding: binding(device: nil, contact: "contact-2"))
        other.mediaStart()
        other.queue.sync {}
        XCTAssertEqual(fake.tagDevices, ["dev-of-this-call", ""])
    }

    func testAFallbackThatComesBeforeMediaStartIsReplayedWhenTheEngineIsBuilt() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let latch = VoiceCallLatch()
        latch.noteFallback() // the call fell back to the data channel before media start
        let (session, _) = makeSession(fake, process)
        latch.attach(session)
        session.mediaStart()
        session.queue.sync {}
        session.callEnded()
        session.queue.sync {}
        XCTAssertTrue(fake.updates.isEmpty, "a call that left SRTP hands nothing to the state functions")
        XCTAssertEqual(fake.finished, 1)
    }

    func testWithoutAFallbackTheCallIsHandedToTheStateFunctionsUnderTheContactLock() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let (session, ticker) = makeSession(fake, process)
        session.mediaStart()
        session.queue.sync {}
        session.callEnded()
        session.queue.sync {}
        XCTAssertEqual(fake.updates, ["contact-1"], "load, end of call and save are one operation of the store")
        XCTAssertEqual(fake.finished, 1)
        XCTAssertTrue(ticker.stopped)
    }

    func testAFallbackAfterMediaStartReachesTheEngine() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let latch = VoiceCallLatch()
        let (session, _) = makeSession(fake, process)
        latch.attach(session)
        session.mediaStart()
        session.queue.sync {}
        latch.noteFallback()
        session.queue.sync {}
        session.callEnded()
        session.queue.sync {}
        XCTAssertTrue(fake.updates.isEmpty)
    }

    // MARK: the post-call work

    func testACancelThatComesBeforeTheEngineExistsStillReachesIt() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let (session, _) = makeSession(fake, process)
        process.cancelPostCallWork() // no engine yet, no session registered by this test's own call
        session.requestPostCancel()
        session.mediaStart()
        session.queue.sync {}
        XCTAssertEqual(session.withEngine { $0?.postCancelRequested }, true, "work that would start after the cancel is cancelled")
    }

    func testACallStartCancelsThePostCallWorkOfALiveSession() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let session = try XCTUnwrap(process.beginCall(binding()))
        session.mediaStart()
        session.queue.sync {}
        XCTAssertEqual(session.withEngine { $0?.postCancelRequested }, false)
        process.cancelPostCallWork()
        XCTAssertEqual(session.withEngine { $0?.postCancelRequested }, true)
    }

    func testAnEndedSessionIsForgottenAndTheBackgroundTaskIsGivenBack() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let tasks = RecordingTasks()
        process.backgroundTasks = tasks
        let session = try XCTUnwrap(process.beginCall(binding()))
        session.mediaStart()
        session.queue.sync {}
        session.callEnded()
        session.queue.sync {}
        XCTAssertEqual(tasks.begun, ["voice-post-call"])
        XCTAssertEqual(tasks.ended, [1])
        session.callEnded() // idempotent
        session.queue.sync {}
        XCTAssertEqual(tasks.begun.count, 1)
    }

    private final class RecordingTasks: VoiceBackgroundTasks {
        var begun: [String] = []
        var ended: [Int] = []
        func begin(name: String, onExpiration: @escaping () -> Void) -> Int? {
            begun.append(name)
            return begun.count
        }
        func end(_ token: Int) { ended.append(token) }
    }

    // MARK: the poll

    func testEveryTickAsksTheSourceOnceAndAFaultReachesTheEngine() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let (session, ticker) = makeSession(fake, process)
        let source = FakeSource()
        session.attachStatsSource(source)
        session.mediaStart()
        session.queue.sync {}
        source.next = .unavailable
        ticker.fire(on: session.queue)
        ticker.fire(on: session.queue)
        session.queue.sync {}
        XCTAssertEqual(source.polls, 2)
        source.next = .fault(.severalAudioRows)
        ticker.fire(on: session.queue)
        session.queue.sync {}
        XCTAssertEqual(source.polls, 3)
    }

    func testAPollIsHeldBackWhileTheProtectedDataIsUnreadable() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let locked = ProtectedDataFlag()
        locked.set(isAvailable: false)
        let (session, ticker) = makeSession(fake, process, protectedData: locked)
        let source = FakeSource()
        session.attachStatsSource(source)
        session.mediaStart()
        session.queue.sync {}
        ticker.fire(on: session.queue)
        XCTAssertEqual(source.polls, 0)
        XCTAssertEqual(session.heldBackPolls, 1)
        locked.set(isAvailable: true)
        ticker.fire(on: session.queue)
        XCTAssertEqual(source.polls, 1)
    }

    // MARK: the tap

    func testBlocksOfTheTapReachTheEngineOnTheWorkerAndNeverBeforeMediaStart() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let (session, _) = makeSession(fake, process)
        session.rxTap.ingest(samples: [Int16](repeating: 100, count: 480), frames: 480, rateHz: 48_000)
        session.queue.sync {}
        XCTAssertEqual(session.fedBlocks, 0, "a block before media start is discarded")
        session.mediaStart()
        session.queue.sync {}
        for _ in 0..<5 {
            session.rxTap.ingest(samples: [Int16](repeating: 100, count: 480), frames: 480, rateHz: 48_000)
        }
        session.queue.sync {}
        XCTAssertEqual(session.fedBlocks, 5)
    }

    func testBlocksAreLetGoWhileTheProtectedDataIsUnreadable() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        let locked = ProtectedDataFlag()
        locked.set(isAvailable: false)
        let (session, _) = makeSession(fake, process, protectedData: locked)
        session.mediaStart()
        session.queue.sync {}
        for _ in 0..<3 {
            session.rxTap.ingest(samples: [Int16](repeating: 5, count: 480), frames: 480, rateHz: 48_000)
        }
        session.queue.sync {}
        XCTAssertEqual(session.fedBlocks, 0)
        XCTAssertEqual(session.heldBackBlocks, 3)
    }

    // MARK: the effect of a withdrawal

    func testTheDeleteEffectDeletesTheRecordOfThatContactThroughTheServices() throws {
        let fake = try services()
        let listener = VoiceSessionEffectListener(contactId: "contact-9", services: fake)
        listener.onEffect(5, .deleteRecord)
        XCTAssertEqual(fake.deletes, ["contact-9"])
    }

    // MARK: the busy time of the other models

    func testTheOtherModelsReportTheirBusyTimeToTheBudgetOfTheEngineWhenTheCheckIsOn() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = VoiceProcess(services: fake)
        _ = process.services.prepare() // the budget exists once a call prepared the check
        let budget = try XCTUnwrap(fake.budget)
        XCTAssertEqual(budget.total(100), 0)
        process.reportBusy(who: "guardian", startNs: 10, endNs: 60)
        XCTAssertEqual(budget.total(100), 50)
    }
}

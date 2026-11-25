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
        var released = 0
        var wipes = 0
        var wipeFails = false
        var staleUpdates = 0
        var threadsWereBackground = true
        var record: TemplateRecord?
        private(set) var budget: VoiceCpuBudget?
        private var generationValue = 0

        var generation: Int {
            lock.lock()
            defer { lock.unlock() }
            return generationValue
        }

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
            return VoicePrepared(config: config, vad: StubVad(), embedder: StubEmbedder(), model: .ok, release: { [self] in
                lock.lock()
                released += 1
                lock.unlock()
            })
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

        func update(contactId: String, cfg: VoiceStateConstants, generation expected: Int,
                    _ body: (TemplateRecord?) throws -> TemplateRecord?) throws {
            lock.lock()
            defer { lock.unlock() }
            note()
            guard generationValue == expected else {
                staleUpdates += 1
                throw VoiceStaleCall()
            }
            _ = try body(record)
            updates.append(contactId)
        }

        func wipeAll() throws {
            lock.lock()
            defer { lock.unlock() }
            generationValue += 1
            wipes += 1
            if wipeFails { throw VoiceStoreError(.io, "records left") }
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
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
        let process = processWithMemoryCounters(fake)
        _ = process.services.prepare() // the budget exists once a call prepared the check
        let budget = try XCTUnwrap(fake.budget)
        XCTAssertEqual(budget.total(100), 0)
        process.reportBusy(who: "guardian", startNs: 10, endNs: 60)
        XCTAssertEqual(budget.total(100), 50)
    }

    // MARK: the log

    private final class MemoryDaily: VoiceDailyStorage {
        var data: Data?
        func load() -> Data? { data }
        func save(_ newData: Data) { data = newData }
        func clear() { data = nil }
    }

    private func processWithMemoryCounters(_ fake: FakeServices) -> VoiceProcess {
        VoiceProcess(services: fake, daily: VoiceDailyCounters(storage: MemoryDaily(), random: { 0 }))
    }

    func testPerCallLinesAreWrittenOnlyForAnAccountWithTheDiagnosticFlagAndDailyLinesAlways() throws {
        let process = processWithMemoryCounters(try services())
        var lines: [String] = []
        var diag = false
        process.setLogging(sink: { lines.append($0) }, diagLinesEnabled: { diag })
        process.emitCallLine("QA-VOICE v=1 ev=cstate call=0a1b2c3d st=lrn")
        XCTAssertTrue(lines.isEmpty, "no diagnostic flag: no per-call line")
        diag = true
        process.emitCallLine("QA-VOICE v=1 ev=cstate call=0a1b2c3d st=lrn")
        XCTAssertEqual(lines.count, 1)
        diag = false
        process.emitDailyLine("QA-VOICE v=1 ev=day calls=0")
        XCTAssertEqual(lines.count, 2, "the id-free daily counters do not depend on the flag")
    }

    func testTheLinesOfACallCarryNoContactAndTheCardFollowsTheStateAndEndsEmpty() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = processWithMemoryCounters(fake)
        var lines: [String] = []
        var displays: [VoiceCheckDisplay?] = []
        process.setLogging(sink: { lines.append($0) }, diagLinesEnabled: { true })
        process.setDisplayHandler { displays.append($0) }
        let session = try XCTUnwrap(process.beginCall(binding(contact: "alice-contact-id")))
        session.mediaStart()
        session.queue.sync {}
        session.callEnded()
        session.queue.sync {}
        XCTAssertTrue(lines.contains { $0.hasPrefix("QA-VOICE v=1 ev=start call=11111111 ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("QA-VOICE v=1 ev=end call=11111111 ") })
        for line in lines {
            XCTAssertTrue(line.hasPrefix("QA-VOICE v=1 ev="), line)
            XCTAssertFalse(line.lowercased().contains("alice"), "no contact id in a line: \(line)")
            XCTAssertFalse(line.contains("11111111-2222"), "only the first eight characters of the call id: \(line)")
        }
        XCTAssertFalse(displays.isEmpty)
        if case .some(.some(let first)) = displays.first {
            XCTAssertEqual(first, .learning, "a contact without a record is being learned")
        } else {
            XCTFail("the first state of the card is a state")
        }
        if case .some(.none) = displays.last {} else { XCTFail("nothing is shown after the call") }
    }

    func testTheDailyCountersOfACallAreWrittenWhenTheirDayIsOverAndDue() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = processWithMemoryCounters(fake)
        let session = try XCTUnwrap(process.beginCall(binding(contact: "alice-contact-id")))
        session.mediaStart()
        session.queue.sync {}
        session.callEnded()
        session.queue.sync {}
        let now = Int(Date().timeIntervalSince1970)
        XCTAssertTrue(process.daily.dueLines(nowS: now, utcOffsetS: 0).isEmpty, "a day is written after it is over")
        let later = process.daily.dueLines(nowS: now + 3 * 86_400, utcOffsetS: 0)
        XCTAssertEqual(later.count, 5, "one day line and four strata")
        XCTAssertTrue(later[0].contains(" lrn=1 "), later[0])
        XCTAssertFalse(later.joined().lowercased().contains("alice"))
    }

    // MARK: the wipe, the deletion and the generation

    func testAWipeStopsEveryLiveSessionAndNothingOfThemIsWrittenAfterIt() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = processWithMemoryCounters(fake)
        let session = try XCTUnwrap(process.beginCall(binding()))
        session.mediaStart()
        session.queue.sync {}
        XCTAssertTrue(process.hasLiveSession)
        XCTAssertTrue(process.wipeAll())
        session.queue.sync {}
        session.callEnded() // the call ends later: the engine is gone and nothing is written
        session.queue.sync {}
        XCTAssertEqual(fake.wipes, 1)
        XCTAssertTrue(fake.updates.isEmpty)
        XCTAssertEqual(fake.finished, 1)
        XCTAssertEqual(fake.released, 1, "the speech model session goes back")
        XCTAssertFalse(process.hasLiveSession)
    }

    func testAWipeThatFailsIsReportedAsAFailure() throws {
        let fake = try services()
        fake.wipeFails = true
        let process = processWithMemoryCounters(fake)
        XCTAssertFalse(process.wipeAll())
        XCTAssertEqual(fake.wipes, 1)
    }

    func testACallThatFinishesAfterAWipeOfAnotherPathWritesNothingBecauseTheGenerationMovedOn() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = processWithMemoryCounters(fake)
        let session = try XCTUnwrap(process.beginCall(binding()))
        session.mediaStart()
        session.queue.sync {}
        try fake.wipeAll() // a wipe that did not go through the process: only the generation tells the call
        session.callEnded()
        session.queue.sync {}
        XCTAssertEqual(fake.staleUpdates, 1, "refused inside the lock of the store")
        XCTAssertTrue(fake.updates.isEmpty)
    }

    func testDeletingAContactDiscardsTheResultOfItsRunningCallAndDeletesItsRecord() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = processWithMemoryCounters(fake)
        let session = try XCTUnwrap(process.beginCall(binding(contact: "Contact-1")))
        session.mediaStart()
        session.queue.sync {}
        let done = expectation(description: "deleted")
        var ok = false
        process.forgetContact("contact-1") { result in
            ok = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.deletes, ["contact-1"])
        session.callEnded()
        session.queue.sync {}
        XCTAssertTrue(fake.updates.isEmpty, "the call with a deleted contact writes no record")
    }

    func testDeletingAContactWorksBeforeAnyCallOfTheProcess() throws {
        let fake = try services()
        let process = processWithMemoryCounters(fake)
        let done = expectation(description: "deleted")
        process.forgetContact("contact-7") { _ in done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(fake.deletes, ["contact-7"])
        XCTAssertEqual(fake.prepareCalls, 0, "no model is loaded for a deletion")
    }

    // MARK: hold

    func testOnlyAChangeOfTheHoldReachesTheEngine() throws {
        VoiceFeature.setProvider { true }
        let fake = try services()
        let process = processWithMemoryCounters(fake)
        let (session, _) = makeSession(fake, process)
        session.mediaStart()
        session.queue.sync {}
        session.holdChanged(false)
        session.holdChanged(true)
        session.holdChanged(true)
        session.holdChanged(false)
        session.queue.sync {}
        XCTAssertEqual(session.holdEventsFed, 2)
    }

    // MARK: the card

    func testEachStateOfTheMachineHasItsOwnStateOfTheCard() {
        XCTAssertEqual(VoiceCheckDisplay(shown: .matches, detail: nil), .matches)
        XCTAssertEqual(VoiceCheckDisplay(shown: .checking, detail: nil), .checking)
        XCTAssertEqual(VoiceCheckDisplay(shown: .checking, detail: .differentSetup), .checkingDifferentSetup)
        XCTAssertEqual(VoiceCheckDisplay(shown: .differs, detail: nil), .differs)
        XCTAssertEqual(VoiceCheckDisplay(shown: .differs, detail: .deviceNew), .differsNewDevice)
        XCTAssertEqual(VoiceCheckDisplay(shown: .off, detail: nil), .off)
        XCTAssertEqual(VoiceCheckDisplay(shown: .cannotVerify, detail: .audio), .cannotVerify)
        XCTAssertEqual(VoiceCheckDisplay(shown: .learning, detail: nil), .learning)
        XCTAssertEqual(VoiceCheckDisplay(shown: .changed, detail: nil), .changed)
    }
}

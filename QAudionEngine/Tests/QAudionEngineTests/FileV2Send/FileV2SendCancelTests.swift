import XCTest
@testable import QAudionEngine

/// Cancel: the workers stop promptly, the object is deleted (404 is success), the state is wiped, the key and the token are destroyed, and
/// nothing else is sent. A cancelled transfer leaves no journal and no token behind. Cancelling the TASK (the app is going away) is not
/// cancelling the TRANSFER: its state stays and it can be resumed.
final class FileV2SendCancelTests: XCTestCase {

    private let manyParts: UInt64 = 6 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 5

    func testCancelInTheMiddleOfAnUploadStopsTheWorkersDeletesTheObjectAndLeavesNothing() async throws {
        let rig = try SendRig(self)
        rig.fake.injectDelay(.putPart, ms: 150)                                // real time: the uploads are in flight when we cancel
        let source = GeneratedSource(size: manyParts)
        let pipeline = try rig.makePipeline()
        let collector = StateCollector()
        let sending = Task { await pipeline.send(rig.makeRequest(source, id: "cancel-me"), onState: collector.sink) }
        try await waitUntil { rig.server.puts.count >= 2 }

        let started = Date()
        let existed = await pipeline.cancel(transferID: "cancel-me")
        XCTAssertTrue(existed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the workers stop promptly")

        let result = await sending.value
        XCTAssertEqual(result, .failed(FileV2SendFailure(.cancelled)))
        XCTAssertEqual(collector.states.last, result)
        XCTAssertEqual(rig.fake.objectCount, 0, "the object is deleted")
        XCTAssertTrue(rig.fake.calls.contains { $0.op == .delete })
        try rig.assertNothingIsLeftBehind()

        // Nothing else is sent: no descriptor, no cancel message (none had gone out), no PUT after the cancel returned.
        XCTAssertTrue(rig.channel.announced.isEmpty)
        XCTAssertTrue(rig.channel.controls.isEmpty, "a descriptor never went out, so the receiver is not told anything")
        let putsAtCancel = rig.server.puts.count
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(rig.server.puts.count, putsAtCancel, "no worker is still uploading")
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .complete }.count, 0)
        XCTAssertEqual(rig.telemetry.count { $0 == .finished(code: "cancelled") }, 1)
        let diagnostics = pipeline.diagnostics
        XCTAssertGreaterThanOrEqual(diagnostics.peakConcurrentParts, 2, "it really was uploading in parallel")
    }

    /// The encryptor of every run, kept so a test can look at its key after the run.
    private final class Encryptors: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [FileV2Encryptor] = []

        func add(_ encryptor: FileV2Encryptor) {
            lock.lock()
            all.append(encryptor)
            lock.unlock()
        }

        var list: [FileV2Encryptor] {
            lock.lock()
            defer { lock.unlock() }
            return all
        }
    }

    func testTheKeyMaterialIsZeroedWhenARunEndsWhateverTheWayItEnds() async throws {
        // sent
        let rig = try SendRig(self)
        let sentKeys = Encryptors()
        let pipeline = try rig.makePipeline()
        pipeline.context.encryptorObserver = { sentKeys.add($0) }
        let sentResult = await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000)))
        XCTAssertEqual(sentResult, .sentOk)
        XCTAssertEqual(sentKeys.list.count, 1)
        XCTAssertTrue(sentKeys.list.allSatisfy { $0.fileKey.isEmpty }, "zeroed after a send")

        // cancelled by the user, in the middle of an upload
        let cancelRig = try SendRig(self)
        cancelRig.fake.injectDelay(.putPart, ms: 150)
        let cancelKeys = Encryptors()
        let cancelPipeline = try cancelRig.makePipeline()
        cancelPipeline.context.encryptorObserver = { cancelKeys.add($0) }
        let sending = Task { await cancelPipeline.send(cancelRig.makeRequest(GeneratedSource(size: manyParts), id: "zero-cancel")) }
        try await waitUntil { cancelRig.server.puts.count >= 1 }
        _ = await cancelPipeline.cancel(transferID: "zero-cancel")
        _ = await sending.value
        XCTAssertEqual(cancelKeys.list.count, 1)
        XCTAssertTrue(cancelKeys.list.allSatisfy { $0.fileKey.isEmpty }, "zeroed after a cancel")

        // interrupted
        let intRig = try SendRig(self)
        intRig.fake.injectDelay(.putPart, ms: 150)
        let intKeys = Encryptors()
        let intPipeline = try intRig.makePipeline()
        intPipeline.context.encryptorObserver = { intKeys.add($0) }
        let running = Task { await intPipeline.send(intRig.makeRequest(GeneratedSource(size: manyParts), id: "zero-interrupt")) }
        try await waitUntil { intRig.server.puts.count >= 1 }
        running.cancel()
        _ = await running.value
        XCTAssertTrue(intKeys.list.allSatisfy { $0.fileKey.isEmpty }, "zeroed after an interruption: a resume reads the key again from the secure store")

        // the content changed
        let changedRig = try SendRig(self)
        changedRig.fake.maxPartsInFlight = 1
        let changedKeys = Encryptors()
        let changedSource = GeneratedSource(size: SendTestSizes.threeParts)
        changedRig.server.setHook { op, call in if op == .putPart && call == 1 { changedSource.touch() } }
        let changedPipeline = try changedRig.makePipeline()
        changedPipeline.context.encryptorObserver = { changedKeys.add($0) }
        let changedResult = await changedPipeline.send(changedRig.makeRequest(changedSource))
        assertFailure(changedResult, .sourceChanged)
        XCTAssertTrue(changedKeys.list.allSatisfy { $0.fileKey.isEmpty }, "zeroed after a source change")
    }

    func testCancelOfATransferThatOnlyHasStateDeletesItsObjectAndWipesIt() async throws {
        let rig = try SendRig(self)
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
        let paused = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "paused"))
        assertFailure(paused, .network)
        XCTAssertEqual(rig.fake.objectCount, 1)

        let restarted = try rig.makePipeline()
        let existed = await restarted.cancel(transferID: "paused")
        XCTAssertTrue(existed)
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
        let again = await restarted.cancel(transferID: "paused")
        XCTAssertFalse(again, "nothing left to cancel")
    }

    func testCancelOfAnUnknownTransferIsFalseAndHarmless() async throws {
        let rig = try SendRig(self)
        let pipeline = try rig.makePipeline()
        let unknown = await pipeline.cancel(transferID: "no-such-transfer")
        XCTAssertFalse(unknown)
        let invalid = await pipeline.cancel(transferID: "../../etc")
        XCTAssertFalse(invalid)
        XCTAssertEqual(rig.fake.calls.count, 0)
    }

    func testADeleteThatIsAlreadyDoneByTheServerIsASuccess() async throws {
        let rig = try SendRig(self)
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "gone-already"))
        // The server's clean-up took the object while the transfer was paused.
        rig.clock.advance(ms: 25 * 3_600_000)
        rig.fake.cleanup()
        XCTAssertEqual(rig.fake.objectCount, 0)
        let existed = await (try rig.makePipeline()).cancel(transferID: "gone-already")
        XCTAssertTrue(existed)
        try rig.assertNothingIsLeftBehind()
    }

    func testCancelDuringTheHandoverOfTheDescriptorTellsTheReceiverAndDeletesTheObject() async throws {
        let rig = try SendRig(self)
        rig.channel.setHangs(true)
        let source = GeneratedSource(size: 700_000)
        let pipeline = try rig.makePipeline()
        let sending = Task { await pipeline.send(rig.makeRequest(source, id: "cancel-handover")) }
        try await waitUntil { !rig.channel.announced.isEmpty }
        let descriptor = try FileV2Descriptor.parse(rig.channel.announced[0].body)

        let existed = await pipeline.cancel(transferID: "cancel-handover")
        XCTAssertTrue(existed)
        let result = await sending.value
        XCTAssertEqual(result, .failed(FileV2SendFailure(.cancelled)))
        XCTAssertEqual(rig.channel.controls.count, 1, "the descriptor may have gone out: qa_file_cancel follows it")
        guard case .cancel(let message) = FileV2Message.recognize(try XCTUnwrap(rig.channel.controls.first).body) else {
            return XCTFail("not a cancel message")
        }
        XCTAssertEqual(message.fileID, descriptor.fileID)
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testCancellingTheTaskIsAnInterruptionTheStateIsKeptAndTheTransferResumes() async throws {
        let rig = try SendRig(self)
        rig.fake.injectDelay(.putPart, ms: 100)
        let source = GeneratedSource(size: manyParts)
        let pipeline = try rig.makePipeline()
        let sending = Task { await pipeline.send(rig.makeRequest(source, id: "interrupted")) }
        try await waitUntil { rig.server.puts.count >= 2 }
        sending.cancel()                                                        // the app is going away: not the user's cancel
        let result = await sending.value
        XCTAssertEqual(result, .interrupted)
        XCTAssertEqual(try rig.journalNames(), ["interrupted.qsj"], "the journal stays")
        XCTAssertEqual(rig.wrapper.count, 2, "and the key and the token")
        XCTAssertFalse(rig.fake.calls.contains { $0.op == .delete }, "the object is not deleted")
        XCTAssertTrue(rig.channel.announced.isEmpty)

        rig.fake.clearDelays()
        let resumed = await (try rig.makePipeline()).resume(transferID: "interrupted")
        XCTAssertEqual(resumed, .sentOk)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
        try rig.assertNothingIsLeftBehind()
    }

    func testCancelAfterTheTransferEndedWithASentDescriptorHasNothingToCancel() async throws {
        let rig = try SendRig(self)
        let pipeline = try rig.makePipeline()
        let result = await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000), id: "done"))
        XCTAssertEqual(result, .sentOk)
        let existed = await pipeline.cancel(transferID: "done")
        XCTAssertFalse(existed, "the state is gone, the descriptor is out, and the object stays for the recipients")
        XCTAssertEqual(rig.fake.objectCount, 1)
    }

    func testRecoverOnLaunchFinishesACancelThatWasInterruptedAndDestroysSecretsNobodyRefersTo() async throws {
        let rig = try SendRig(self)
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "half-cancelled"))
        // The app died in the middle of a cancel: the journal says "cancelled" and nothing else happened.
        try rig.makeStore().inner.append(.phase(.cancelled), to: "half-cancelled")
        // And a crash between the wrapping of a key and its begin record left a secret no journal names.
        _ = try rig.wrapper.wrap(Data(repeating: 1, count: 32))
        XCTAssertEqual(rig.wrapper.count, 3)

        let restarted = try rig.makePipeline()
        await restarted.recoverOnLaunch()
        XCTAssertEqual(rig.fake.objectCount, 0, "the cancel was finished")
        try rig.assertNothingIsLeftBehind()

        // A transfer in the cancelled phase is not resumed: it is finished and reported as cancelled.
        rig.channel.setOutcomes([.unavailable])                                  // its descriptor is not taken, so its state stays
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "second"))
        try rig.makeStore().inner.append(.phase(.cancelled), to: "second")
        let result = await (try rig.makePipeline()).resume(transferID: "second")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.cancelled)))
    }

    func testRecoverOnLaunchKeepsTheSecretsOfTransfersThatHaveState() async throws {
        let rig = try SendRig(self)
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "kept"))
        XCTAssertEqual(rig.wrapper.count, 2)
        await (try rig.makePipeline()).recoverOnLaunch()
        XCTAssertEqual(rig.wrapper.count, 2, "the key and the token of a journal are not orphans")
        let resumed = await (try rig.makePipeline()).resume(transferID: "kept")
        XCTAssertEqual(resumed, .sentOk)
    }
}

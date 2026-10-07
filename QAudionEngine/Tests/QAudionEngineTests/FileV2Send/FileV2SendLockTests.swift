import XCTest
@testable import QAudionEngine

/// ONE WRITER PER TRANSFER. Two holders of one transfer (two pipelines of a process, or the app and an extension of its App Group) would each
/// build a ledger of tags that lacks what the other sealed, and could seal one chunk from two versions of a file under one nonce
/// (WIRE_SPEC 12.8 rule 2). The store's exclusive lock, taken before the journal is read and kept until the operation has ended, is what
/// makes "one run per transfer" true across instances and across processes. Two file descriptors of one process conflict under `flock` exactly
/// as two processes do, which is what these tests use.
final class FileV2SendLockTests: XCTestCase {

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        return rig
    }

    private func makeStores() throws -> (FileV2FileSendStore, FileV2FileSendStore, URL) {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self).appendingPathComponent("send", isDirectory: true)
        return (try FileV2FileSendStore(directory: directory, durability: NoopDurability()),
                try FileV2FileSendStore(directory: directory, durability: NoopDurability()), directory)
    }

    private func names(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: The store's lock

    func testASecondHolderOfATransferIsRefusedAtOnceWhetherItIsAnotherInstanceOrTheSameOne() throws {
        let (first, second, _) = try makeStores()
        let held = try first.acquireLock("transfer-a")
        XCTAssertThrowsError(try second.acquireLock("transfer-a")) { XCTAssertEqual($0 as? FileV2SendStoreError, .busy) }
        XCTAssertThrowsError(try first.acquireLock("transfer-a"), "not even the instance that holds it may take it twice") {
            XCTAssertEqual($0 as? FileV2SendStoreError, .busy)
        }
        held.release()
        let again = try second.acquireLock("transfer-a")
        again.release()
    }

    func testTheLockIsPerTransferAndAnIdThatCouldBuildAPathHasNone() throws {
        let (first, second, _) = try makeStores()
        let one = try first.acquireLock("transfer-a")
        let two = try second.acquireLock("transfer-b")
        one.release()
        two.release()
        for bad in ["", "../escape", "a/b", "A-UPPER", "dot.dot", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try first.acquireLock(bad), bad.debugDescription) {
                XCTAssertEqual($0 as? FileV2SendStoreError, .invalidIdentifier)
            }
        }
    }

    func testReleasingTwiceIsHarmlessAndALockThatIsDroppedWithoutReleaseGivesItselfUp() throws {
        let (first, second, _) = try makeStores()
        let held = try first.acquireLock("transfer-a")
        held.release()
        held.release()
        let reacquired = try second.acquireLock("transfer-a")
        reacquired.release()

        do {
            let dropped = try first.acquireLock("transfer-a")
            XCTAssertThrowsError(try second.acquireLock("transfer-a"), "held while the object lives")
            _ = dropped
        }
        // The object went out of scope: its deinit released the lock.
        XCTAssertNoThrow(try second.acquireLock("transfer-a").release())
    }

    func testReleasingRemovesTheLockFileSoTheDirectoryIsEmptyAgain() throws {
        let (first, _, directory) = try makeStores()
        let held = try first.acquireLock("transfer-a")
        XCTAssertEqual(try names(directory), ["transfer-a.lock"], "an empty file, nothing else")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transfer-a.lock")), Data())
        held.release()
        XCTAssertEqual(try names(directory), [])
    }

    func testALockFileNobodyHoldsIsTheLeftoverOfAProcessThatDiedAndTheListingRemovesIt() throws {
        let (first, second, directory) = try makeStores()
        // A process that died holding the lock left its file; the kernel released the lock with it.
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent("dead-process.lock").path, contents: nil))
        let held = try first.acquireLock("live-transfer")
        XCTAssertEqual(try second.listTransferIDs(), [])
        XCTAssertEqual(try names(directory), ["live-transfer.lock"], "the stale file is gone and the HELD one is left alone")
        XCTAssertThrowsError(try second.acquireLock("live-transfer")) { XCTAssertEqual($0 as? FileV2SendStoreError, .busy) }
        held.release()
    }

    func testManyThreadsRacingForOneTransferHaveExactlyOneWinner() throws {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self).appendingPathComponent("send", isDirectory: true)
        let racers = 16
        let results = FileV2Locked<[FileV2SendTransferLock]>([])
        let busy = FileV2Locked(0)
        let group = DispatchGroup()
        for _ in 0..<racers {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                guard let store = try? FileV2FileSendStore(directory: directory, durability: NoopDurability()) else { return }
                do {
                    let lock = try store.acquireLock("contested")
                    results.withValue { $0.append(lock) }
                } catch FileV2SendStoreError.busy {
                    busy.withValue { $0 += 1 }
                } catch {
                    XCTFail("unexpected \(error)")
                }
            }
        }
        group.wait()
        XCTAssertEqual(results.withValue { $0.count }, 1, "one winner")
        XCTAssertEqual(busy.withValue { $0 }, racers - 1, "everyone else is told busy, and nobody waits")
        results.withValue { $0.forEach { $0.release() } }
    }

    func testTheLockStaysExclusiveWhileHoldersComeAndGoAtFullSpeed() throws {
        // Each holder unlinks the lock file as it leaves. A competitor that opened the old name must not end up holding a lock on a file
        // nobody can find while another one holds the new file of the same name.
        let directory = try FileV2TestSupport.makeTempDirectory(for: self).appendingPathComponent("send", isDirectory: true)
        let inside = FileV2Locked(0)
        let violations = FileV2Locked(0)
        let acquisitions = FileV2Locked(0)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                guard let store = try? FileV2FileSendStore(directory: directory, durability: NoopDurability()) else { return }
                for _ in 0..<250 {
                    guard let lock = try? store.acquireLock("churn") else { continue }
                    let others = inside.withValue { value -> Int in
                        value += 1
                        return value
                    }
                    if others != 1 { violations.withValue { $0 += 1 } }
                    acquisitions.withValue { $0 += 1 }
                    inside.withValue { $0 -= 1 }
                    lock.release()
                }
            }
        }
        group.wait()
        XCTAssertEqual(violations.withValue { $0 }, 0, "two holders at once")
        XCTAssertGreaterThan(acquisitions.withValue { $0 }, 0)
        XCTAssertEqual(try names(directory), [], "no lock file is left")
    }

    // MARK: The pipeline's use of it

    /// The review's probe: two pipelines resume the same transfer over one store and the file changes between them (same size, same time).
    /// Pipeline A is slow at its first request and the file changes the moment its PUT of the last part begins, after A sealed that part's
    /// chunk and before anyone else could. B must be refused at once, must not read the journal, and no chunk may ever be transmitted
    /// with two different tags.
    func testTwoPipelinesResumingTheSameTransferNeverTransmitAChunkWithTwoTags() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let pristine = GeneratedSource(size: SendTestSizes.threeParts)
        let id = "two-writers"
        // The first process dies before the PUT of part 1: the journal holds the tags of chunks 0 to 15, part 0 is on the server.
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: id))
        XCTAssertEqual(first, .interrupted)
        rig.server.revive()

        rig.fake.injectDelay(.create, ms: 600)                                    // real time: A is parked at its first request
        rig.server.setHook { op, call in
            if op == .putPart && call == 1 { source.mutate(chunk: 16) }            // the file changes under A's PUT of part 2
        }
        let acquiredBefore = rig.log.events.filter { $0 == "lock.acquire" }.count
        let storeA = try rig.makeStore()
        let storeB = try rig.makeStore()
        let pipelineA = try rig.makePipeline(store: storeA)
        let pipelineB = try rig.makePipeline(store: storeB)
        let running = Task { await pipelineA.resume(transferID: id) }
        try await pollUntilTrue { rig.log.events.filter { $0 == "lock.acquire" }.count > acquiredBefore }

        let refused = await pipelineB.resume(transferID: id)
        assertSendFailure(refused, .busy)
        XCTAssertEqual(storeB.loadCount, 0, "B never read the journal: no ledger was built")
        XCTAssertTrue(rig.log.events.contains("lock.busy"))
        let cancelled = await pipelineB.cancelTransfer(transferID: id)
        XCTAssertEqual(cancelled, .busy, "and it cannot cancel what A runs either")

        let result = await running.value
        XCTAssertEqual(result, .sentOk)
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
        XCTAssertEqual(rig.fake.objectCount, 1, "A's object was not deleted by anyone")
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: pristine)
        try rig.assertNothingIsLeftBehind()
    }

    func testTheLockIsTakenBeforeTheJournalIsReadAndHeldUntilTheWholeRunHasEnded() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)

        // A new transfer: the lock before the begin record, the release after the very last thing the run does.
        let sent = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "ordered-send"))
        XCTAssertEqual(sent, .sentOk)
        var events = rig.log.events
        XCTAssertEqual(events.filter { $0 == "lock.acquire" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "lock.release" }.count, 1)
        let acquire = try XCTUnwrap(events.firstIndex(of: "lock.acquire"))
        let release = try XCTUnwrap(events.lastIndex(of: "lock.release"))
        XCTAssertLessThan(acquire, try XCTUnwrap(events.firstIndex(of: "journal.begin")))
        let lastWork = try XCTUnwrap(events.lastIndex {
            $0.hasPrefix("server.") || $0.hasPrefix("journal.") || $0.hasPrefix("fsync") || $0 == "channel.announce"
        })
        XCTAssertLessThan(lastWork, release, "the clean-up after the descriptor was taken is still under the lock")
        XCTAssertEqual(release, events.count - 1, "nothing of the run follows the release")

        // A resume: the lock before the journal is read (a rig of its own: the crash plan counts the calls of the server).
        let resumeRig = try sequentialRig()
        resumeRig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))
        _ = await (try resumeRig.makePipeline()).send(resumeRig.makeRequest(GeneratedSource(size: SendTestSizes.threeParts), id: "ordered-resume"))
        resumeRig.server.revive()
        resumeRig.log.clear()
        let resumed = await (try resumeRig.makePipeline()).resume(transferID: "ordered-resume")
        XCTAssertEqual(resumed, .sentOk)
        events = resumeRig.log.events
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "lock.acquire")), try XCTUnwrap(events.firstIndex(of: "journal.load")),
                          "the lock comes before the journal is read")
        let resumeRelease = try XCTUnwrap(events.lastIndex(of: "lock.release"))
        XCTAssertLessThan(try XCTUnwrap(events.lastIndex { $0.hasPrefix("server.") || $0.hasPrefix("journal.") || $0.hasPrefix("fsync") }),
                          resumeRelease)
        XCTAssertEqual(resumeRelease, events.count - 1)
    }

    /// Runs one way of ending an operation on a transfer of the id `end` and checks that every lock that was taken was given back.
    private func assertTheLockIsGivenBack(_ name: String, _ body: (SendRig) async throws -> Void) async throws {
        let rig = try sequentialRig()
        try await body(rig)
        let events = rig.log.events
        XCTAssertEqual(events.filter { $0 == "lock.acquire" }.count, events.filter { $0 == "lock.release" }.count,
                       "\(name): every lock that was taken was given back")
        let free = try rig.makeStore().acquireLock("end")
        free.release()
        XCTAssertEqual(try rig.journalNames().filter { $0.hasSuffix(".lock") }, [], "\(name): no lock file is left")
    }

    func testTheLockIsGivenUpOnEveryWayAnOperationCanEnd() async throws {
        let manyParts = 6 * UInt64(FileV2Wire.chunksPerPart) * UInt64(FileV2.chunkSize) + 5
        try await assertTheLockIsGivenBack("sent") { rig in
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "end"))
            XCTAssertEqual(result, .sentOk)
        }
        try await assertTheLockIsGivenBack("refused at the preflight") { rig in
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 0), id: "end"))
            assertSendFailure(result, .emptySource)
        }
        try await assertTheLockIsGivenBack("the chat cannot carry a descriptor") { rig in
            rig.channel.setCanCarry(false)
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "end"))
            assertSendFailure(result, .channelUnavailable)
        }
        try await assertTheLockIsGivenBack("a failure that keeps the state") { rig in
            rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "end"))
            assertSendFailure(result, .network)
        }
        try await assertTheLockIsGivenBack("a failure that ends the transfer") { rig in
            rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 409, code: "part_conflict"), times: 1)
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "end"))
            assertSendFailure(result, .sourceChanged)
        }
        try await assertTheLockIsGivenBack("the task was cancelled") { rig in
            rig.fake.injectDelay(.putPart, ms: 100)
            let pipeline = try rig.makePipeline()
            let request = rig.makeRequest(GeneratedSource(size: manyParts), id: "end")
            let sending = Task { await pipeline.send(request) }
            try await pollUntilTrue { rig.server.puts.count >= 1 }
            sending.cancel()
            let result = await sending.value
            XCTAssertEqual(result, .interrupted)
        }
        try await assertTheLockIsGivenBack("the user cancelled") { rig in
            rig.fake.injectDelay(.putPart, ms: 100)
            let pipeline = try rig.makePipeline()
            let request = rig.makeRequest(GeneratedSource(size: manyParts), id: "end")
            let sending = Task { await pipeline.send(request) }
            try await pollUntilTrue { rig.server.puts.count >= 1 }
            let outcome = await pipeline.cancelTransfer(transferID: "end")
            XCTAssertEqual(outcome, .cancelled)
            let result = await sending.value
            XCTAssertEqual(result, .failed(FileV2SendFailure(.cancelled)))
        }
        try await assertTheLockIsGivenBack("a resume with no state") { rig in
            let result = await (try rig.makePipeline()).resume(transferID: "end")
            assertSendFailure(result, .stateLost)
        }
        try await assertTheLockIsGivenBack("a cancel of a transfer that only has state") { rig in
            rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
            _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "end"))
            let outcome = await (try rig.makePipeline()).cancelTransfer(transferID: "end")
            XCTAssertEqual(outcome, .cancelled)
        }
        try await assertTheLockIsGivenBack("a cancel with nothing to cancel") { rig in
            let outcome = await (try rig.makePipeline()).cancelTransfer(transferID: "end")
            XCTAssertEqual(outcome, .nothingToCancel)
        }
    }

    func testATransferAnotherHolderHasIsRefusedAndNothingOfItIsTouched() async throws {
        let rig = try sequentialRig()
        rig.channel.setOutcomes([.unavailable, .sent])
        let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "held"))
        assertSendFailure(first, .announceNotSent)
        XCTAssertEqual(rig.fake.objectCount, 1)
        XCTAssertEqual(rig.wrapper.count, 2)

        // Another process (the extension) holds the transfer.
        let other = try rig.makeStore().acquireLock("held")
        let pipeline = try rig.makePipeline()
        let calls = rig.fake.calls.count
        assertSendFailure(await pipeline.resume(transferID: "held"), .busy)
        assertSendFailure(await pipeline.send(rig.makeRequest(source, id: "held")), .busy)
        let outcome = await pipeline.cancelTransfer(transferID: "held")
        XCTAssertEqual(outcome, .busy)
        let simple = await pipeline.cancel(transferID: "held")
        XCTAssertFalse(simple)
        XCTAssertEqual(rig.fake.calls.count, calls, "the server was not called")
        XCTAssertEqual(rig.fake.objectCount, 1)
        XCTAssertEqual(rig.wrapper.count, 2, "the key and the token are still there")
        XCTAssertEqual(try rig.makeStore().load("held").phase, .announcePending)
        let listed = await pipeline.listResumable()
        XCTAssertEqual(listed.map { $0.transferID }, ["held"], "it is still listed: its state is intact")

        // The other holder is done: the transfer goes on from where it was.
        other.release()
        let resumed = await pipeline.resume(transferID: "held")
        XCTAssertEqual(resumed, .sentOk)
        try rig.assertNothingIsLeftBehind()
    }

    func testALaunchLeavesAHalfCancelledTransferAloneWhileAnotherHolderHasItAndFinishesItWhenItIsFree() async throws {
        let rig = try sequentialRig()
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "half"))
        try rig.makeStore().inner.append(.phase(.cancelled), to: "half")           // the app died in the middle of a cancel

        let other = try rig.makeStore().acquireLock("half")
        let ran = await (try rig.makePipeline()).recoverOnLaunch()
        XCTAssertTrue(ran, "the purge itself ran to its end: nothing is an orphan")
        XCTAssertEqual(rig.fake.objectCount, 1, "the holder's transfer was not cleaned up under it")
        XCTAssertEqual(try rig.journalNames().filter { $0.hasSuffix(".qsj") }, ["half.qsj"])
        XCTAssertEqual(rig.wrapper.count, 2)

        other.release()
        _ = await (try rig.makePipeline()).recoverOnLaunch()
        XCTAssertEqual(rig.fake.objectCount, 0, "now the cancel is finished")
        try rig.assertNothingIsLeftBehind()
    }

    func testTwoPipelinesOverOneStoreRunDifferentTransfersAtTheSameTime() async throws {
        let rig = try SendRig(self)
        let one = GeneratedSource(size: SendTestSizes.oneChunkOver)
        let two = GeneratedSource(size: SendTestSizes.oneChunkOver)
        let pipelineA = try rig.makePipeline()
        let pipelineB = try rig.makePipeline()
        let requestA = rig.makeRequest(one, id: "transfer-one")
        let requestB = rig.makeRequest(two, id: "transfer-two")
        async let a = pipelineA.send(requestA)
        async let b = pipelineB.send(requestB)
        let (resultA, resultB) = await (a, b)
        XCTAssertEqual(resultA, .sentOk)
        XCTAssertEqual(resultB, .sentOk)
        try rig.assertNothingIsLeftBehind()
    }

    func testTheSamePipelineStillRefusesTheSameTransferTwiceBeforeItTouchesTheStore() async throws {
        let rig = try SendRig(self)
        rig.fake.injectDelay(.create, ms: 300)
        let source = GeneratedSource(size: 700_000)
        let pipeline = try rig.makePipeline()
        let running = Task { await pipeline.send(rig.makeRequest(source, id: "twice")) }
        try await pollUntilTrue { rig.log.events.contains("lock.acquire") }
        let second = await pipeline.send(rig.makeRequest(source, id: "twice"))
        assertSendFailure(second, .alreadyRunning)
        XCTAssertEqual(rig.log.events.filter { $0 == "lock.acquire" }.count, 1, "the registry refused it: the store was not asked")
        let result = await running.value
        XCTAssertEqual(result, .sentOk)
    }

    /// A cancel that arrives while a send is being admitted must find a transfer it can cancel completely, or find nothing and take the
    /// lock itself: never half a transfer. Whatever the interleaving, nothing is left behind, and a cancel that says it cancelled is
    /// matched by a send that says so.
    func testACancelThatRacesTheStartOfASendNeverLeavesHalfATransfer() async throws {
        for round in 0..<30 {
            let rig = try SendRig(self)
            let pipeline = try rig.makePipeline()
            let id = "race-\(round)"
            let request = rig.makeRequest(GeneratedSource(size: 700_000), id: id)
            let sending = Task { await pipeline.send(request) }
            if round % 3 == 1 { await Task.yield() }
            if round % 3 == 2 { try await Task.sleep(nanoseconds: 300_000) }
            let outcome = await pipeline.cancelTransfer(transferID: id)
            let result = await sending.value
            switch outcome {
            case .cancelled:
                XCTAssertEqual(result, .failed(FileV2SendFailure(.cancelled)), "round \(round)")
                XCTAssertEqual(rig.fake.objectCount, 0, "round \(round)")
            case .nothingToCancel, .busy:
                XCTAssertTrue(result == .sentOk || result == .failed(FileV2SendFailure(.busy)), "round \(round): \(result)")
            case .storageUnavailable:
                XCTFail("round \(round)")
            }
            try rig.assertNothingIsLeftBehind()
            let free = try rig.makeStore().acquireLock(id)
            free.release()
        }
    }
}

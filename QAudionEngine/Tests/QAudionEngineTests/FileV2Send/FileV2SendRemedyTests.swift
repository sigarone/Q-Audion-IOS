import XCTest
@testable import QAudionEngine

/// The user-remedy flow: an account at its limit of unfinished uploads (or objects, or its quota) cannot create an object, and waiting does
/// not help. The pipeline lists the account's unfinished objects, deletes ONLY the ones that no local journal knows (the orphans of lost
/// state) and that have been idle for a while, and repeats the create ONCE. It never calls the bulk delete, which would also delete the
/// transfers that are running, the ones paused in a journal and the live uploads of the account's other devices.
final class FileV2SendRemedyTests: XCTestCase {

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        return rig
    }

    /// An object of the account that no journal of this device knows: what a reinstall or a wiped app leaves behind.
    @discardableResult
    private func makeOrphan(_ rig: SendRig, length: Int64 = 70_000) async throws -> String {
        var head = Data(count: 64)
        for index in 0..<head.count { head[index] = UInt8.random(in: 0...255) }
        let created = try await rig.fake.create(FileV2CreateRequest(blobLength: length, head: head))
        return created.obj
    }

    private func unfinishedObjects(_ rig: SendRig) async throws -> [String] {
        let page = try await rig.fake.listUnfinished(limit: 100, after: nil)
        return page.objects.map { $0.obj }
    }

    /// A transfer of this device that holds a slot: it crashed in the middle of its upload, so its journal names its object.
    private func makeJournaledTransfer(_ rig: SendRig, id: String) async throws -> String {
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 0, applyEffect: false))
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: SendTestSizes.threeParts), id: id))
        rig.server.revive()
        return try XCTUnwrap(try rig.makeStore().load(id).object?.obj)
    }

    func testTooManyUploadsDeletesOnlyTheIdleOrphansKeepsTheJournaledObjectAndRepeatsTheCreateOnce() async throws {
        let rig = try sequentialRig()
        rig.fake.maxIncomplete = 3
        let known = try await makeJournaledTransfer(rig, id: "paused-here")
        let orphan1 = try await makeOrphan(rig)
        let orphan2 = try await makeOrphan(rig)
        let all = try await unfinishedObjects(rig)
        XCTAssertEqual(Set(all), Set([known, orphan1, orphan2]), "the account is at its limit of 3")
        rig.clock.advance(ms: 11 * 60_000)                                   // the orphans have been idle for 11 minutes

        let source = GeneratedSource(size: 900_000)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "new-one"))
        XCTAssertEqual(result, .sentOk)

        let ops = rig.fake.calls.map { $0.op }
        let remaining = try await unfinishedObjects(rig)
        XCTAssertTrue(remaining.contains(known), "the object of a journal is never touched")
        XCTAssertFalse(remaining.contains(orphan1))
        XCTAssertFalse(remaining.contains(orphan2))
        XCTAssertFalse(ops.contains(.deleteUnfinished), "never the bulk delete")
        XCTAssertEqual(ops.filter { $0 == .listUnfinished }.count, 2, "one listing for the sweep (the other is this test's)")
        XCTAssertEqual(ops.filter { $0 == .delete }.count, 2, "one delete for each orphan")
        XCTAssertEqual(rig.telemetry.count { $0 == .orphansDeleted(count: 2) }, 1)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    func testOrphansThatAreNotIdleYetAreKeptAndTheUserIsToldToFreeSomething() async throws {
        let rig = try sequentialRig()
        rig.fake.maxIncomplete = 2
        let first = try await makeOrphan(rig)
        let second = try await makeOrphan(rig)
        rig.clock.advance(ms: 5 * 60_000)                                    // only 5 minutes: they may be live uploads of another device

        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 900_000), id: "refused"))
        let failure = assertFailure(result, .userRemedy, code: "too_many_uploads")
        XCTAssertEqual(failure?.transferError, .quota)
        XCTAssertEqual(failure?.details?.limit, 2, "the number the user interface shows")
        let remaining = try await unfinishedObjects(rig)
        XCTAssertEqual(Set(remaining), Set([first, second]), "nothing was deleted")
        XCTAssertEqual(rig.server.callCount(.create), 1, "no retry when nothing was freed")
        try rig.assertNothingIsLeftBehind()
    }

    func testTheCreateIsRepeatedOnlyOnceEvenWhenTheServerRefusesAgain() async throws {
        let rig = try sequentialRig()
        let orphan = try await makeOrphan(rig)
        rig.clock.advance(ms: 11 * 60_000)
        // The server refuses twice in a row (the injected answers stand for another upload taking the slot that was freed).
        rig.fake.injectFailure(.create, error: FileV2ServerError(status: 429, code: "too_many_uploads", retryAfter: 30,
                                                                  details: FileV2ErrorDetails(limit: 10)), times: 2)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 900_000)))
        assertFailure(result, .userRemedy, code: "too_many_uploads")
        XCTAssertEqual(rig.server.callCount(.create), 2, "the create and its single repeat")
        XCTAssertEqual(rig.server.callCount(.listUnfinished), 1, "one sweep")
        let remaining = try await unfinishedObjects(rig)
        XCTAssertFalse(remaining.contains(orphan))
        XCTAssertEqual(rig.sleeper.delays, [], "waiting is not what this answer asks for")
        try rig.assertNothingIsLeftBehind()
    }

    func testTooManyObjectsWithNoUnfinishedOrphanIsAVisibleErrorAndNeverAWait() async throws {
        let rig = try sequentialRig()
        rig.fake.maxObjects = 1
        // A completed object of the account holds the only slot: the sweep cannot (and must not) touch it.
        let created = try await rig.fake.create(FileV2CreateRequest(blobLength: 65, head: Data(repeating: 7, count: 64)))
        let byte = Data([1])
        _ = try await rig.fake.putPart(obj: created.obj, part: 0, body: byte, sha256: XferSupport.sha256(byte))
        try await rig.fake.complete(obj: created.obj)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 900_000)))
        assertFailure(result, .userRemedy, code: "too_many_objects")
        XCTAssertEqual(rig.sleeper.delays, [])
        XCTAssertEqual(rig.fake.objectCount, 1, "the completed object is still there")
        try rig.assertNothingIsLeftBehind()
    }

    func testAQuotaThatOrphansFillIsFreedAndTheCreateRepeated() async throws {
        let rig = try sequentialRig()
        rig.fake.quota = 1_000_000
        let orphan = try await makeOrphan(rig, length: 600_000)
        rig.clock.advance(ms: 11 * 60_000)
        let source = GeneratedSource(size: 700_000)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source))
        XCTAssertEqual(result, .sentOk)
        let remaining = try await unfinishedObjects(rig)
        XCTAssertFalse(remaining.contains(orphan))
    }

    func testAQuotaThatNothingCanFreeIsAVisibleQuotaErrorWithItsNumbers() async throws {
        let rig = try sequentialRig()
        rig.fake.quota = 100_000
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        let failure = assertFailure(result, .quota, code: "quota_exceeded")
        XCTAssertEqual(failure?.details?.limit, 100_000)
        try rig.assertNothingIsLeftBehind()
    }

    func testTheObjectsOfOtherJournalsAreNeverDeletedWhateverTheirAge() async throws {
        let rig = try sequentialRig()
        rig.fake.maxIncomplete = 2
        let known = try await makeJournaledTransfer(rig, id: "old-paused")
        let orphan = try await makeOrphan(rig)
        rig.clock.advance(ms: 20 * 3_600_000)                                 // twenty hours: far past any idle guard
        let deleted = try await (try rig.makePipeline()).discardOrphanedUploads(minIdleMs: 0)
        XCTAssertEqual(deleted, 1)
        let remaining = try await unfinishedObjects(rig)
        XCTAssertEqual(remaining, [known])
        XCTAssertFalse(remaining.contains(orphan))
    }

    func testTheExplicitDiscardWithNoIdleGuardTakesTheRecentOrphansToo() async throws {
        let rig = try sequentialRig()
        let recent = try await makeOrphan(rig)
        let pipeline = try rig.makePipeline()
        let guarded = try await pipeline.discardOrphanedUploads()
        XCTAssertEqual(guarded, 0, "recent: the default guard keeps it")
        let explicit = try await pipeline.discardOrphanedUploads(minIdleMs: 0)
        XCTAssertEqual(explicit, 1)
        let remaining = try await unfinishedObjects(rig)
        XCTAssertFalse(remaining.contains(recent))
    }

    func testAnOrphanSweepNeverMeetsAnObjectWhoseCreateAnsweredAndWhoseRecordIsNotJournalYet() async throws {
        // Two transfers of one pipeline create at once while an explicit sweep runs: the gate serialises each create with its journal write,
        // so the sweep never sees a live object of this process as an orphan.
        let rig = try SendRig(self)
        rig.fake.injectDelay(.create, ms: 20)
        let pipeline = try rig.makePipeline()
        let a = Task { await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000), id: "a")) }
        let b = Task { await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_001), id: "b")) }
        var deleted = 0
        for _ in 0..<5 { deleted += try await pipeline.discardOrphanedUploads(minIdleMs: 0) }
        let resultA = await a.value
        let resultB = await b.value
        XCTAssertEqual(resultA, .sentOk)
        XCTAssertEqual(resultB, .sentOk)
        XCTAssertEqual(deleted, 0, "no live object was taken for an orphan")
    }
}

/// The async gate: one holder at a time, in order, and a task cancelled while it waits never holds it.
final class FileV2AsyncGateTests: XCTestCase {

    func testSectionsNeverOverlapAndRunInOrder() async throws {
        let gate = FileV2AsyncGate()
        let state = FileV2Locked((inside: 0, maxInside: 0, order: [Int]()))
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? await gate.withGate {
                        state.withValue {
                            $0.inside += 1
                            $0.maxInside = max($0.maxInside, $0.inside)
                            $0.order.append(index)
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        state.withValue { $0.inside -= 1 }
                    }
                }
            }
        }
        let seen = state.withValue { $0 }
        XCTAssertEqual(seen.maxInside, 1)
        XCTAssertEqual(seen.order.count, 20)
    }

    func testATaskCancelledWhileItWaitsLeavesTheQueueAndTheNextOneGetsTheGate() async throws {
        let gate = FileV2AsyncGate()
        let release = FileV2Locked(false)
        let holder = Task {
            try await gate.withGate {
                while !release.withValue({ $0 }) { try await Task.sleep(nanoseconds: 1_000_000) }
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let ran = FileV2Locked<[String]>([])
        let cancelled = Task {
            do {
                try await gate.withGate { ran.withValue { $0.append("cancelled") } }
            } catch {
                ran.withValue { $0.append(error is CancellationError ? "cancelled-threw" : "other-error") }
            }
        }
        let next = Task { try await gate.withGate { ran.withValue { $0.append("next") } } }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        _ = await cancelled.value
        release.withValue { $0 = true }
        _ = try await holder.value
        try await next.value
        XCTAssertEqual(ran.withValue { $0 }, ["cancelled-threw", "next"], "the cancelled waiter never ran its section")
    }
}

import XCTest
@testable import QAudionEngine

/// A store that fails on demand, the way a device does before its first unlock, or when the disk hiccups: the listing throws, or the read of
/// one journal does.
final class FlakyStore: FileV2SendStore, @unchecked Sendable {
    let inner: FileV2SendStore
    private let lock = NSLock()
    private var listError: FileV2SendStoreError?
    private var loadErrors: [String: FileV2SendStoreError] = [:]

    init(inner: FileV2SendStore) {
        self.inner = inner
    }

    func failListing(_ error: FileV2SendStoreError?) {
        lock.lock()
        listError = error
        lock.unlock()
    }

    func failLoad(of id: String, with error: FileV2SendStoreError?) {
        lock.lock()
        loadErrors[id] = error
        lock.unlock()
    }

    func acquireLock(_ transferID: String) throws -> FileV2SendTransferLock { try inner.acquireLock(transferID) }

    func begin(_ record: FileV2SendBeginRecord) throws { try inner.begin(record) }

    func append(_ event: FileV2SendJournalEvent, to transferID: String) throws { try inner.append(event, to: transferID) }

    func load(_ transferID: String) throws -> FileV2SendRecovered {
        lock.lock()
        let error = loadErrors[transferID]
        lock.unlock()
        if let error = error { throw error }
        return try inner.load(transferID)
    }

    func listTransferIDs() throws -> [String] {
        lock.lock()
        let error = listError
        lock.unlock()
        if let error = error { throw error }
        return try inner.listTransferIDs()
    }

    func remove(_ transferID: String) throws { try inner.remove(transferID) }
}

/// The launch of the app: `recoverOnLaunch` and the sweep of orphaned uploads DECIDE NOTHING FROM WHAT THEY CANNOT READ. A launch before the
/// first unlock (a VoIP push after a reboot) cannot read the journals; to a store that cannot list them, a device with ten paused uploads looks
/// exactly like a device with none, and acting on that would destroy the key of every one of them.
final class FileV2SendLaunchTests: XCTestCase {

    private func pausedTransfer(_ rig: SendRig, id: String) async throws {
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 5)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: id))
        assertSendFailure(result, .network)
    }

    func testAPurgeAtLaunchWhenTheJournalsCannotBeListedKeepsTheKeysOfPausedTransfers() async throws {
        let rig = try SendRig(self)
        try await pausedTransfer(rig, id: "paused")
        _ = try rig.wrapper.wrap(Data(repeating: 7, count: 32))                      // a crash between a wrap and its begin record
        XCTAssertEqual(rig.wrapper.count, 3)

        let flaky = FlakyStore(inner: try rig.makeStore())
        flaky.failListing(.io("list"))
        let pipeline = try rig.makePipeline(store: flaky)
        let ran = await pipeline.recoverOnLaunch()
        XCTAssertFalse(ran, "it stopped")
        XCTAssertEqual(rig.wrapper.count, 3, "no key and no token was destroyed, not even the orphan")

        // The disk is back: the purge runs, destroys what nothing refers to and nothing else, and the paused transfer goes on.
        flaky.failListing(nil)
        let second = await pipeline.recoverOnLaunch()
        XCTAssertTrue(second)
        XCTAssertEqual(rig.wrapper.count, 2, "only the orphan went")
        let resumed = await pipeline.resume(transferID: "paused")
        XCTAssertEqual(resumed, .sentOk)
        try rig.assertNothingIsLeftBehind()
    }

    func testAJournalThatCannotBeReadForAReasonOtherThanCorruptionStopsThePurge() async throws {
        let rig = try SendRig(self)
        try await pausedTransfer(rig, id: "paused")
        try await pausedTransfer(rig, id: "other")
        _ = try rig.wrapper.wrap(Data(repeating: 7, count: 32))
        XCTAssertEqual(rig.wrapper.count, 5)

        let flaky = FlakyStore(inner: try rig.makeStore())
        for failure in [FileV2SendStoreError.io("read"), .notFound, .protectedDataUnavailable] {
            flaky.failLoad(of: "paused", with: failure)
            let ran = await (try rig.makePipeline(store: flaky)).recoverOnLaunch()
            XCTAssertFalse(ran, "\(failure)")
            XCTAssertEqual(rig.wrapper.count, 5, "\(failure): one unreadable journal is enough to destroy nothing")
        }
        flaky.failLoad(of: "paused", with: nil)
        let ran = await (try rig.makePipeline(store: flaky)).recoverOnLaunch()
        XCTAssertTrue(ran)
        XCTAssertEqual(rig.wrapper.count, 4)
    }

    func testACorruptJournalReferencesNothingAndDoesNotStopThePurge() async throws {
        let rig = try SendRig(self)
        try await pausedTransfer(rig, id: "paused")
        try Data("not a journal".utf8).write(to: rig.storeDirectory.appendingPathComponent("broken.qsj"))
        _ = try rig.wrapper.wrap(Data(repeating: 7, count: 32))
        XCTAssertEqual(rig.wrapper.count, 3)
        let ran = await (try rig.makePipeline()).recoverOnLaunch()
        XCTAssertTrue(ran)
        XCTAssertEqual(rig.wrapper.count, 2, "the orphan went, the key and the token of the paused transfer stayed")
        let resumed = await (try rig.makePipeline()).resume(transferID: "paused")
        XCTAssertEqual(resumed, .sentOk)
    }

    func testNothingIsDecidedWhileTheProtectedDataIsUnavailable() async throws {
        let rig = try SendRig(self)
        try await pausedTransfer(rig, id: "paused")
        _ = try rig.wrapper.wrap(Data(repeating: 7, count: 32))
        rig.clock.advance(ms: 11 * 60_000)
        let available = FileV2Locked(false)
        rig.protectedDataAvailable = { available.withValue { $0 } }
        let pipeline = try rig.makePipeline()
        try rig.makeStore().inner.append(.phase(.cancelled), to: "paused")          // would be finished by a launch that could read

        let ran = await pipeline.recoverOnLaunch()
        XCTAssertFalse(ran)
        XCTAssertEqual(rig.wrapper.count, 3, "nothing was destroyed")
        XCTAssertEqual(rig.fake.objectCount, 1, "the half-cancelled transfer was not finished from a store that could not be trusted")
        do {
            _ = try await pipeline.discardOrphanedUploads(minIdleMs: 0)
            XCTFail("the sweep must refuse")
        } catch {
            XCTAssertEqual(error as? FileV2SendStoreError, .protectedDataUnavailable)
        }
        XCTAssertFalse(rig.fake.calls.contains { $0.op == .listUnfinished }, "not even the server was asked")
        XCTAssertFalse(rig.fake.calls.contains { $0.op == .delete })

        // The first unlock happened.
        available.withValue { $0 = true }
        let later = await pipeline.recoverOnLaunch()
        XCTAssertTrue(later)
        XCTAssertEqual(rig.fake.objectCount, 0, "now the cancel is finished")
        try rig.assertNothingIsLeftBehind()
    }

    func testTheSweepOfOrphanedUploadsStopsWhenAJournalCannotBeReadAndDeletesNothing() async throws {
        let rig = try SendRig(self)
        try await pausedTransfer(rig, id: "paused")
        rig.clock.advance(ms: 11 * 60_000)                                            // idle for longer than the guard: it WOULD be an orphan
        XCTAssertEqual(rig.fake.objectCount, 1)

        let flaky = FlakyStore(inner: try rig.makeStore())
        let pipeline = try rig.makePipeline(store: flaky)
        flaky.failLoad(of: "paused", with: .io("read"))
        do {
            _ = try await pipeline.discardOrphanedUploads()
            XCTFail("the sweep must refuse")
        } catch {
            XCTAssertEqual(error as? FileV2SendStoreError, .io("read"))
        }
        flaky.failLoad(of: "paused", with: nil)
        flaky.failListing(.io("list"))
        do {
            _ = try await pipeline.discardOrphanedUploads()
            XCTFail("the sweep must refuse")
        } catch {
            XCTAssertEqual(error as? FileV2SendStoreError, .io("list"))
        }
        XCTAssertEqual(rig.fake.objectCount, 1, "the object of the paused transfer is still there")
        XCTAssertFalse(rig.fake.calls.contains { $0.op == .delete }, "nothing was deleted")

        // With the journals readable the object is known, so it is not an orphan whatever its age.
        flaky.failListing(nil)
        let deleted = try await pipeline.discardOrphanedUploads()
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(rig.fake.objectCount, 1)
        let resumed = await pipeline.resume(transferID: "paused")
        XCTAssertEqual(resumed, .sentOk)
    }

    func testTheRemedyOfAFullAccountDoesNotSweepWhenTheJournalsCannotBeRead() async throws {
        // The create is refused because the account holds its limit of unfinished uploads; the pipeline would sweep orphans and try again, but
        // with unreadable journals it cannot tell an orphan from a paused transfer, so it sweeps nothing and tells the user.
        let rig = try SendRig(self)
        try await pausedTransfer(rig, id: "paused")
        rig.clock.advance(ms: 11 * 60_000)
        let flaky = FlakyStore(inner: try rig.makeStore())
        flaky.failLoad(of: "paused", with: .io("read"))
        rig.fake.injectFailure(.create, error: FileV2ServerError(status: 429, code: "too_many_uploads", retryAfter: 30,
                                                                  details: FileV2ErrorDetails(limit: 10)), times: 1)
        let result = await (try rig.makePipeline(store: flaky)).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "second"))
        assertSendFailure(result, .userRemedy)
        XCTAssertEqual(rig.fake.objectCount, 1, "the paused transfer's object was not swept")
        XCTAssertFalse(rig.fake.calls.contains { $0.op == .delete })
    }
}

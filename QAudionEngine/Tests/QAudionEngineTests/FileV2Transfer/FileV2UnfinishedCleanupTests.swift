import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux (the scratch harness)
#endif
@testable import QAudionEngine

/// The cleanup of the account's leftover unfinished objects: only those idle for 30 minutes or more, one by one, never the
/// live upload of another device of the same account.
final class FileV2UnfinishedCleanupTests: XCTestCase {

    private let noSleep: @Sendable (Int64) async throws -> Void = { _ in }
    private let minute: Int64 = 60_000

    /// A distinct header per object (the server keys an object on the account and the header).
    private func create(_ server: FakeFileV2Server, _ number: Int, blobLength: Int64 = 1_000) async throws -> String {
        var head = Data(count: FileV2.headerLength)
        head[0] = UInt8(number & 0xFF)
        head[1] = UInt8((number >> 8) & 0xFF)
        let created = try await server.create(FileV2CreateRequest(blobLength: blobLength, head: head))
        return created.obj
    }

    private func listed(_ server: FakeFileV2Server) async throws -> Set<String> {
        var objects = Set<String>()
        var cursor: String?
        repeat {
            let page = try await server.listUnfinished(limit: 100, after: cursor)
            for item in page.objects { objects.insert(item.obj) }
            cursor = page.next
        } while cursor != nil
        return objects
    }

    func test_onlyObjectsIdleForThirtyMinutes_areDeleted() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        let old = try await create(alice, 1)
        clock.advance(ms: 29 * minute)
        let nearlyOld = try await create(alice, 2)          // created 29 minutes after `old`
        clock.advance(ms: 1 * minute + 5_000)               // `old` is 30 min 5 s idle, `nearlyOld` 1 min 5 s
        let young = try await create(alice, 3)

        let deleted = try await FileV2UnfinishedCleanup.run(server: alice, clock: clock, sleep: noSleep)
        XCTAssertEqual(deleted, 1)
        let left = try await listed(alice)
        XCTAssertEqual(left, [nearlyOld, young])
        XCTAssertFalse(left.contains(old))
    }

    func test_aPartUploadedRecently_keepsAnOldObjectAlive() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        let live = try await create(alice, 1, blobLength: 64 + 100)       // one part of 100 bytes
        let abandoned = try await create(alice, 2)
        clock.advance(ms: 45 * minute)
        let body = Data(repeating: 7, count: 100)                         // another device is uploading right now
        _ = try await alice.putPart(obj: live, part: 0, body: body, sha256: XferSupport.sha256(body))

        let deleted = try await FileV2UnfinishedCleanup.run(server: alice, clock: clock, sleep: noSleep)
        XCTAssertEqual(deleted, 1)
        let left = try await listed(alice)
        XCTAssertEqual(left, [live])
        XCTAssertFalse(left.contains(abandoned))
    }

    func test_nothingIsDeleted_whenEveryObjectIsRecent() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        _ = try await create(alice, 1)
        _ = try await create(alice, 2)
        clock.advance(ms: 10 * minute)
        let deleted = try await FileV2UnfinishedCleanup.run(server: alice, clock: clock, sleep: noSleep)
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(alice.objectCount, 2)
        XCTAssertFalse(alice.calls.contains { $0.op == .deleteUnfinished })      // never the bulk route
    }

    func test_anObjectOfAnotherAccount_isNeverTouched() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        let bob = alice.asAccount("bob")
        _ = try await create(alice, 1)
        let bobs = try await create(bob, 2)
        clock.advance(ms: 2 * 60 * minute)
        let deleted = try await FileV2UnfinishedCleanup.run(server: alice, clock: clock, sleep: noSleep)
        XCTAssertEqual(deleted, 1)
        let left = try await listed(bob)
        XCTAssertEqual(left, [bobs])
    }

    func test_anObjectAlreadyGone_isSkipped_andTheCleanupGoesOn() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        _ = try await create(alice, 1)
        _ = try await create(alice, 2)
        clock.advance(ms: 40 * minute)
        alice.injectFailure(.delete, error: FileV2ServerError(status: 404, code: "not_found"), times: 1)
        let deleted = try await FileV2UnfinishedCleanup.run(server: alice, clock: clock, sleep: noSleep)
        XCTAssertEqual(deleted, 1)                       // the first delete answered 404 and was skipped, the second went
        XCTAssertEqual(alice.objectCount, 1)
    }

    func test_aFailureStopsTheCleanup_butKeepsWhatWasDone() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        _ = try await create(alice, 1)
        _ = try await create(alice, 2)
        clock.advance(ms: 40 * minute)
        // 403 is final for a delete: the cleanup stops there and does not throw
        alice.injectFailure(.delete, error: FileV2ServerError(status: 403, code: "not_owner"), times: 1)
        let deleted = try await FileV2UnfinishedCleanup.run(server: alice, clock: clock, sleep: noSleep)
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(alice.objectCount, 2)
    }

    func test_severalPagesOfTheList_areWalked() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        alice.maxIncomplete = 130                         // the real cap is 10; the page logic needs more than one page
        for number in 0..<130 { _ = try await create(alice, number) }
        clock.advance(ms: 40 * minute)
        let deleted = try await FileV2UnfinishedCleanup.run(server: alice, clock: clock, sleep: noSleep)
        XCTAssertEqual(deleted, 130)
        XCTAssertEqual(alice.objectCount, 0)
    }
}

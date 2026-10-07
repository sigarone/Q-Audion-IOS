import XCTest
@testable import QAudionEngine

/// A sleeper the test controls: `sleep` suspends until the test releases it, so a call with an injected delay, or a download
/// that waits for parts, is in flight exactly as long as the test wants.
final class XferGateSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var sleptMs: [Int64] = []

    /// A sleep shorter than this returns at once (it is only logged); a longer one suspends until the test releases it. The
    /// default suspends every sleep.
    var suspendFromMs: Int64 = 0

    func sleep(_ ms: Int64) async {
        guard record(ms) else { return }
        await withCheckedContinuation { continuation in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Logs the sleep and says whether it suspends (a plain function: a lock is not for an `async` one).
    private func record(_ ms: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sleptMs.append(ms)
        return ms >= suspendFromMs
    }

    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    var log: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return sleptMs
    }

    /// Lets every suspended sleep return.
    func releaseAll() {
        lock.lock()
        let all = waiters
        waiters = []
        lock.unlock()
        for continuation in all { continuation.resume() }
    }

    /// How many sleeps of exactly `ms` were started (suspended or not).
    func count(ms: Int64) -> Int { log.filter { $0 == ms }.count }

    /// Waits (really, briefly) until `count` sleeps are suspended.
    func waitUntilWaiting(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if waiting >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("only \(waiting) of \(count) sleeps are suspended", file: file, line: line)
    }
}

/// The typed `FileV2Server` fake, driven the way the pipelines will drive it. Every behaviour here goes through the core that the
/// conformance transcript holds to the real server; these tests check the typed layer on top of it: the requests it builds,
/// the values and errors it returns, and the controls the pipelines' tests use.
final class FakeFileV2ServerTests: XCTestCase {

    // MARK: Helpers

    private let day: Int64 = 86_400_000

    private func blob(_ seed: Int64, length: Int64 = 1_064) -> XferBlob {
        XferBlob(name: "t\(seed)", seed: seed, length: length, parts: FileV2Wire.partCount(blobLength: length), headBase64: "",
                 partsSHA256: nil, declaredOnly: false)
    }

    private func createRequest(_ blob: XferBlob, token: FileV2TokenRequest? = nil) -> FileV2CreateRequest {
        FileV2CreateRequest(blobLength: blob.length, head: blob.head, token: token)
    }

    @discardableResult
    private func put(_ server: FakeFileV2Server, _ obj: String, _ blob: XferBlob, _ part: Int) async throws -> FileV2PutResult {
        let body = blob.part(part)
        return try await server.putPart(obj: obj, part: part, body: body, sha256: XferSupport.sha256(body))
    }

    private func expectError(_ status: Int, _ code: String, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async -> FileV2ServerError? {
        do {
            try await body()
            XCTFail("expected \(status) \(code)", file: file, line: line)
            return nil
        } catch let error as FileV2ServerError {
            XCTAssertEqual(error.status, status, "\(error)", file: file, line: line)
            XCTAssertEqual(error.code, code, "\(error)", file: file, line: line)
            return error
        } catch {
            XCTFail("expected \(status) \(code), got \(error)", file: file, line: line)
            return nil
        }
    }

    private func fetchHeader(_ server: FakeFileV2Server, _ obj: String, token: FileV2DownloadAuth? = nil) async throws -> FileV2RangeResult {
        try await server.fetchRange(obj: obj, from: 0, toInclusive: 63, token: token, waitSeconds: 0)
    }

    private func auth(_ token: FileV2IssuedToken) -> FileV2DownloadAuth { FileV2DownloadAuth(v: token.v, expMs: token.exp, max: token.max) }

    // MARK: Create

    func testCreateThenResumeReturnsTheSameObjectWithWhatIsAlreadyThere() async throws {
        let server = FakeFileV2Server()
        let file = blob(1)
        let first = try await server.create(createRequest(file))
        XCTAssertFalse(first.existing)
        XCTAssertEqual(first.parts, 1)
        XCTAssertEqual(first.blobLength, 1_064)
        XCTAssertEqual(first.partSize, FileV2Wire.partSize)
        XCTAssertEqual(first.parallelism, 6)
        XCTAssertEqual(first.maxParallelism, 8)
        XCTAssertNil(first.token)
        XCTAssertEqual(first.received, 0)
        XCTAssertFalse(first.complete)

        let again = try await server.create(createRequest(file))
        XCTAssertTrue(again.existing)
        XCTAssertEqual(again.obj, first.obj)

        try await put(server, first.obj, file, 0)
        let resumed = try await server.create(createRequest(file))
        XCTAssertTrue(resumed.existing)
        XCTAssertEqual(resumed.received, 1)
        XCTAssertFalse(resumed.complete)

        try await server.complete(obj: first.obj)
        let done = try await server.create(createRequest(file))
        XCTAssertTrue(done.complete)
        XCTAssertEqual(server.objectCount, 1)
    }

    func testCreateWithATokenIssuesOneAndEveryRepeatIssuesANewOne() async throws {
        let clock = XferManualClock(startMs: 1_790_000_000_000)
        let server = FakeFileV2Server(clock: clock)
        let file = blob(2)
        let request = createRequest(file, token: .forRecipient("bob"))
        let first = try await server.create(request)
        let token = try XCTUnwrap(first.token)
        XCTAssertEqual(token.scope, "user")
        XCTAssertEqual(token.max, 10)
        XCTAssertEqual(token.exp, 1_790_000_000_000 + 7 * day)
        XCTAssertEqual(token.v.count, 64)

        clock.advance(ms: 1_000)
        let second = try await server.create(request)
        XCTAssertTrue(second.existing)
        let renewed = try XCTUnwrap(second.token)
        XCTAssertNotEqual(renewed.v, token.v, "a repeat gets a fresh token (a new expiry, a new MAC)")
        XCTAssertEqual(renewed.exp, token.exp + 1_000)
    }

    func testTheSameHeaderWithAnotherLengthIsAConflict() async throws {
        let server = FakeFileV2Server()
        let file = blob(3)
        _ = try await server.create(createRequest(file))
        let other = FileV2CreateRequest(blobLength: 2_000, head: file.head)
        let error = await expectError(409, "head_conflict") { _ = try await server.create(other) }
        XCTAssertEqual(error?.disposition(for: .create), .fail(.badRequest))
    }

    func testAnotherAccountWithTheSameHeaderGetsAnObjectOfItsOwn() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let bob = alice.asAccount("bob")
        let file = blob(4)
        let a = try await alice.create(createRequest(file))
        let b = try await bob.create(createRequest(file))
        XCTAssertNotEqual(a.obj, b.obj)
        XCTAssertFalse(b.existing)
        _ = await expectError(403, "not_owner") { _ = try await bob.partsMap(obj: a.obj) }
        _ = try await bob.partsMap(obj: b.obj)
    }

    func testCreateValidationErrorsCarryTheirDetails() async throws {
        let server = FakeFileV2Server()
        let file = blob(5)
        var error = await expectError(413, "blob_too_large") {
            _ = try await server.create(FileV2CreateRequest(blobLength: Int64(FileV2.maxBlob) + 1, head: file.head))
        }
        XCTAssertEqual(error?.details.maxBlobLength, Int64(FileV2.maxBlob))
        XCTAssertEqual(error?.disposition(for: .create), .fail(.quota))

        error = await expectError(400, "bad_part_size") {
            _ = try await server.create(FileV2CreateRequest(blobLength: 100, head: file.head, partSize: 4_194_368))
        }
        XCTAssertEqual(error?.details.partSize, Int64(FileV2Wire.partSize))

        _ = await expectError(400, "bad_blob_len") { _ = try await server.create(FileV2CreateRequest(blobLength: 64, head: file.head)) }
        _ = await expectError(400, "bad_head") { _ = try await server.create(FileV2CreateRequest(blobLength: 100, head: Data(count: 63))) }
        _ = await expectError(400, "bad_token_request") {
            _ = try await server.create(createRequest(file, token: FileV2TokenRequest(recipientUserID: nil, groupID: nil)))
        }
        _ = await expectError(400, "bad_token_request") {
            _ = try await server.create(createRequest(file, token: .forRecipient("bob", ttlSeconds: 2_592_001)))
        }
        _ = await expectError(400, "bad_token_request") {
            _ = try await server.create(createRequest(file, token: .forRecipient("bob", maxUses: 1_001)))
        }
        XCTAssertEqual(server.objectCount, 0, "a refused create reserves nothing")
    }

    // MARK: Limits and the errors a user sees

    func testQuotaExceededCarriesUsedAndLimitAndFreesAtOnceOnDelete() async throws {
        let server = FakeFileV2Server()
        server.quota = 3_000
        let first = try await server.create(createRequest(blob(6, length: 2_000)))
        let error = await expectError(413, "quota_exceeded") { _ = try await server.create(self.createRequest(self.blob(7, length: 1_500))) }
        XCTAssertEqual(error?.details.used, 2_000)
        XCTAssertEqual(error?.details.limit, 3_000)
        XCTAssertEqual(error?.disposition(for: .create), .fail(.quota))
        try await server.delete(obj: first.obj)
        _ = try await server.create(createRequest(blob(7, length: 1_500)))
    }

    func testTooManyUploadsAndTooManyObjectsAskTheUserToFreeSomething() async throws {
        let server = FakeFileV2Server()
        server.maxIncomplete = 2
        _ = try await server.create(createRequest(blob(8)))
        _ = try await server.create(createRequest(blob(9)))
        let error = await expectError(429, "too_many_uploads") { _ = try await server.create(self.createRequest(self.blob(10))) }
        XCTAssertEqual(error?.retryAfter, 30)
        XCTAssertEqual(error?.details.limit, 2)
        XCTAssertEqual(error?.disposition(for: .create), .userRemedy(.quota))

        let other = FakeFileV2Server(account: "carol")
        other.maxObjects = 1
        _ = try await other.create(createRequest(blob(11)))
        let many = await expectError(429, "too_many_objects") { _ = try await other.create(self.createRequest(self.blob(12))) }
        XCTAssertNil(many?.retryAfter)
        XCTAssertEqual(many?.disposition(for: .create), .userRemedy(.quota))
    }

    func testNoRoomOnTheServerIs507WithOrWithoutARetryAfter() async throws {
        let full = FakeFileV2Server()
        full.freeBytes = 500 << 20
        var error = await expectError(507, "insufficient_storage") { _ = try await full.create(self.createRequest(self.blob(13))) }
        XCTAssertNil(error?.retryAfter, "a full disk: no hint")
        XCTAssertEqual(error?.disposition(for: .create), .fail(.serverFull))
        full.freeBytes = nil
        _ = try await full.create(createRequest(blob(13)))

        let capped = FakeFileV2Server()
        capped.maxUnfinishedBytes = 1_500
        _ = try await capped.create(createRequest(blob(14, length: 1_000)))
        error = await expectError(507, "insufficient_storage") { _ = try await capped.create(self.createRequest(self.blob(15, length: 1_000))) }
        XCTAssertEqual(error?.retryAfter, 60, "the server-wide cap: come back later")
        XCTAssertEqual(error?.disposition(for: .create), .fail(.serverFull))
    }

    func testWithoutTheFilesEntitlementCreateAndTokensAreRefusedAndEverythingElseStillWorks() async throws {
        let server = FakeFileV2Server()
        let file = blob(16)
        let made = try await server.create(createRequest(file))
        server.revokeEntitlement("alice")
        let error = await expectError(402, "entitlement_required") { _ = try await server.create(self.createRequest(self.blob(17))) }
        XCTAssertEqual(error?.details.feature, "feat.files")
        XCTAssertEqual(error?.details.packageName, "pro")
        XCTAssertEqual(error?.disposition(for: .create), .fail(.entitlement))
        _ = await expectError(402, "entitlement_required") { _ = try await server.issueToken(obj: made.obj, scope: .forRecipient("bob")) }
        // finishing and freeing what the account holds needs no entitlement
        try await put(server, made.obj, file, 0)
        try await server.complete(obj: made.obj)
        _ = try await server.listUnfinished(limit: nil, after: nil)
        _ = try await server.deleteUnfinished()
        try await server.delete(obj: made.obj)
        server.grantEntitlement("alice")
        _ = try await server.create(createRequest(blob(17)))
    }

    // MARK: Parts

    func testADigestMismatchIsRetriedAndLeavesNothingBehind() async throws {
        let server = FakeFileV2Server()
        let file = blob(20)
        let made = try await server.create(createRequest(file))
        let error = await expectError(400, "digest_mismatch") {
            _ = try await server.putPart(obj: made.obj, part: 0, body: file.part(0), sha256: Data(repeating: 1, count: 32))
        }
        XCTAssertEqual(error?.disposition(for: .putPart), .retry(onExhausted: .network))
        let empty = try await server.partsMap(obj: made.obj)
        XCTAssertEqual(empty.received, 0)
        XCTAssertNil(server.storedPart(obj: made.obj, part: 0))
        let result = try await put(server, made.obj, file, 0)
        XCTAssertEqual(result, FileV2PutResult(part: 0, duplicate: false, received: 1, parts: 1))
        XCTAssertEqual(server.storedPart(obj: made.obj, part: 0), file.part(0))
    }

    func testTheSamePartAgainIsADuplicateAndAnotherDigestIsAConflict() async throws {
        let server = FakeFileV2Server()
        let file = blob(21)
        let made = try await server.create(createRequest(file))
        _ = try await put(server, made.obj, file, 0)
        let again = try await put(server, made.obj, file, 0)
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(again.received, 1)
        let changed = blob(22)
        let error = await expectError(409, "part_conflict") { _ = try await self.put(server, made.obj, changed, 0) }
        XCTAssertEqual(error?.disposition(for: .putPart), .fail(.sourceChanged))
        XCTAssertEqual(server.storedPart(obj: made.obj, part: 0), file.part(0), "a part on the server never changes")
    }

    func testBadLengthIndexAndDigestAreRefusedBeforeTheBody() async throws {
        let server = FakeFileV2Server()
        let file = blob(23)
        let made = try await server.create(createRequest(file))
        let body = file.part(0)
        var error = await expectError(400, "bad_length") {
            _ = try await server.putPart(obj: made.obj, part: 0, body: body.dropLast(), sha256: XferSupport.sha256(body))
        }
        XCTAssertEqual(error?.details.expected, 1_000)
        error = await expectError(400, "bad_part") { _ = try await server.putPart(obj: made.obj, part: 1, body: body, sha256: XferSupport.sha256(body)) }
        XCTAssertEqual(error?.details.parts, 1)
        _ = await expectError(400, "bad_part") { _ = try await server.putPart(obj: made.obj, part: -1, body: body, sha256: XferSupport.sha256(body)) }
        _ = await expectError(400, "digest_invalid") { _ = try await server.putPart(obj: made.obj, part: 0, body: body, sha256: Data(count: 31)) }
        _ = await expectError(404, "not_found") {
            _ = try await server.putPart(obj: "00000000-0000-4000-8000-000000000000", part: 0, body: body, sha256: XferSupport.sha256(body))
        }
        error = await expectError(404, "not_found") { _ = try await server.putPart(obj: "not-an-id", part: 0, body: body, sha256: XferSupport.sha256(body)) }
        XCTAssertEqual(error?.disposition(for: .putPart), .recreate)
    }

    func testThePartsMapCompleteAndTheMissingList() async throws {
        let server = FakeFileV2Server()
        let size = Int64(FileV2Wire.partSize)
        let file = blob(24, length: 64 + 2 * size + 100)     // three parts, the last one 100 bytes
        let made = try await server.create(createRequest(file))
        XCTAssertEqual(made.parts, 3)
        let fresh = try await server.partsMap(obj: made.obj)
        XCTAssertEqual(fresh.missing, [0, 1, 2])
        _ = try await put(server, made.obj, file, 2)
        let map = try await server.partsMap(obj: made.obj)
        XCTAssertEqual(map.bits, [false, false, true])
        XCTAssertEqual(map.received, 1)
        XCTAssertEqual(map.partSize, FileV2Wire.partSize)
        XCTAssertEqual(map.blobLength, file.length)
        XCTAssertFalse(map.complete)

        let error = await expectError(409, "incomplete") { try await server.complete(obj: made.obj) }
        XCTAssertEqual(error?.missing, [0, 1])
        XCTAssertEqual(error?.details.parts, 3)
        XCTAssertEqual(error?.disposition(for: .complete), .sendMissing)

        _ = try await put(server, made.obj, file, 1)
        _ = try await put(server, made.obj, file, 0)
        try await server.complete(obj: made.obj)
        try await server.complete(obj: made.obj)                       // idempotent
        let closed = try await server.partsMap(obj: made.obj)
        XCTAssertTrue(closed.complete)
    }

    func testDeleteIsImmediateAndASecondDeleteIsAlreadyDone() async throws {
        let server = FakeFileV2Server()
        let made = try await server.create(createRequest(blob(25)))
        try await server.delete(obj: made.obj)
        let error = await expectError(404, "not_found") { try await server.delete(obj: made.obj) }
        XCTAssertEqual(error?.disposition(for: .delete), .done)
        _ = await expectError(404, "not_found") { _ = try await server.partsMap(obj: made.obj) }
        XCTAssertEqual(server.objectCount, 0)
        let fresh = try await server.create(createRequest(blob(25)))
        XCTAssertNotEqual(fresh.obj, made.obj, "the header is free again: a create after a delete makes a new object")
        XCTAssertFalse(fresh.existing)
    }

    // MARK: Tokens and reading

    func testAUserTokenOpensTheObjectForThatAccountOnlyAndItsUsesAreCounted() async throws {
        let clock = XferManualClock(startMs: 1_790_000_000_000)
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        let bob = alice.asAccount("bob")
        let carol = alice.asAccount("carol")
        let file = blob(30)
        let made = try await alice.create(createRequest(file))
        try await put(alice, made.obj, file, 0)
        try await alice.complete(obj: made.obj)
        let token = try await alice.issueToken(obj: made.obj, scope: .forRecipient("bob", ttlSeconds: 3_600, maxUses: 2))
        XCTAssertEqual(token.exp, 1_790_000_000_000 + 3_600_000)
        XCTAssertEqual(token.max, 2)

        let own = try await fetchHeader(alice, made.obj)
        XCTAssertEqual(own.body, file.bytes(from: 0, count: 64))
        XCTAssertEqual(own.totalLength, 1_064)
        let read = try await bob.fetchRange(obj: made.obj, from: 64, toInclusive: 1_063, token: auth(token), waitSeconds: 0)
        XCTAssertEqual(read.body, file.part(0))
        let firstUse = try await fetchHeader(bob, made.obj, token: auth(token))
        let secondUse = try await fetchHeader(bob, made.obj, token: auth(token))
        XCTAssertEqual(firstUse.body, file.bytes(from: 0, count: 64))
        XCTAssertEqual(secondUse.body, file.bytes(from: 0, count: 64))
        let spent = await expectError(403, "token_rejected") { _ = try await self.fetchHeader(bob, made.obj, token: self.auth(token)) }
        XCTAssertEqual(spent?.disposition(for: .fetchRange), .unavailable, "a spent token: the file is no longer available")

        _ = await expectError(403, "token_rejected") { _ = try await self.fetchHeader(carol, made.obj, token: self.auth(token)) }
        _ = await expectError(403, "token_required") { _ = try await self.fetchHeader(carol, made.obj) }
        let tampered = FileV2DownloadAuth(v: token.v, expMs: token.exp + 1, max: token.max)
        _ = await expectError(403, "token_rejected") { _ = try await self.fetchHeader(bob, made.obj, token: tampered) }
    }

    func testATokenExpiresOneMillisecondAfterItsExpiry() async throws {
        let clock = XferManualClock(startMs: 1_790_000_000_000)
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        let bob = alice.asAccount("bob")
        let file = blob(31)
        let made = try await alice.create(createRequest(file))
        try await put(alice, made.obj, file, 0)
        try await alice.complete(obj: made.obj)
        let token = try await alice.issueToken(obj: made.obj, scope: .forRecipient("bob", ttlSeconds: 60))
        clock.advance(ms: 60_000)
        _ = try await fetchHeader(bob, made.obj, token: auth(token))
        clock.advance(ms: 1)
        _ = await expectError(403, "token_rejected") { _ = try await self.fetchHeader(bob, made.obj, token: self.auth(token)) }
    }

    func testAGroupTokenFollowsTheMembershipAtDownloadTime() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let bob = alice.asAccount("bob")
        let file = blob(32)
        let made = try await alice.create(createRequest(file))
        try await put(alice, made.obj, file, 0)
        try await alice.complete(obj: made.obj)
        alice.addGroupMember(group: "group-0001abcd", user: "bob")
        _ = await expectError(403, "not_group_member") { _ = try await alice.issueToken(obj: made.obj, scope: .forGroup("group-0001abcd")) }
        alice.addGroupMember(group: "group-0001abcd", user: "alice")
        let token = try await alice.issueToken(obj: made.obj, scope: .forGroup("group-0001abcd"))
        XCTAssertEqual(token.scope, "group")
        _ = try await fetchHeader(bob, made.obj, token: auth(token))
        alice.removeGroupMember(group: "group-0001abcd", user: "bob")
        _ = await expectError(403, "token_rejected") { _ = try await self.fetchHeader(bob, made.obj, token: self.auth(token)) }
        alice.addGroupMember(group: "group-0001abcd", user: "bob")
        alice.setGroupLookupFails(true)
        let broken = await expectError(500, "storage_error") { _ = try await self.fetchHeader(bob, made.obj, token: self.auth(token)) }
        XCTAssertEqual(broken?.disposition(for: .fetchRange), .retry(onExhausted: .network), "a failing lookup is never a pass")
    }

    func testWithoutATokenSecretOnlyTheOwnerReads() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let bob = alice.asAccount("bob")
        let file = blob(33)
        let made = try await alice.create(createRequest(file))
        try await put(alice, made.obj, file, 0)
        alice.tokensEnabled = false
        let error = await expectError(503, "tokens_disabled") { _ = try await alice.issueToken(obj: made.obj, scope: .forRecipient("bob")) }
        XCTAssertEqual(error?.disposition(for: .issueToken), .retry(onExhausted: .network))
        _ = await expectError(403, "not_owner") { _ = try await self.fetchHeader(bob, made.obj) }
        _ = try await fetchHeader(alice, made.obj)
    }

    func testRangesAndTheStreamingRefusal() async throws {
        let server = FakeFileV2Server()
        let size = Int64(FileV2Wire.partSize)
        let file = blob(34, length: 64 + size + 700)
        let made = try await server.create(createRequest(file))
        // the header exists from the creation; a range that needs a missing part is 425 (not a failure)
        let header = try await fetchHeader(server, made.obj)
        XCTAssertEqual(header.body, file.bytes(from: 0, count: 64))
        let early = await expectError(425, "parts_not_yet_received") {
            _ = try await server.fetchRange(obj: made.obj, from: 64, toInclusive: 100, token: nil, waitSeconds: 0)
        }
        XCTAssertEqual(early?.retryAfter, 1)
        XCTAssertEqual(early?.details.firstPart, 0)
        XCTAssertEqual(early?.details.lastPart, 0)
        XCTAssertEqual(early?.disposition(for: .fetchRange), .wait)

        _ = try await put(server, made.obj, file, 1)
        let tail = try await server.fetchRange(obj: made.obj, from: 64 + size, toInclusive: 64 + size + 699, token: nil, waitSeconds: 0)
        XCTAssertEqual(tail.body, file.part(1))
        XCTAssertEqual(tail.totalLength, file.length)
        // a range over the parts that are there but touching the missing one is still refused
        let touching = await expectError(425, "parts_not_yet_received") {
            _ = try await server.fetchRange(obj: made.obj, from: 64 + size - 5, toInclusive: 64 + size + 5, token: nil, waitSeconds: 0)
        }
        XCTAssertEqual(touching?.details.firstPart, 0)
        XCTAssertEqual(touching?.details.lastPart, 1)

        let outside = await expectError(416, "range_not_satisfiable") {
            _ = try await server.fetchRange(obj: made.obj, from: file.length, toInclusive: file.length + 5, token: nil, waitSeconds: 0)
        }
        XCTAssertEqual(outside?.disposition(for: .fetchRange), .fail(.badRequest))
        _ = await expectError(416, "range_not_satisfiable") { _ = try await server.fetchRange(obj: made.obj, from: 10, toInclusive: 5, token: nil, waitSeconds: 0) }
        _ = await expectError(416, "range_not_satisfiable") { _ = try await server.fetchRange(obj: made.obj, from: -1, toInclusive: 5, token: nil, waitSeconds: 0) }
        let gone = await expectError(404, "not_found") {
            _ = try await server.fetchRange(obj: "00000000-0000-4000-8000-000000000000", from: 0, toInclusive: 5, token: nil, waitSeconds: 0)
        }
        XCTAssertEqual(gone?.disposition(for: .fetchRange), .unavailable)
    }

    func testAReadThatWaitsForAPartIsAnsweredWhenThePartArrives() async throws {
        let sleeper = XferGateSleeper()
        let alice = FakeFileV2Server(account: "alice", sleep: { await sleeper.sleep($0) })
        let file = blob(35)
        let made = try await alice.create(createRequest(file))
        let reader = Task { try await alice.fetchRange(obj: made.obj, from: 64, toInclusive: 1_063, token: nil, waitSeconds: 20) }
        await sleeper.waitUntilWaiting(1)
        try await put(alice, made.obj, file, 0)
        sleeper.releaseAll()
        let result = try await reader.value
        XCTAssertEqual(result.body, file.part(0))
    }

    func testAReadThatWaitsForAPartThatNeverArrivesIs425AfterItsWait() async throws {
        let sleeper = XferGateSleeper()
        sleeper.suspendFromMs = 1_000                  // the polls (50 ms) return at once: the wait runs out in no time
        let alice = FakeFileV2Server(account: "alice", sleep: { await sleeper.sleep($0) })
        let file = blob(36)
        let made = try await alice.create(createRequest(file))
        let error = await expectError(425, "parts_not_yet_received") {
            _ = try await alice.fetchRange(obj: made.obj, from: 64, toInclusive: 100, token: nil, waitSeconds: 5)
        }
        XCTAssertEqual(error?.disposition(for: .fetchRange), .wait)
        XCTAssertEqual(sleeper.count(ms: 50), 100, "5 seconds asked, looked at every 50 ms")
        // the cap of the server (25 s) is the longest it waits, whatever the client asks
        let capped = await expectError(425, "parts_not_yet_received") {
            _ = try await alice.fetchRange(obj: made.obj, from: 64, toInclusive: 100, token: nil, waitSeconds: 600)
        }
        XCTAssertNotNil(capped)
        XCTAssertEqual(sleeper.count(ms: 50), 100 + 500)
    }

    func testDeletingTheObjectWakesAWaitingReadWith404() async throws {
        let sleeper = XferGateSleeper()
        let alice = FakeFileV2Server(account: "alice", sleep: { await sleeper.sleep($0) })
        let file = blob(37)
        let made = try await alice.create(createRequest(file))
        let waiting = Task { try await alice.fetchRange(obj: made.obj, from: 64, toInclusive: 100, token: nil, waitSeconds: 20) }
        await sleeper.waitUntilWaiting(1)
        try await alice.delete(obj: made.obj)
        sleeper.releaseAll()
        do {
            _ = try await waiting.value
            XCTFail("a read of a deleted object must be refused")
        } catch let error as FileV2ServerError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.code, "not_found")
            XCTAssertEqual(error.disposition(for: .fetchRange), .unavailable)
        }
    }

    // MARK: The collection routes

    func testListPagesInObjectIdOrderAndNeverShowsACompletedObject() async throws {
        let server = FakeFileV2Server()
        var made = [FileV2Created]()
        for seed in 40..<45 { made.append(try await server.create(createRequest(blob(Int64(seed))))) }
        let done = blob(45)
        let completed = try await server.create(createRequest(done))
        try await put(server, completed.obj, done, 0)
        try await server.complete(obj: completed.obj)

        let all = try await server.listUnfinished(limit: nil, after: nil)
        XCTAssertEqual(all.objects.count, 5)
        XCTAssertNil(all.next)
        let ids = all.objects.map { $0.obj }
        XCTAssertEqual(ids, ids.sorted(), "object id order")
        XCTAssertEqual(Set(ids), Set(made.map { $0.obj }))
        XCTAssertFalse(ids.contains(completed.obj))
        XCTAssertEqual(all.objects[0].blobLength, 1_064)
        XCTAssertEqual(all.objects[0].parts, 1)
        XCTAssertEqual(all.objects[0].received, 0)

        let first = try await server.listUnfinished(limit: 2, after: nil)
        XCTAssertEqual(first.objects.map { $0.obj }, Array(ids[0..<2]))
        XCTAssertEqual(first.next, ids[1])
        let second = try await server.listUnfinished(limit: 2, after: first.next)
        XCTAssertEqual(second.objects.map { $0.obj }, Array(ids[2..<4]))
        let last = try await server.listUnfinished(limit: 2, after: second.next)
        XCTAssertEqual(last.objects.map { $0.obj }, [ids[4]])
        XCTAssertNil(last.next)

        let error = await expectError(400, "bad_request") { _ = try await server.listUnfinished(limit: 0, after: nil) }
        XCTAssertEqual(error?.disposition(for: .listUnfinished), .fail(.badRequest))
        _ = await expectError(400, "bad_request") { _ = try await server.listUnfinished(limit: 101, after: nil) }
        _ = await expectError(400, "bad_request") { _ = try await server.listUnfinished(limit: nil, after: "not-an-object-id") }
        let widest = try await server.listUnfinished(limit: 100, after: nil)
        XCTAssertEqual(widest.objects.count, 5)
    }

    func testDeleteUnfinishedFreesEverythingUnfinishedAndNothingElse() async throws {
        let server = FakeFileV2Server()
        let a = try await server.create(createRequest(blob(50, length: 1_000)))
        _ = try await server.create(createRequest(blob(51, length: 2_000)))
        let done = blob(52)
        let kept = try await server.create(createRequest(done))
        try await put(server, kept.obj, done, 0)
        try await server.complete(obj: kept.obj)
        let result = try await server.deleteUnfinished()
        XCTAssertEqual(result, FileV2BulkDeleteResult(deleted: 2, freedBytes: 3_000))
        XCTAssertEqual(server.objectCount, 1)
        _ = await expectError(404, "not_found") { _ = try await server.partsMap(obj: a.obj) }
        let survivor = try await server.partsMap(obj: kept.obj)
        XCTAssertTrue(survivor.complete)
        let nothing = try await server.deleteUnfinished()
        XCTAssertEqual(nothing, FileV2BulkDeleteResult(deleted: 0, freedBytes: 0), "idempotent")
    }

    // MARK: Cleanup and the clock

    func testTheCleanupRemovesWhatTheServerRemoves() async throws {
        let clock = XferManualClock(startMs: 1_790_000_000_000)
        let server = FakeFileV2Server(clock: clock)
        let idle = blob(60)
        let made = try await server.create(createRequest(idle))
        let kept = blob(61)
        let active = try await server.create(createRequest(kept))
        let done = blob(62)
        let completed = try await server.create(createRequest(done))
        try await put(server, completed.obj, done, 0)
        try await server.complete(obj: completed.obj)

        clock.advance(ms: 6 * 3_600_000)
        server.cleanup()
        XCTAssertEqual(server.objectCount, 3, "at exactly six hours an unfinished object is kept")
        _ = try await put(server, active.obj, kept, 0)          // a new part refreshes its activity
        clock.advance(ms: 1)
        server.cleanup()
        XCTAssertEqual(server.objectCount, 2, "one millisecond later the idle one is gone")
        _ = await expectError(404, "not_found") { _ = try await server.partsMap(obj: made.obj) }

        clock.advance(ms: 18 * 3_600_000)                       // now 24 hours and 1 ms after the creation
        server.cleanup()
        XCTAssertEqual(server.objectCount, 1, "an unfinished object goes 24 hours after its creation, whatever it did since")
        _ = await expectError(404, "not_found") { _ = try await server.partsMap(obj: active.obj) }

        clock.advance(ms: 30 * day - 24 * 3_600_000 - 1)        // exactly 30 days after the completion
        server.cleanup()
        XCTAssertEqual(server.objectCount, 1, "a completed object is kept for 30 days")
        clock.advance(ms: 1)
        server.cleanup()
        XCTAssertEqual(server.objectCount, 0)
    }

    func testTheRetentionOfACompletedObjectIsAParameter() async throws {
        let clock = XferManualClock(startMs: 1_790_000_000_000)
        let server = FakeFileV2Server(clock: clock)
        server.completedRetentionMs = 14 * day
        let done = blob(63)
        let made = try await server.create(createRequest(done))
        try await put(server, made.obj, done, 0)
        try await server.complete(obj: made.obj)
        clock.advance(ms: 14 * day)
        server.cleanup()
        XCTAssertEqual(server.objectCount, 1)
        clock.advance(ms: 1)
        server.cleanup()
        XCTAssertEqual(server.objectCount, 0)
    }

    // MARK: Accounts, the calls log, failures and delays

    func testTheCallsLogRecordsEveryCallInOrder() async throws {
        let server = FakeFileV2Server()
        let file = blob(70)
        let made = try await server.create(createRequest(file))
        _ = try await put(server, made.obj, file, 0)
        _ = try await server.partsMap(obj: made.obj)
        try await server.complete(obj: made.obj)
        try await server.delete(obj: made.obj)
        XCTAssertEqual(server.calls, [call(.create, nil), call(.putPart, 0), call(.partsMap, nil), call(.complete, nil), call(.delete, nil)])
    }

    private func call(_ op: FileV2Op, _ part: Int?) -> FakeFileV2Server.Call { FakeFileV2Server.Call(op: op, part: part) }

    func testAFailureBeforeTheEffectLeavesNothingAndAFailureAfterItLeavesTheEffect() async throws {
        let server = FakeFileV2Server()
        let file = blob(71)
        let made = try await server.create(createRequest(file))
        server.injectFailure(.putPart, error: URLError(.timedOut), when: .beforeEffect)
        do {
            _ = try await put(server, made.obj, file, 0)
            XCTFail("the injected failure must surface")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertNil(server.storedPart(obj: made.obj, part: 0))

        server.injectFailure(.putPart, error: URLError(.networkConnectionLost), when: .afterEffect)
        do {
            _ = try await put(server, made.obj, file, 0)
            XCTFail("the injected failure must surface")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(server.storedPart(obj: made.obj, part: 0), file.part(0), "the server served it: only the client lost the answer")
        let retry = try await put(server, made.obj, file, 0)
        XCTAssertTrue(retry.duplicate, "the retry of a request the server had served is a duplicate")
    }

    func testAFailureCanTargetOnePartAndFiresOnlyTheGivenNumberOfTimes() async throws {
        let server = FakeFileV2Server()
        let size = Int64(FileV2Wire.partSize)
        let file = blob(72, length: 64 + size + 10)
        let made = try await server.create(createRequest(file))
        server.injectFailure(.putPart, error: URLError(.timedOut), times: 2, part: 1)
        _ = try await put(server, made.obj, file, 0)
        for _ in 0..<2 { do { _ = try await put(server, made.obj, file, 1); XCTFail("must fail") } catch {} }
        _ = try await put(server, made.obj, file, 1)
        try await server.complete(obj: made.obj)
    }

    func testADelayedUploadHoldsItsSlotUntilItEnds() async throws {
        let sleeper = XferGateSleeper()
        let server = FakeFileV2Server(account: "alice", sleep: { await sleeper.sleep($0) })
        server.maxPartsInFlight = 2
        let size = Int64(FileV2Wire.partSize)
        let file = blob(73, length: 64 + 2 * size + 10)         // three parts
        let made = try await server.create(createRequest(file))
        XCTAssertEqual(made.maxParallelism, 2, "max_parallelism follows the in-flight cap when it is below 8")
        server.injectDelay(.putPart, ms: 500)
        let first = Task { try await self.put(server, made.obj, file, 0) }
        let second = Task { try await self.put(server, made.obj, file, 1) }
        await sleeper.waitUntilWaiting(2)
        let refused = await expectError(429, "too_many_parts_in_flight") { _ = try await self.put(server, made.obj, file, 2) }
        XCTAssertEqual(refused?.retryAfter, 1)
        XCTAssertEqual(refused?.disposition(for: .putPart), .retry(onExhausted: .rateLimited))
        XCTAssertNil(server.storedPart(obj: made.obj, part: 0), "an upload that is still in flight has marked nothing")
        sleeper.releaseAll()
        _ = try await first.value
        _ = try await second.value
        server.clearDelays()
        _ = try await put(server, made.obj, file, 2)
        try await server.complete(obj: made.obj)
        XCTAssertEqual(sleeper.log, [500, 500])
    }

    func testARetryOfAPartThatIsStillBeingUploadedWaitsAndThenIsADuplicate() async throws {
        let sleeper = XferGateSleeper()
        let server = FakeFileV2Server(account: "alice", sleep: { await sleeper.sleep($0) })
        let file = blob(74)
        let made = try await server.create(createRequest(file))
        server.injectDelay(.putPart, ms: 300)
        let original = Task { try await self.put(server, made.obj, file, 0) }
        await sleeper.waitUntilWaiting(1)
        server.clearDelays()
        let retry = Task { try await self.put(server, made.obj, file, 0) }
        await sleeper.waitUntilWaiting(2)           // the retry looks again after a poll: it waits for the part lock
        sleeper.releaseAll()
        let first = try await original.value
        XCTAssertFalse(first.duplicate)
        // the retry keeps polling until the original has ended and it can take the lock
        for _ in 0..<100 {
            if sleeper.waiting == 0 { break }
            sleeper.releaseAll()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = try await retry.value
        XCTAssertTrue(second.duplicate)
        XCTAssertEqual(second.received, 1)
    }

    func testARetryThatWaitsLongerThanTheLockWaitIsPartBusy() async throws {
        let sleeper = XferGateSleeper()
        sleeper.suspendFromMs = 1_000                  // only the long delay of the holder suspends; the retry's polls return at once
        let server = FakeFileV2Server(account: "alice", sleep: { await sleeper.sleep($0) })
        let file = blob(75)
        let made = try await server.create(createRequest(file))
        server.injectDelay(.putPart, ms: 1_000_000)
        let holder = Task { try await self.put(server, made.obj, file, 0) }
        await sleeper.waitUntilWaiting(1)
        server.clearDelays()
        let error = await expectError(429, "part_busy") { _ = try await self.put(server, made.obj, file, 0) }
        XCTAssertEqual(error?.retryAfter, 2)
        XCTAssertEqual(error?.disposition(for: .putPart), .retry(onExhausted: .rateLimited))
        XCTAssertEqual(sleeper.count(ms: 50), 100, "the lock wait is 5 seconds, looked at every 50 ms")
        sleeper.releaseAll()
        let result = try await holder.value
        XCTAssertFalse(result.duplicate)
        // the holder was not disturbed, and the slot of the refused retry was given back
        let again = try await put(server, made.obj, file, 0)
        XCTAssertTrue(again.duplicate)
    }

    func testTwoAccountsShareOneServerAndNothingElse() async throws {
        let clock = XferManualClock()
        let alice = FakeFileV2Server(clock: clock, account: "alice")
        let bob = alice.asAccount("bob")
        XCTAssertTrue((bob.clock as AnyObject) === (alice.clock as AnyObject))
        let file = blob(80)
        let a = try await alice.create(createRequest(file))
        _ = try await bob.create(createRequest(blob(81)))
        XCTAssertEqual(alice.objectCount, 2)
        let mine = try await alice.listUnfinished(limit: nil, after: nil)
        XCTAssertEqual(mine.objects.map { $0.obj }, [a.obj])
        _ = await expectError(403, "not_owner") { try await bob.delete(obj: a.obj) }
        _ = await expectError(403, "not_owner") { try await bob.complete(obj: a.obj) }
        let freed = try await bob.deleteUnfinished()
        XCTAssertEqual(freed.deleted, 1)
        XCTAssertEqual(alice.objectCount, 1)
        // the limits are the server's, whichever account sets them
        bob.maxIncomplete = 1
        XCTAssertEqual(alice.maxIncomplete, 1)
        XCTAssertEqual(alice.parallelism, 6)
    }

    func testAnAbortedOrStuckRequestIsNeverMistakenForASuccess() {
        let response = FakeWireResponse(status: 0)
        XCTAssertNil(response.errorCode)
        XCTAssertNil(response.stuck)
        let bug = FakeServerTestBug(text: "x")
        XCTAssertEqual(bug.description, "FakeFileV2Server test bug: x")
    }
}

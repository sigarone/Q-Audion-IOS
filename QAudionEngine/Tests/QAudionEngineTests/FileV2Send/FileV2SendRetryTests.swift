import XCTest
@testable import QAudionEngine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The error matrix of the parts protocol (docs/FILES_V2_PARTS_PROTOCOL.md, "Errors") as the pipeline applies it through the disposition
/// table of step 2a: what is retried (and after how long), what is waited for, what fails the transfer and whether its state is kept.
final class FileV2SendRetryTests: XCTestCase {

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        return rig
    }

    private func error(_ status: Int, _ code: String, retryAfter: Int? = nil) -> FileV2ServerError {
        FileV2ServerError(status: status, code: code, retryAfter: retryAfter)
    }

    // MARK: A part PUT that is retried

    func testAPartIsRetriedWithTheBackoffOfThePolicyAndOnTheServersRetryAfter() async throws {
        struct Case {
            let name: String
            let failure: Error
            let times: Int
            let delays: [Int64]
        }
        let cases: [Case] = [
            Case(name: "digest_mismatch", failure: error(400, "digest_mismatch"), times: 2, delays: [1000, 2000]),
            Case(name: "short_body", failure: error(400, "short_body"), times: 1, delays: [1000]),
            Case(name: "storage_error", failure: error(500, "storage_error"), times: 4, delays: [1000, 2000, 4000, 8000]),
            Case(name: "502 with another code", failure: error(502, "bad_gateway"), times: 1, delays: [1000]),
            Case(name: "part_busy 429 with Retry-After 2", failure: error(429, "part_busy", retryAfter: 2), times: 1, delays: [2000]),
            Case(name: "too_many_parts_in_flight 429 with Retry-After 1", failure: error(429, "too_many_parts_in_flight", retryAfter: 1),
                 times: 2, delays: [1000, 1000]),
            Case(name: "429 with Retry-After 300 is the longest wait", failure: error(429, "part_busy", retryAfter: 300), times: 1,
                 delays: [300_000]),
            Case(name: "425 is waited for and not counted", failure: error(425, "parts_not_yet_received", retryAfter: 3), times: 6,
                 delays: [3000, 3000, 3000, 3000, 3000, 3000]),
            Case(name: "425 with Retry-After 300 is the longest wait", failure: error(425, "parts_not_yet_received", retryAfter: 300), times: 1,
                 delays: [300_000]),
            Case(name: "a reset connection", failure: URLError(.networkConnectionLost), times: 1, delays: [1000]),
            Case(name: "a timeout", failure: URLError(.timedOut), times: 2, delays: [1000, 2000]),
            Case(name: "offline", failure: URLError(.notConnectedToInternet), times: 1, delays: [1000]),
            Case(name: "a POSIX error", failure: POSIXError(.ECONNRESET), times: 1, delays: [1000])
        ]
        for item in cases {
            let rig = try sequentialRig()
            let source = GeneratedSource(size: 700_000)
            rig.fake.injectFailure(.putPart, error: item.failure, times: item.times)
            let result = await (try rig.makePipeline()).send(rig.makeRequest(source))
            XCTAssertEqual(result, .sentOk, item.name)
            XCTAssertEqual(rig.sleeper.delays, item.delays, item.name)
            rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
            try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
        }
    }

    func testARetryAfterOfMoreThanFiveMinutesIsNotWaitedForTheTransferPausesWithItsStateKept() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: 700_000)
        rig.fake.injectFailure(.putPart, error: error(429, "part_busy", retryAfter: 301), times: 1)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "long-wait"))
        let failure = assertSendFailure(result, .rateLimited)
        XCTAssertTrue(failure?.keepsState ?? false)
        XCTAssertEqual(rig.sleeper.delays, [], "no automatic wait for 301 seconds: not cut down to 300 either")
        XCTAssertEqual(rig.server.puts.count, 1, "no hammering")
        XCTAssertEqual(try rig.journalNames(), ["long-wait.qsj"], "the state is kept")

        let resumed = await (try rig.makePipeline()).resume(transferID: "long-wait")
        XCTAssertEqual(resumed, .sentOk)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    func testA425WithARetryAfterOfMoreThanFiveMinutesIsNotWaitedForEitherAndIsNotCutDownTo300() async throws {
        // The same platform rule for every wait: above 300 s there is no automatic wait, whatever the status (425 is a wait, not a retry).
        let rig = try sequentialRig()
        let source = GeneratedSource(size: 700_000)
        rig.fake.injectFailure(.putPart, error: error(425, "parts_not_yet_received", retryAfter: 301), times: 1)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "long-425"))
        let failure = assertSendFailure(result, .network)
        XCTAssertTrue(failure?.keepsState ?? false)
        XCTAssertEqual(rig.sleeper.delays, [], "no wait at all")
        XCTAssertEqual(rig.server.puts.count, 1, "no hammering")
        XCTAssertEqual(try rig.journalNames(), ["long-425.qsj"], "the state is kept")
        let resumed = await (try rig.makePipeline()).resume(transferID: "long-425")
        XCTAssertEqual(resumed, .sentOk)
    }

    func testAPartThatKeepsFailingPausesTheTransferAfterTheAttemptsAreSpentAndItsStateIsKept() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: 700_000)
        rig.fake.injectFailure(.putPart, error: error(503, "files_unavailable"), times: 5)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "paused"))
        let failure = assertSendFailure(result, .network)
        XCTAssertTrue(failure?.keepsState ?? false)
        XCTAssertEqual(rig.sleeper.delays, [1000, 2000, 4000, 8000], "four waits for five failed attempts")
        XCTAssertEqual(try rig.journalNames(), ["paused.qsj"])
        XCTAssertEqual(rig.wrapper.count, 2)
        XCTAssertEqual(rig.fake.objectCount, 1, "the object stays: the transfer is paused, not cancelled")

        let list = await (try rig.makePipeline()).listResumable()
        XCTAssertEqual(list.map { $0.transferID }, ["paused"])
        let resumed = await (try rig.makePipeline()).resume(transferID: "paused")
        XCTAssertEqual(resumed, .sentOk)
        try rig.assertNothingIsLeftBehind()
    }

    func testTooManyRetriesOf429AreRateLimitedNotNetwork() async throws {
        let rig = try sequentialRig()
        rig.fake.injectFailure(.putPart, error: error(429, "too_many_parts_in_flight", retryAfter: 1), times: 5)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        assertSendFailure(result, .rateLimited)
    }

    // MARK: A part PUT that fails the transfer

    func testAnAnswerThatCannotBeRetriedFailsTheTransferWithTheReasonOfTheTaxonomy() async throws {
        struct Case {
            let name: String
            let failure: FileV2ServerError
            let reason: FileV2SendFailure.Reason
            let keepsState: Bool
        }
        let cases: [Case] = [
            Case(name: "402", failure: error(402, "entitlement_required"), reason: .entitlement, keepsState: true),
            Case(name: "403 not_owner", failure: error(403, "not_owner"), reason: .auth, keepsState: true),
            Case(name: "413", failure: error(413, "quota_exceeded"), reason: .quota, keepsState: false),
            Case(name: "507", failure: error(507, "insufficient_storage", retryAfter: 60), reason: .serverFull, keepsState: true),
            Case(name: "400 bad_part", failure: error(400, "bad_part"), reason: .badRequest, keepsState: false),
            Case(name: "405", failure: error(405, "method_not_allowed"), reason: .badRequest, keepsState: false),
            Case(name: "411", failure: error(411, "length_required"), reason: .badRequest, keepsState: false),
            Case(name: "418", failure: error(418, "teapot"), reason: .badRequest, keepsState: false),
            Case(name: "an unusable code", failure: FileV2ServerError(status: 418, code: "Not A Code!"), reason: .badRequest, keepsState: false)
        ]
        for item in cases {
            let rig = try sequentialRig()
            rig.fake.injectFailure(.putPart, error: item.failure, times: 1)
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "fails"))
            let failure = assertSendFailure(result, item.reason)
            XCTAssertEqual(failure?.keepsState, item.keepsState, item.name)
            XCTAssertEqual(rig.sleeper.delays, [], "\(item.name): no retry")
            XCTAssertEqual(rig.server.puts.count, 1, item.name)
            if item.keepsState {
                XCTAssertEqual(try rig.journalNames(), ["fails.qsj"], item.name)
            } else {
                try rig.assertNothingIsLeftBehind()
                XCTAssertEqual(rig.fake.objectCount, 0, "\(item.name): the object is deleted")
            }
        }
    }

    func testA401IsRepeatedAfterTheAccessTokenIsRefreshedAndIsAuthFailureWithoutARefresher() async throws {
        let refreshed = FileV2Locked(0)
        let rig = try sequentialRig()
        rig.refreshAuth = { refreshed.withValue { $0 += 1 }; return true }
        rig.fake.injectFailure(.putPart, error: error(401, "unauthorized"), times: 1)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(refreshed.withValue { $0 }, 1)
        XCTAssertEqual(rig.sleeper.delays, [], "no backoff for a refresh")

        let without = try sequentialRig()
        without.fake.injectFailure(.putPart, error: error(401, "unauthorized"), times: 1)
        let failed = await (try without.makePipeline()).send(without.makeRequest(GeneratedSource(size: 700_000)))
        assertSendFailure(failed, .auth)

        let refuses = try sequentialRig()
        refuses.refreshAuth = { false }
        refuses.fake.injectFailure(.putPart, error: error(401, "unauthorized"), times: 1)
        assertSendFailure(await (try refuses.makePipeline()).send(refuses.makeRequest(GeneratedSource(size: 700_000))), .auth)

        let loops = try sequentialRig()
        let calls = FileV2Locked(0)
        loops.refreshAuth = { calls.withValue { $0 += 1 }; return true }
        loops.fake.injectFailure(.putPart, error: error(401, "unauthorized"), times: 10)
        assertSendFailure(await (try loops.makePipeline()).send(loops.makeRequest(GeneratedSource(size: 700_000))), .auth)
        XCTAssertEqual(calls.withValue { $0 }, 2, "a token that keeps being refused is refreshed twice and then it is an auth failure")
    }

    func testA404OnAPartMeansTheObjectIsGoneAndItIsMadeAgain() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.fake.injectFailure(.putPart, error: error(404, "not_found"), times: 1, part: 1)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(rig.telemetry.count { $0 == .objectRecreated }, 1)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .create }.count, 2, "create is called again, idempotent on the header")
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    func testAnObjectThatIsGoneEveryTimeStopsAfterTheRecreationsAreSpent() async throws {
        let rig = try sequentialRig()
        rig.fake.injectFailure(.putPart, error: error(404, "not_found"), times: 100)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        assertSendFailure(result, .network)
        XCTAssertEqual(rig.telemetry.count { $0 == .objectRecreated }, rig.configuration.maxObjectRecreations)
    }

    // MARK: Create

    func testCreateIsRetriedWhenTheServerIsBusyAndFailsForAnAccountReasonWithNothingLeftBehind() async throws {
        struct Case {
            let name: String
            let failure: FileV2ServerError
            let times: Int
            let outcome: FileV2SendFailure.Reason?
            let delays: [Int64]
        }
        let cases: [Case] = [
            Case(name: "create_busy", failure: error(429, "create_busy", retryAfter: 2), times: 1, outcome: nil, delays: [2000]),
            Case(name: "files_unavailable", failure: error(503, "files_unavailable"), times: 2, outcome: nil, delays: [1000, 2000]),
            Case(name: "402", failure: error(402, "entitlement_required"), times: 1, outcome: .entitlement, delays: []),
            Case(name: "507", failure: error(507, "insufficient_storage", retryAfter: 60), times: 1, outcome: .serverFull, delays: []),
            Case(name: "413 blob_too_large", failure: error(413, "blob_too_large"), times: 1, outcome: .quota, delays: []),
            Case(name: "403", failure: error(403, "not_owner"), times: 1, outcome: .auth, delays: []),
            Case(name: "400", failure: error(400, "bad_blob_len"), times: 1, outcome: .badRequest, delays: [])
        ]
        for item in cases {
            let rig = try sequentialRig()
            rig.fake.injectFailure(.create, error: item.failure, times: item.times)
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "create-error"))
            if let reason = item.outcome {
                assertSendFailure(result, reason)
                try rig.assertNothingIsLeftBehind()
                XCTAssertEqual(rig.fake.objectCount, 0, item.name)
                XCTAssertEqual(rig.server.puts.count, 0, item.name)
            } else {
                XCTAssertEqual(result, .sentOk, item.name)
            }
            XCTAssertEqual(rig.sleeper.delays, item.delays, item.name)
        }
    }

    func testACreateThatKeepsFailingOnTheNetworkKeepsTheStateBecauseTheObjectMayExist() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: 700_000)
        // The create reaches the server and its answer is lost every time: the object may exist, and the header is what finds it again.
        rig.fake.injectFailure(.create, error: URLError(.networkConnectionLost), times: 5, when: .afterEffect)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "create-lost"))
        assertSendFailure(result, .network)
        XCTAssertEqual(try rig.journalNames(), ["create-lost.qsj"])
        XCTAssertEqual(rig.fake.objectCount, 1)
        let resumed = await (try rig.makePipeline()).resume(transferID: "create-lost")
        XCTAssertEqual(resumed, .sentOk)
        XCTAssertEqual(rig.fake.objectCount, 1, "found again by its header, not made twice")
    }

    func testAnAnswerOfCreateThatDoesNotDescribeTheObjectIsRefused() async throws {
        // A server that answers 200 with another part size is not a server this client speaks to.
        final class Wrong: FileV2Server, @unchecked Sendable {
            let inner: RecordingServer
            init(inner: RecordingServer) { self.inner = inner }
            func create(_ request: FileV2CreateRequest) async throws -> FileV2Created {
                let real = try await inner.create(request)
                return FileV2Created(obj: real.obj, blobLength: real.blobLength, partSize: real.partSize * 2, parts: real.parts,
                                     parallelism: real.parallelism, maxParallelism: real.maxParallelism, token: real.token,
                                     existing: false, received: 0, complete: false)
            }
            func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult {
                try await inner.putPart(obj: obj, part: part, body: body, sha256: sha256)
            }
            func partsMap(obj: String) async throws -> FileV2PartsMap { try await inner.partsMap(obj: obj) }
            func complete(obj: String) async throws { try await inner.complete(obj: obj) }
            func delete(obj: String) async throws { try await inner.delete(obj: obj) }
            func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken {
                try await inner.issueToken(obj: obj, scope: scope)
            }
            func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage {
                try await inner.listUnfinished(limit: limit, after: after)
            }
            func deleteUnfinished() async throws -> FileV2BulkDeleteResult { try await inner.deleteUnfinished() }
            func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?, waitSeconds: Int) async throws
                -> FileV2RangeResult {
                try await inner.fetchRange(obj: obj, from: from, toInclusive: toInclusive, token: token, waitSeconds: waitSeconds)
            }
        }
        let rig = try sequentialRig()
        let deps = FileV2SendDependencies(server: Wrong(inner: rig.server), store: try rig.makeStore(), secrets: rig.wrapper,
                                          sources: rig.sources, channel: rig.channel, clock: rig.clock, sleeper: rig.sleeper)
        let result = await FileV2SendPipeline(dependencies: deps, configuration: rig.configuration)
            .send(rig.makeRequest(GeneratedSource(size: 700_000)))
        assertSendFailure(result, .badRequest)
        XCTAssertEqual(rig.server.puts.count, 0)
    }

    // MARK: Complete and the token

    func testCompleteThatFindsPartsMissingSendsThemAndCompletesAgain() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.swallowPut(part: 1)                                       // the server said "stored" for part 1 and had lost it
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .complete }.count, 2, "the first complete was a 409 incomplete")
        XCTAssertEqual(SendEventAnalysis.putStarts(rig.log.events), [0, 1, 2, 1], "part 1 is sent again")
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    func testCompleteThatKeepsBeingIncompleteGivesUpAfterTheRounds() async throws {
        let rig = try sequentialRig()
        rig.fake.injectFailure(.complete, error: FileV2ServerError(status: 409, code: "incomplete", missing: [0]), times: 100)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        assertSendFailure(result, .badRequest)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .complete }.count, rig.configuration.maxCompleteRounds + 1)
    }

    func testCompleteIsRetriedOnA5xxAndAnObjectGoneAtCompleteIsMadeAgain() async throws {
        let rig = try sequentialRig()
        rig.fake.injectFailure(.complete, error: error(500, "storage_error"), times: 2)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(rig.sleeper.delays, [1000, 2000])

        let gone = try sequentialRig()
        gone.fake.injectFailure(.complete, error: error(404, "not_found"), times: 1)
        let source = GeneratedSource(size: 700_000)
        let goneResult = await (try gone.makePipeline()).send(gone.makeRequest(source))
        XCTAssertEqual(goneResult, .sentOk)
        XCTAssertEqual(gone.telemetry.count { $0 == .objectRecreated }, 1)
        try gone.assertBlobEqualsOneShot(descriptor: try gone.lastDescriptor(), source: source)
    }

    func testAMissingTokenIsIssuedBeforeTheDescriptorGoesOut() async throws {
        let rig = try sequentialRig()
        rig.server.setStripCreateTokens(true)                                // the answer of create carries no token
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .issueToken }.count, 1)
        XCTAssertNotNil(try rig.lastDescriptor().source.token)
    }

    func testATokenAboutToExpireIsReplacedBeforeTheDescriptorGoesOut() async throws {
        let rig = try sequentialRig()
        rig.channel.setOutcomes([.unavailable, .sent])
        let first = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "stale-token"))
        assertSendFailure(first, .announceNotSent)
        let oldToken = try rig.lastDescriptor().source.token?.v

        // Six days and twenty-three and a half hours later: the 7-day token has 30 minutes left, under the hour of margin. The create of the
        // resume brings no token (stripped), so the one in the journal is judged by its expiry.
        rig.clock.advance(ms: (6 * 24 * 3600 + 23 * 3600 + 1800) * 1000)
        rig.server.setStripCreateTokens(true)
        let second = await (try rig.makePipeline()).resume(transferID: "stale-token")
        XCTAssertEqual(second, .sentOk)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .issueToken }.count, 1)
        let newToken = try rig.lastDescriptor().source.token
        XCTAssertNotEqual(newToken?.v, oldToken)
        XCTAssertGreaterThan(newToken?.exp ?? 0, rig.clock.nowMs() + 3_600_000)
        try rig.assertNothingIsLeftBehind()
    }
}

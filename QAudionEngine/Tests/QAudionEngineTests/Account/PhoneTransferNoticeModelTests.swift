import XCTest
@testable import QAudionEngine

private final class FakePhoneTransferApi: PhoneTransferApi, @unchecked Sendable {
    var listResult: Result<[PhoneTransferPending], Error> = .success([])
    var cancelResult: Result<Void, Error> = .success(())
    private(set) var fetchCount = 0
    private(set) var cancelledIds: [String] = []

    func fetchPending() async throws -> [PhoneTransferPending] {
        fetchCount += 1
        return try listResult.get()
    }

    func cancel(id: String) async throws {
        cancelledIds.append(id)
        try cancelResult.get()
    }
}

@MainActor
final class PhoneTransferNoticeModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func transfer(_ id: String, hoursLeft: Double) -> PhoneTransferPending {
        PhoneTransferPending(id: id, expiresAt: t0.addingTimeInterval(hoursLeft * 3600))
    }

    private func makeModel(_ api: FakePhoneTransferApi) -> PhoneTransferNoticeModel {
        let reference = t0
        return PhoneTransferNoticeModel(api: api, now: { reference })
    }

    // MARK: - List

    func test_emptyList_showsNothing() async {
        let api = FakePhoneTransferApi()
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
    }

    func test_list_showsTheEntryThatExpiresFirst() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("late", hoursLeft: 40), transfer("soon", hoursLeft: 5)])
        let model = makeModel(api)
        await model.refresh()
        XCTAssertEqual(model.current(at: t0)?.id, "soon")
    }

    func test_expiredEntries_areNotShown() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("gone", hoursLeft: -1), transfer("edge", hoursLeft: 0)])
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNil(model.current(at: t0))
        XCTAssertTrue(model.transfers.isEmpty)
    }

    func test_entryHidesWhenItsTimeIsUp() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 2)])
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNotNil(model.current(at: t0.addingTimeInterval(3600)))
        XCTAssertNil(model.current(at: t0.addingTimeInterval(2 * 3600)))
    }

    func test_list404_hidesTheEntryWithoutAMessage() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNotNil(model.current(at: t0))

        api.listResult = .failure(BCryptoError.httpError(404))
        await model.refresh()
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
    }

    func test_networkError_keepsTheEntryAndAllowsARetry() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.listResult = .failure(URLError(.notConnectedToInternet))
        await model.refresh()
        XCTAssertEqual(model.current(at: t0)?.id, "a")
        XCTAssertEqual(model.problem, .refreshFailed)

        api.listResult = .success([transfer("a", hoursLeft: 10)])
        await model.refresh()
        XCTAssertEqual(model.current(at: t0)?.id, "a")
        XCTAssertNil(model.problem)
    }

    func test_serverError_keepsTheEntry() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.listResult = .failure(BCryptoError.httpError(503))
        await model.refresh()
        XCTAssertEqual(model.current(at: t0)?.id, "a")
        XCTAssertEqual(model.problem, .refreshFailed)
    }

    func test_refreshFailureWithNothingOnScreen_staysSilent() async {
        let api = FakePhoneTransferApi()
        api.listResult = .failure(URLError(.notConnectedToInternet))
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
    }

    func test_signedOut_clearsSilently() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.listResult = .failure(BCryptoError.unauthorized)
        await model.refresh()
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
    }

    func test_reset_dropsEverything() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()
        model.reset()
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
    }

    // MARK: - Cancel

    func test_cancel_callsTheServerAndHidesTheEntry() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.listResult = .success([])
        await model.cancel()
        XCTAssertEqual(api.cancelledIds, ["a"])
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
        XCTAssertFalse(model.isCancelling)
        XCTAssertEqual(api.fetchCount, 2, "the state is read again after the cancel")
    }

    func test_cancel_neverShowsACancelledEntryAgain() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        // The list still contains the entry when it is read again after the cancel.
        await model.cancel()
        XCTAssertNil(model.current(at: t0))
    }

    func test_cancel_showsTheNextEntryWhenThereAreSeveral() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("first", hoursLeft: 5), transfer("second", hoursLeft: 30)])
        let model = makeModel(api)
        await model.refresh()
        await model.cancel()
        XCTAssertEqual(api.cancelledIds, ["first"])
        XCTAssertEqual(model.current(at: t0)?.id, "second")
    }

    func test_cancel404_hidesTheEntryWithoutAMessage() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.cancelResult = .failure(BCryptoError.httpError(404))
        api.listResult = .success([])
        await model.cancel()
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
    }

    func test_cancelNetworkError_keepsTheEntryAndAllowsARetry() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.cancelResult = .failure(URLError(.timedOut))
        await model.cancel()
        XCTAssertEqual(model.current(at: t0)?.id, "a")
        XCTAssertEqual(model.problem, .cancelFailed)
        XCTAssertFalse(model.isCancelling)

        api.cancelResult = .success(())
        api.listResult = .success([])
        await model.cancel()
        XCTAssertNil(model.current(at: t0))
        XCTAssertNil(model.problem)
        XCTAssertEqual(api.cancelledIds, ["a", "a"])
    }

    func test_cancelWithNothingOnScreen_doesNothing() async {
        let api = FakePhoneTransferApi()
        let model = makeModel(api)
        await model.cancel()
        XCTAssertTrue(api.cancelledIds.isEmpty)
    }

    // MARK: - Hours left

    func test_hoursRemaining_roundsUpAndNeverReadsZeroWhileTimeRemains() {
        let now = t0
        func hours(_ seconds: TimeInterval) -> Int {
            PhoneTransferPending(id: "x", expiresAt: now.addingTimeInterval(seconds)).hoursRemaining(at: now)
        }
        XCTAssertEqual(hours(48 * 3600), 48)
        XCTAssertEqual(hours(48 * 3600 - 60), 48)
        XCTAssertEqual(hours(47 * 3600 + 1), 48)
        XCTAssertEqual(hours(3600), 1)
        XCTAssertEqual(hours(3601), 2)
        XCTAssertEqual(hours(60), 1)
        XCTAssertEqual(hours(0), 0)
        XCTAssertEqual(hours(-5), 0)
    }

    func test_isExpired_atTheExactInstantAndAfter() {
        let entry = PhoneTransferPending(id: "x", expiresAt: t0)
        XCTAssertFalse(entry.isExpired(at: t0.addingTimeInterval(-1)))
        XCTAssertTrue(entry.isExpired(at: t0))
        XCTAssertTrue(entry.isExpired(at: t0.addingTimeInterval(1)))
    }
}

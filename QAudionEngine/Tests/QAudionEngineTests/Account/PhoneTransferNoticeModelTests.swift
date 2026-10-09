import XCTest
@testable import QAudionEngine

private final class FakePhoneTransferApi: PhoneTransferApi, @unchecked Sendable {
    private let lock = NSLock()
    private var _listResult: Result<[PhoneTransferPending], Error> = .success([])
    private var _cancelResult: Result<Void, Error> = .success(())
    private var _fetchCount = 0
    private var _running = 0
    private var _maxRunning = 0
    private var _cancelledIds: [String] = []
    private var _hold = false
    private var _waiting: [CheckedContinuation<Void, Never>] = []

    var listResult: Result<[PhoneTransferPending], Error> {
        get { lock.withLock { _listResult } }
        set { lock.withLock { _listResult = newValue } }
    }
    var cancelResult: Result<Void, Error> {
        get { lock.withLock { _cancelResult } }
        set { lock.withLock { _cancelResult = newValue } }
    }
    var fetchCount: Int { lock.withLock { _fetchCount } }
    var maxRunning: Int { lock.withLock { _maxRunning } }
    var cancelledIds: [String] { lock.withLock { _cancelledIds } }

    /// While true, `fetchPending` suspends until `release()`.
    func hold(_ value: Bool) { lock.withLock { _hold = value } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let list = _waiting
            _waiting = []
            return list
        }
        waiting.forEach { $0.resume() }
    }

    /// How many calls are suspended inside `fetchPending` (safe to `release()` once it is the expected number).
    var waitingCount: Int { lock.withLock { _waiting.count } }

    func fetchPending() async throws -> [PhoneTransferPending] {
        // The answer is the one current when the call starts, like a server that answers at that instant.
        let (shouldHold, result) = lock.withLock { () -> (Bool, Result<[PhoneTransferPending], Error>) in
            _fetchCount += 1
            _running += 1
            _maxRunning = max(_maxRunning, _running)
            return (_hold, _listResult)
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { _waiting.append(continuation) }
            }
        }
        lock.withLock { _running -= 1 }
        return try result.get()
    }

    func cancel(id: String) async throws {
        lock.withLock { _cancelledIds.append(id) }
        try cancelResult.get()
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _date: Date

    init(_ date: Date) { _date = date }

    var date: Date {
        get { lock.withLock { _date } }
        set { lock.withLock { _date = newValue } }
    }
}

@MainActor
final class PhoneTransferNoticeModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func transfer(_ id: String, hoursLeft: Double) -> PhoneTransferPending {
        PhoneTransferPending(id: id, expiresAt: t0.addingTimeInterval(hoursLeft * 3600))
    }

    private func makeModel(_ api: FakePhoneTransferApi, clock: FakeClock? = nil) -> PhoneTransferNoticeModel {
        let source = clock ?? FakeClock(t0)
        return PhoneTransferNoticeModel(api: api, minRefreshInterval: 30, now: { source.date })
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - List

    func test_emptyList_showsNothing() async {
        let api = FakePhoneTransferApi()
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNil(model.current)
        XCTAssertNil(model.problem)
    }

    func test_list_showsTheEntryThatExpiresFirst() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("late", hoursLeft: 40), transfer("soon", hoursLeft: 5)])
        let model = makeModel(api)
        await model.refresh()
        XCTAssertEqual(model.current?.id, "soon")
    }

    func test_theDeviceClockNeverRemovesAnEntry() async {
        // The server lists it, so it is live, whatever this device thinks the time is.
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("ahead", hoursLeft: -3)])
        let clock = FakeClock(t0.addingTimeInterval(10 * 86_400))
        let model = makeModel(api, clock: clock)
        await model.refresh()
        XCTAssertEqual(model.current?.id, "ahead")
    }

    func test_anEntryWithAPastExpiryCanStillBeCancelled() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("ahead", hoursLeft: -3)])
        let model = makeModel(api)
        await model.refresh()
        api.listResult = .success([])
        await model.cancel()
        XCTAssertEqual(api.cancelledIds, ["ahead"])
        XCTAssertNil(model.current)
    }

    func test_list404_hidesTheEntryWithoutAMessage() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNotNil(model.current)

        api.listResult = .failure(BCryptoError.httpError(404))
        await model.refresh()
        XCTAssertNil(model.current)
        XCTAssertNil(model.problem)
    }

    func test_networkError_keepsTheEntryAndAllowsARetry() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.listResult = .failure(URLError(.notConnectedToInternet))
        await model.refresh()
        XCTAssertEqual(model.current?.id, "a")
        XCTAssertEqual(model.problem, .refreshFailed)

        api.listResult = .success([transfer("a", hoursLeft: 10)])
        await model.refresh()
        XCTAssertEqual(model.current?.id, "a")
        XCTAssertNil(model.problem)
    }

    func test_serverError_keepsTheEntry() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.listResult = .failure(BCryptoError.httpError(503))
        await model.refresh()
        XCTAssertEqual(model.current?.id, "a")
        XCTAssertEqual(model.problem, .refreshFailed)
    }

    func test_refreshFailureWithNothingOnScreen_staysSilent() async {
        let api = FakePhoneTransferApi()
        api.listResult = .failure(URLError(.notConnectedToInternet))
        let model = makeModel(api)
        await model.refresh()
        XCTAssertNil(model.current)
        XCTAssertNil(model.problem)
    }

    func test_signedOut_clearsSilently() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.listResult = .failure(BCryptoError.unauthorized)
        await model.refresh()
        XCTAssertNil(model.current)
        XCTAssertNil(model.problem)
    }

    func test_reset_dropsEverything() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()
        model.reset()
        XCTAssertNil(model.current)
        XCTAssertTrue(model.transfers.isEmpty)
        XCTAssertNil(model.problem)
    }

    func test_resetDuringARequest_dropsItsAnswer() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        api.hold(true)
        let model = makeModel(api)
        let running = Task { await model.refresh() }
        await waitUntil { api.waitingCount == 1 }
        model.reset()
        api.hold(false)
        api.release()
        await running.value
        XCTAssertNil(model.current, "the answer belongs to the account that left")
    }

    // MARK: - Coalescing and minimum interval

    func test_aRefreshAskedWhileOneRuns_sharesIt() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        api.hold(true)
        let model = makeModel(api)
        let first = Task { await model.refresh() }
        await waitUntil { api.waitingCount == 1 }
        let second = Task { await model.refresh(throttled: true) }
        let third = Task { await model.refresh(throttled: true) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        api.hold(false)
        api.release()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(api.fetchCount, 1, "throttled requests share the one in flight")
        XCTAssertEqual(model.current?.id, "a")
    }

    func test_aRefreshThatMustNotBeMissed_repeatsOnceAfterTheRunningOne_neverOverlapping() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([])
        api.hold(true)
        let model = makeModel(api)
        let first = Task { await model.refresh() }
        await waitUntil { api.waitingCount == 1 }
        // The notice arrives while an older request, which may predate the transfer, is still running.
        api.listResult = .success([transfer("new", hoursLeft: 40)])
        let notice = Task { await model.refresh() }
        let notice2 = Task { await model.refresh() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        api.hold(false)
        api.release()
        await first.value
        await notice.value
        await notice2.value
        XCTAssertEqual(api.fetchCount, 2, "one repeat, however many notices arrived")
        XCTAssertEqual(api.maxRunning, 1, "requests never overlap")
        XCTAssertEqual(model.current?.id, "new")
    }

    func test_throttledRefresh_isSkippedWithinTheMinimumInterval() async {
        let api = FakePhoneTransferApi()
        let clock = FakeClock(t0)
        let model = makeModel(api, clock: clock)

        await model.refresh(throttled: true)
        XCTAssertEqual(api.fetchCount, 1, "the first one always goes")

        clock.date = t0.addingTimeInterval(10)
        await model.refresh(throttled: true)
        XCTAssertEqual(api.fetchCount, 1)

        clock.date = t0.addingTimeInterval(29.9)
        await model.refresh(throttled: true)
        XCTAssertEqual(api.fetchCount, 1)

        clock.date = t0.addingTimeInterval(30)
        await model.refresh(throttled: true)
        XCTAssertEqual(api.fetchCount, 2)
    }

    func test_unthrottledRefresh_alwaysGoes() async {
        let api = FakePhoneTransferApi()
        let model = makeModel(api)
        await model.refresh()
        await model.refresh()
        await model.refresh()
        XCTAssertEqual(api.fetchCount, 3, "launch, notice, retry and the read after a cancel are never throttled")
    }

    func test_throttledRefresh_afterTheClockWentBack_isNotStuck() async {
        let api = FakePhoneTransferApi()
        let clock = FakeClock(t0)
        let model = makeModel(api, clock: clock)
        await model.refresh(throttled: true)
        clock.date = t0.addingTimeInterval(-3600)
        await model.refresh(throttled: true)
        XCTAssertEqual(api.fetchCount, 2)
    }

    func test_reset_clearsTheMinimumInterval() async {
        let api = FakePhoneTransferApi()
        let model = makeModel(api)
        await model.refresh(throttled: true)
        model.reset()
        await model.refresh(throttled: true)
        XCTAssertEqual(api.fetchCount, 2, "a new account reads at once")
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
        XCTAssertNil(model.current)
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
        XCTAssertNil(model.current)
    }

    func test_cancel_showsTheNextEntryWhenThereAreSeveral() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("first", hoursLeft: 5), transfer("second", hoursLeft: 30)])
        let model = makeModel(api)
        await model.refresh()
        await model.cancel()
        XCTAssertEqual(api.cancelledIds, ["first"])
        XCTAssertEqual(model.current?.id, "second")
    }

    func test_cancel404_hidesTheEntryWithoutAMessage() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.cancelResult = .failure(BCryptoError.httpError(404))
        api.listResult = .success([])
        await model.cancel()
        XCTAssertNil(model.current)
        XCTAssertNil(model.problem)
    }

    func test_cancelNetworkError_keepsTheEntryAndAllowsARetry() async {
        let api = FakePhoneTransferApi()
        api.listResult = .success([transfer("a", hoursLeft: 10)])
        let model = makeModel(api)
        await model.refresh()

        api.cancelResult = .failure(URLError(.timedOut))
        await model.cancel()
        XCTAssertEqual(model.current?.id, "a")
        XCTAssertEqual(model.problem, .cancelFailed)
        XCTAssertFalse(model.isCancelling)

        api.cancelResult = .success(())
        api.listResult = .success([])
        await model.cancel()
        XCTAssertNil(model.current)
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

    func test_hoursRemaining_roundsDown_andZeroMeansLessThanAnHour() {
        let now = t0
        func hours(_ seconds: TimeInterval) -> Int {
            PhoneTransferPending(id: "x", expiresAt: now.addingTimeInterval(seconds)).hoursRemaining(at: now)
        }
        XCTAssertEqual(hours(48 * 3600), 48)
        XCTAssertEqual(hours(48 * 3600 - 1), 47)
        XCTAssertEqual(hours(47 * 3600 + 59 * 60), 47)
        XCTAssertEqual(hours(3600), 1)
        XCTAssertEqual(hours(3599), 0)
        XCTAssertEqual(hours(60), 0)
        XCTAssertEqual(hours(0), 0)
        XCTAssertEqual(hours(-5), 0)
        XCTAssertEqual(hours(-100 * 3600), 0)
    }

    // MARK: - account_notice

    func test_notice_onlyThePendingCodeStartsARead() {
        XCTAssertTrue(PhoneTransferNotice.isPending(["code": "phone_transfer_pending"]))
        XCTAssertTrue(PhoneTransferNotice.isPending([
            "code": "phone_transfer_pending", "transfer_id": "t-1", "expires_at": "2026-10-11T10:00:00Z",
        ]))
    }

    func test_notice_otherCodesAreIgnored() {
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": "phone_moved"]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": "phone_transfer_done"]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": "something_new"]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": ""]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": "PHONE_TRANSFER_PENDING"]))
    }

    func test_notice_malformedPayloadsAreIgnored() {
        XCTAssertFalse(PhoneTransferNotice.isPending([:]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": 7]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": NSNull()]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["code": ["phone_transfer_pending"]]))
        XCTAssertFalse(PhoneTransferNotice.isPending(["transfer_id": "t-1"]))
    }
}

import XCTest
@testable import QAudionEngine

private final class FakeApprovalApi: DeviceApprovalApi, @unchecked Sendable {
    private let lock = NSLock()
    private var _list: Result<[LoginApprovalRequest], Error> = .success([])
    private var _approve: Result<ApprovalResult, Error> = .success(.done)
    private var _deny: Result<ApprovalResult, Error> = .success(.done)
    private var _approvedWith: [(String, String)] = []
    private var _denied: [String] = []
    private var _hold = false
    private var _waiting: [CheckedContinuation<Void, Never>] = []

    func setList(_ value: Result<[LoginApprovalRequest], Error>) { lock.withLock { _list = value } }
    func setApprove(_ value: Result<ApprovalResult, Error>) { lock.withLock { _approve = value } }
    func setDeny(_ value: Result<ApprovalResult, Error>) { lock.withLock { _deny = value } }
    var approvedWith: [(String, String)] { lock.withLock { _approvedWith } }
    var denied: [String] { lock.withLock { _denied } }
    func hold(_ value: Bool) { lock.withLock { _hold = value } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let list = _waiting
            _waiting = []
            return list
        }
        waiting.forEach { $0.resume() }
    }

    private func gate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Reading the hold and parking happen under one lock: a `release()` cannot fall between them.
            let parked = lock.withLock { () -> Bool in
                guard _hold else { return false }
                _waiting.append(continuation)
                return true
            }
            if !parked { continuation.resume() }
        }
    }

    func fetchPending() async throws -> [LoginApprovalRequest] { try lock.withLock { _list }.get() }

    func approve(id: String, matchCode: String) async throws -> ApprovalResult {
        lock.withLock { _approvedWith.append((id, matchCode)) }
        await gate()
        return try lock.withLock { _approve }.get()
    }

    func deny(id: String) async throws -> ApprovalResult {
        lock.withLock { _denied.append(id) }
        await gate()
        return try lock.withLock { _deny }.get()
    }

    func revokeOthers() async throws -> PasswordChangeResult {
        PasswordChangeResult(accessToken: "a", refreshToken: "r", expiresIn: 900, deviceId: "d")
    }
    func listDevices() async throws -> [AccountDevice] { [] }
    func revokeDevice(id: String) async throws {}
}

@MainActor
final class LoginApprovalModelTests: XCTestCase {

    private func request(_ id: String, at seconds: TimeInterval? = 0) -> LoginApprovalRequest {
        LoginApprovalRequest(id: id, deviceName: "iPhone", platform: "ios", area: "Italia, rete mobile",
                             createdAt: seconds.map { Date(timeIntervalSince1970: 1_793_786_400 + $0) },
                             choices: ["12", "47", "83"])
    }

    private func make(_ api: FakeApprovalApi, entries: [LoginApprovalRequest]) async -> LoginApprovalModel {
        api.setList(.success(entries))
        let model = LoginApprovalModel(api: api)
        await model.refresh()
        return model
    }

    /// Waits for the model to start a request; a model that never does fails the test instead of hanging the run.
    private func waitUntilBusy(_ model: LoginApprovalModel, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !model.isBusy {
            guard Date() < deadline else {
                XCTFail("the model never became busy", file: file, line: line)
                return false
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }

    func test_emptyList_showsNothing() async {
        let model = await make(FakeApprovalApi(), entries: [])
        XCTAssertNil(model.current)
    }

    func test_shows_theOldestEntry() async {
        let model = await make(FakeApprovalApi(), entries: [request("new", at: 60), request("old", at: 0), request("nodate", at: nil)])
        XCTAssertEqual(model.current?.id, "old")
    }

    func test_approve_sendsTheTappedNumber_andRemovesTheEntry() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        await model.approve(id: "p-1", choice: "47")
        XCTAssertEqual(api.approvedWith.first?.0, "p-1")
        XCTAssertEqual(api.approvedWith.first?.1, "47")
        XCTAssertNil(model.current)
        XCTAssertEqual(model.outcome, .approved)
        XCTAssertFalse(model.isBusy)
    }

    func test_wrongNumber_closesTheEntryWithItsOwnOutcome() async {
        let api = FakeApprovalApi()
        api.setApprove(.success(.wrongCode))
        let model = await make(api, entries: [request("p-1")])
        await model.approve(id: "p-1", choice: "12")
        XCTAssertNil(model.current, "no retry: the server denied the entry")
        XCTAssertEqual(model.outcome, .wrongCode)
    }

    func test_alreadyResolvedAndGone_removeTheEntry() async {
        for result in [ApprovalResult.alreadyResolved, .gone] {
            let api = FakeApprovalApi()
            api.setApprove(.success(result))
            let model = await make(api, entries: [request("p-1")])
            await model.approve(id: "p-1", choice: "47")
            XCTAssertNil(model.current)
            XCTAssertEqual(model.outcome, .alreadyResolved)
        }
    }

    func test_deny_removesTheEntry() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        await model.deny(id: "p-1")
        XCTAssertEqual(api.denied, ["p-1"])
        XCTAssertNil(model.current)
        XCTAssertEqual(model.outcome, .denied)
    }

    func test_networkFailure_keepsTheEntry_andAllowsARetry() async {
        let api = FakeApprovalApi()
        api.setApprove(.failure(URLError(.notConnectedToInternet)))
        let model = await make(api, entries: [request("p-1")])
        await model.approve(id: "p-1", choice: "47")
        XCTAssertNotNil(model.current)
        XCTAssertEqual(model.outcome, .failed)
        XCTAssertFalse(model.isBusy)
        api.setApprove(.success(.done))
        await model.approve(id: "p-1", choice: "47")
        XCTAssertNil(model.current)
        XCTAssertEqual(model.outcome, .approved)
    }

    /// 403 `device_key_required` reaches the model as a thrown 403 (see the API tests): the entry stays pending,
    /// so it is a failure to retry and never the "wrong number" outcome.
    func test_deviceKeyRequired403_isAFailureThatKeepsTheEntry() async {
        let api = FakeApprovalApi()
        api.setApprove(.failure(BCryptoError.httpError(403)))
        let model = await make(api, entries: [request("p-1")])
        await model.approve(id: "p-1", choice: "47")
        XCTAssertNotNil(model.current)
        XCTAssertEqual(model.outcome, .failed)
    }

    func test_deviceNotReadyToSign_isAFailureThatKeepsTheEntry() async {
        let api = FakeApprovalApi()
        api.setApprove(.failure(DeviceApprovalError.notReady))
        let model = await make(api, entries: [request("p-1")])
        await model.approve(id: "p-1", choice: "47")
        XCTAssertNotNil(model.current)
        XCTAssertEqual(model.outcome, .failed)
    }

    func test_oneActionAtATime() async {
        let api = FakeApprovalApi()
        api.hold(true)
        let model = await make(api, entries: [request("p-1")])
        let first = Task { await model.approve(id: "p-1", choice: "47") }
        guard await waitUntilBusy(model) else { api.hold(false); api.release(); return }
        await model.approve(id: "p-1", choice: "12")
        await model.deny(id: "p-1")
        api.hold(false)
        api.release()
        await first.value
        XCTAssertEqual(api.approvedWith.count, 1)
        XCTAssertTrue(api.denied.isEmpty)
    }

    func test_refresh_doesNotBringBackAnEntryAlreadyHandled() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        await model.approve(id: "p-1", choice: "47")
        await model.refresh()
        XCTAssertNil(model.current, "the list still held it for a moment")
    }

    func test_rejectedSession_clearsSilently() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        api.setList(.failure(BCryptoError.unauthorized))
        await model.refresh()
        XCTAssertNil(model.current)
        XCTAssertNil(model.outcome)
    }

    func test_failedRead_keepsWhatIsOnScreen() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        api.setList(.failure(URLError(.timedOut)))
        await model.refresh()
        XCTAssertNotNil(model.current)
    }

    func test_lock_dropsTheState_andNothingIsReadWhileLocked() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        model.setLocked(true)
        XCTAssertNil(model.current)
        await model.refresh()
        XCTAssertNil(model.current)
        model.setLocked(false)
        await model.refresh()
        XCTAssertNotNil(model.current)
    }

    func test_answerThatArrivesAfterAReset_changesNothing() async {
        let api = FakeApprovalApi()
        api.hold(true)
        let model = await make(api, entries: [request("p-1")])
        let action = Task { await model.approve(id: "p-1", choice: "47") }
        guard await waitUntilBusy(model) else { api.hold(false); api.release(); return }
        model.reset()
        api.hold(false)
        api.release()
        await action.value
        XCTAssertNil(model.outcome)
        XCTAssertFalse(model.isBusy)
    }

    func test_acknowledge_clearsTheOutcome() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        await model.deny(id: "p-1")
        model.acknowledgeOutcome()
        XCTAssertNil(model.outcome)
    }

    // MARK: - Explicit entry ids

    func test_approve_withAnIdNoLongerListed_sendsNothing_andReadsTheListAgain() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        api.setList(.success([request("p-2")]))
        await model.approve(id: "p-1", choice: "47")
        XCTAssertTrue(api.approvedWith.isEmpty, "the entry that was on screen is gone: nothing is signed")
        XCTAssertEqual(model.current?.id, "p-2", "the list was read again")
        XCTAssertNil(model.outcome)
        XCTAssertFalse(model.isBusy)
    }

    func test_deny_withAnIdNoLongerListed_sendsNothing_andReadsTheListAgain() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        api.setList(.success([request("p-2")]))
        await model.deny(id: "p-1")
        XCTAssertTrue(api.denied.isEmpty)
        XCTAssertEqual(model.current?.id, "p-2")
    }

    func test_approve_actsOnTheGivenId_notOnTheCurrentOne() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1", at: 0), request("p-2", at: 60)])
        XCTAssertEqual(model.current?.id, "p-1")
        await model.approve(id: "p-2", choice: "47")
        XCTAssertEqual(api.approvedWith.map(\.0), ["p-2"])
        XCTAssertEqual(model.current?.id, "p-1", "the other entry is untouched")
    }

    func test_deny_actsOnTheGivenId_notOnTheCurrentOne() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1", at: 0), request("p-2", at: 60)])
        await model.deny(id: "p-2")
        XCTAssertEqual(api.denied, ["p-2"])
        XCTAssertEqual(model.current?.id, "p-1")
    }

    func test_approve_withANumberThatIsNotOneOfTheEntrysChoices_isRefused() async {
        let api = FakeApprovalApi()
        let model = await make(api, entries: [request("p-1")])
        await model.approve(id: "p-1", choice: "99")
        XCTAssertTrue(api.approvedWith.isEmpty, "99 is not one of the numbers shown for p-1")
        XCTAssertNotNil(model.current)
    }
}

import XCTest
@testable import QAudionEngine

private final class FakePendingLoginApi: PendingLoginApi, @unchecked Sendable {
    private let lock = NSLock()
    private var _polls: [Result<PendingLoginPoll, Error>] = []
    private var _pollCount = 0
    private var _requestResult: Result<Void, Error> = .success(())
    private var _verifyResult: Result<Void, Error> = .success(())
    private var _requested: [RecoveryChannel] = []
    private var _verified: [String] = []

    /// Answers in order; the last one repeats.
    func script(_ polls: [Result<PendingLoginPoll, Error>]) { lock.withLock { _polls = polls } }
    var pollCount: Int { lock.withLock { _pollCount } }
    var requested: [RecoveryChannel] { lock.withLock { _requested } }
    var verified: [String] { lock.withLock { _verified } }
    func setRequest(_ result: Result<Void, Error>) { lock.withLock { _requestResult = result } }
    func setVerify(_ result: Result<Void, Error>) { lock.withLock { _verifyResult = result } }

    func poll(pendingId: String, pollToken: String) async throws -> PendingLoginPoll {
        let next: Result<PendingLoginPoll, Error> = lock.withLock {
            let index = min(_pollCount, max(0, _polls.count - 1))
            _pollCount += 1
            return _polls.isEmpty ? .success(.pending) : _polls[index]
        }
        return try next.get()
    }

    func requestRecoveryCode(pendingId: String, pollToken: String, channel: RecoveryChannel) async throws {
        let result = lock.withLock { () -> Result<Void, Error> in
            _requested.append(channel)
            return _requestResult
        }
        try result.get()
    }

    func verifyRecoveryCode(pendingId: String, pollToken: String, code: String) async throws {
        let result = lock.withLock { () -> Result<Void, Error> in
            _verified.append(code)
            return _verifyResult
        }
        try result.get()
    }
}

private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []
    var delays: [TimeInterval] { lock.withLock { _delays } }
    func add(_ value: TimeInterval) { lock.withLock { _delays.append(value) } }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

@MainActor
final class LoginWaitModelTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_793_786_400)

    private func ticket(emailRecovery: Bool = true, smsRecovery: Bool = true) -> PendingLoginTicket {
        PendingLoginTicket(pendingId: "p-1", pollToken: "tok", matchCode: "47",
                           expiresAt: t0.addingTimeInterval(600), shortCode: "ABCD2345",
                           emailRecovery: emailRecovery, smsRecovery: smsRecovery)
    }

    private func login(prompt: RevokePrompt = .keep) -> ApprovedLogin {
        ApprovedLogin(credentials: AuthCredentials(userId: "u", deviceId: "d", accessToken: "a",
                                                   refreshToken: "r", expiresIn: 900),
                      revokePrompt: prompt)
    }

    private func makeModel(api: FakePendingLoginApi, clock: FakeClock? = nil, sleeps: SleepLog = SleepLog(),
                           ticket: PendingLoginTicket? = nil) -> LoginWaitModel {
        let clock = clock ?? FakeClock(t0)
        return LoginWaitModel(
            ticket: ticket ?? self.ticket(), api: api,
            sleep: { seconds in
                sleeps.add(seconds)
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            },
            now: { clock.now })
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    // MARK: - Polling

    func test_pending_keepsWaiting() async {
        let api = FakePendingLoginApi()
        api.script([.success(.pending)])
        let model = makeModel(api: api)
        await model.pollOnce()
        XCTAssertEqual(model.phase, .waiting)
        XCTAssertFalse(model.connectionProblem)
    }

    func test_approved_isFinal_andTheSessionIsHandedOverOnce() async throws {
        let api = FakePendingLoginApi()
        api.script([.success(.approved(login(prompt: .disconnectAll)))])
        let model = makeModel(api: api)
        await model.pollOnce()
        XCTAssertEqual(model.phase, .approved)
        let taken = try XCTUnwrap(model.takeApproved())
        XCTAssertEqual(taken.credentials.deviceId, "d")
        XCTAssertEqual(taken.revokePrompt, .disconnectAll)
        XCTAssertNil(model.takeApproved(), "single use")
        await model.pollOnce()
        XCTAssertEqual(api.pollCount, 1, "no poll after the entry ended")
    }

    func test_deniedAndExpired_areFinal() async {
        for (answer, phase) in [(PendingLoginPoll.denied, LoginWaitModel.Phase.denied),
                                (PendingLoginPoll.expired, LoginWaitModel.Phase.expired)] {
            let api = FakePendingLoginApi()
            api.script([.success(answer)])
            let model = makeModel(api: api)
            await model.pollOnce()
            XCTAssertEqual(model.phase, phase)
        }
    }

    func test_sessionRevoked_isFinalWithItsOwnPhase_andPollingStops() async {
        let api = FakePendingLoginApi()
        api.script([.success(.sessionRevoked)])
        let model = makeModel(api: api)
        await model.pollOnce()
        XCTAssertEqual(model.phase, .sessionRevoked)
        XCTAssertFalse(model.connectionProblem)
        await model.pollOnce()
        XCTAssertEqual(api.pollCount, 1, "no poll after the entry ended")
        XCTAssertNil(model.takeApproved())
    }

    func test_loop_pollsEveryInterval_untilApproved() async {
        let api = FakePendingLoginApi()
        api.script([.success(.pending), .success(.pending), .success(.approved(login()))])
        let sleeps = SleepLog()
        let model = makeModel(api: api, sleeps: sleeps)
        model.start()
        await waitUntil { model.phase != .waiting }
        XCTAssertEqual(model.phase, .approved)
        XCTAssertEqual(api.pollCount, 3)
        XCTAssertEqual(sleeps.delays, [3, 3], "3 s between polls")
    }

    func test_tooFast_stretchesTheNextWait_neverBelowTheInterval() async {
        let api = FakePendingLoginApi()
        api.script([.success(.tooFast(retryAfter: 9)), .success(.tooFast(retryAfter: 1)), .success(.denied)])
        let sleeps = SleepLog()
        let model = makeModel(api: api, sleeps: sleeps)
        model.start()
        await waitUntil { model.phase != .waiting }
        XCTAssertEqual(sleeps.delays, [9, 3])
    }

    func test_failures_raiseTheConnectionProblemAfterThree_andClearOnAGoodAnswer() async {
        let api = FakePendingLoginApi()
        let failure = Result<PendingLoginPoll, Error>.failure(URLError(.notConnectedToInternet))
        api.script([failure, failure, failure, .success(.pending)])
        let model = makeModel(api: api)
        await model.pollOnce()
        await model.pollOnce()
        XCTAssertFalse(model.connectionProblem)
        await model.pollOnce()
        XCTAssertTrue(model.connectionProblem)
        XCTAssertEqual(model.phase, .waiting, "polling goes on")
        await model.pollOnce()
        XCTAssertFalse(model.connectionProblem)
    }

    func test_stillPendingLongAfterTheExpiry_showsExpired() async {
        let api = FakePendingLoginApi()
        api.script([.success(.pending)])
        let clock = FakeClock(t0)
        let model = makeModel(api: api, clock: clock)
        clock.now = t0.addingTimeInterval(600 + 10)
        await model.pollOnce()
        XCTAssertEqual(model.phase, .waiting, "within the grace the server decides")
        clock.now = t0.addingTimeInterval(600 + 25)
        await model.pollOnce()
        XCTAssertEqual(model.phase, .expired)
    }

    func test_stop_endsTheLoop() async {
        let api = FakePendingLoginApi()
        api.script([.success(.pending)])
        let model = makeModel(api: api)
        model.start()
        await waitUntil { api.pollCount >= 2 }
        model.stop()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let after = api.pollCount
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(api.pollCount, after)
    }

    func test_remainingSeconds_countsDownToZero() {
        let model = makeModel(api: FakePendingLoginApi())
        XCTAssertEqual(model.remainingSeconds(at: t0), 600)
        XCTAssertEqual(model.remainingSeconds(at: t0.addingTimeInterval(599.2)), 1)
        XCTAssertEqual(model.remainingSeconds(at: t0.addingTimeInterval(700)), 0)
    }

    // MARK: - Recovery by code

    func test_requestCode_thenVerify_pollsAtOnceAndReturnsTheSession() async throws {
        let api = FakePendingLoginApi()
        api.script([.success(.approved(login(prompt: .disconnectAll)))])
        let model = makeModel(api: api)
        await model.requestCode(.email)
        XCTAssertEqual(model.recovery, .codeSent(.email))
        XCTAssertEqual(api.requested, [.email])
        await model.verify(code: " 123456 ")
        XCTAssertEqual(api.verified, ["123456"])
        XCTAssertEqual(model.phase, .approved)
        XCTAssertEqual(model.takeApproved()?.revokePrompt, .disconnectAll)
    }

    func test_verify_withoutAskingForACode_doesNothing() async {
        let api = FakePendingLoginApi()
        let model = makeModel(api: api)
        await model.verify(code: "123456")
        XCTAssertTrue(api.verified.isEmpty)
    }

    func test_verify_codeThatIsNotSixDigits_isRefusedLocally() async {
        let api = FakePendingLoginApi()
        let model = makeModel(api: api)
        await model.requestCode(.sms)
        for bad in ["12345", "1234567", "12345a", "١٢٣٤٥٦"] {
            await model.verify(code: bad)
            XCTAssertEqual(model.recoveryProblem, .invalidCode, bad)
        }
        XCTAssertTrue(api.verified.isEmpty)
    }

    func test_wrongCode_keepsTheStep_tooManyAttemptsSendsBackToAskAgain() async {
        let api = FakePendingLoginApi()
        let model = makeModel(api: api)
        await model.requestCode(.email)
        api.setVerify(.failure(PendingLoginRecoveryError.invalidCode))
        await model.verify(code: "111111")
        XCTAssertEqual(model.recovery, .codeSent(.email))
        XCTAssertEqual(model.recoveryProblem, .invalidCode)
        api.setVerify(.failure(PendingLoginRecoveryError.tooManyAttempts))
        await model.verify(code: "222222")
        XCTAssertEqual(model.recovery, .idle)
        XCTAssertEqual(model.recoveryProblem, .tooManyAttempts)
        XCTAssertEqual(model.phase, .waiting)
    }

    func test_codeExpired_sendsBackToAskAgain_andTheEntryKeepsWaiting() async {
        let api = FakePendingLoginApi()
        let model = makeModel(api: api)
        await model.requestCode(.email)
        api.setVerify(.failure(PendingLoginRecoveryError.codeExpired))
        await model.verify(code: "222222")
        XCTAssertEqual(model.recovery, .idle)
        XCTAssertEqual(model.recoveryProblem, .codeExpired)
        XCTAssertEqual(model.phase, .waiting, "a gone code is not the end of the whole entry")
    }

    func test_requestCode_failure_staysIdleWithAProblem() async {
        let api = FakePendingLoginApi()
        api.setRequest(.failure(PendingLoginRecoveryError.rateLimited(retryAfter: 60)))
        let model = makeModel(api: api)
        await model.requestCode(.sms)
        XCTAssertEqual(model.recovery, .idle)
        XCTAssertEqual(model.recoveryProblem, .rateLimited)
    }

    func test_requestCode_unavailableChannel() async {
        let api = FakePendingLoginApi()
        api.setRequest(.failure(PendingLoginRecoveryError.channelUnavailable))
        let model = makeModel(api: api)
        await model.requestCode(.sms)
        XCTAssertEqual(model.recoveryProblem, .unavailable)
    }

    func test_recoveryAnswerThatSaysDeniedOrExpired_endsTheEntry() async {
        let api = FakePendingLoginApi()
        api.setVerify(.failure(PendingLoginRecoveryError.denied))
        let model = makeModel(api: api)
        await model.requestCode(.email)
        await model.verify(code: "123456")
        XCTAssertEqual(model.phase, .denied)

        let api2 = FakePendingLoginApi()
        api2.setRequest(.failure(PendingLoginRecoveryError.expired))
        let model2 = makeModel(api: api2)
        await model2.requestCode(.email)
        XCTAssertEqual(model2.phase, .expired)
    }

    func test_nothingIsAskedOnceTheEntryEnded() async {
        let api = FakePendingLoginApi()
        api.script([.success(.denied)])
        let model = makeModel(api: api)
        await model.pollOnce()
        await model.requestCode(.email)
        XCTAssertTrue(api.requested.isEmpty)
    }
}

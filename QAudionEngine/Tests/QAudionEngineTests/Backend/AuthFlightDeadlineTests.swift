import XCTest
@testable import QAudionEngine

/// 2026-10-03 — two properties of the process-wide `AuthRefreshCoordinator` that the single
/// flight makes load-bearing (see the header of `AuthRefreshCoordinator.swift`):
///
///   1. A flight has an overall deadline. Without one, a request that hangs keeps the one
///      slot forever and every later caller joins it.
///   2. Which failures PROVE the credentials are gone (`provesCredentialLoss`), the only ones
///      the REST client may answer with `BCryptoError.unauthorized` (a forced QR re-pair).
///   3. (auth follow-ups to #156) A store-backed client without a renewer never poisons the shared
///      flight with a final failure, a flight cut at its deadline leaves an abandoned marker so
///      the same refresh token is not presented twice, and an abandoned flight writes no shared
///      state when it finally answers.
///
/// Every test that waits on a hung closure goes through `bounded(_:_:)`, so reverting the
/// deadline makes it fail in seconds instead of hanging the suite.
///
/// Foundation-only, like the coordinator: no transport, no Keychain. A closure "hangs" on a
/// `Hang`, which the test releases at the end, so no continuation is ever leaked.
final class AuthFlightDeadlineTests: XCTestCase {

    // MARK: - helpers

    /// Suspends callers until `release()`. Ignores task cancellation on purpose: it stands for
    /// a request or a Keychain call that never answers whatever the coordinator does.
    private final class Hang: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let proceed: Bool = lock.withLock {
                    if released { return true }
                    waiting.append(c)
                    return false
                }
                if proceed { c.resume() }
            }
        }

        func release() {
            let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                let w = waiting
                waiting = []
                return w
            }
            for c in toResume { c.resume() }
        }
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _tokens: [String] = []
        private var _lines: [String] = []
        private var _flag = false

        @discardableResult
        func hit(token: String? = nil) -> Int {
            lock.withLock {
                _calls += 1
                if let t = token { _tokens.append(t) }
                return _calls
            }
        }
        var calls: Int { lock.withLock { _calls } }
        var tokens: [String] { lock.withLock { _tokens } }
        func log(_ line: String) { lock.withLock { _lines.append(line) } }
        var text: String { lock.withLock { _lines.joined(separator: "\n") } }
        func raise() { lock.withLock { _flag = true } }
        var raised: Bool { lock.withLock { _flag } }
    }

    private func makeCoordinator(deadline: TimeInterval = 0.3) -> (AuthRefreshCoordinator, Probe) {
        let probe = Probe()
        let c = AuthRefreshCoordinator(flightDeadlineSec: deadline)
        c.setLogger { _, line in probe.log(line) }
        return (c, probe)
    }

    private func request(_ trigger: AuthRefreshTrigger = .rest401,
                         store: AuthCredentialStore?,
                         refresher: AuthRefreshRequest.Refresher? = nil,
                         renewer: AuthRefreshRequest.Renewer? = nil,
                         ignoreCooldown: Bool = false) -> AuthRefreshRequest {
        AuthRefreshRequest(trigger: trigger, staleAccessToken: "A0", callerRefreshToken: nil,
                           store: store, refresher: refresher, renewer: renewer,
                           ignoreCooldown: ignoreCooldown)
    }

    private func fresh(_ n: Int) -> AuthTokenSet {
        AuthTokenSet(accessToken: "A\(n)", refreshToken: "R\(n)", expiresInSec: 900)
    }

    /// Polls `condition` for up to `seconds` (the late result of an abandoned flight lands on
    /// its own schedule, there is nothing to await).
    private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// `refresh`, failing the test (instead of hanging it) if the caller is not released in 5 s.
    private func bounded(_ c: AuthRefreshCoordinator, _ r: AuthRefreshRequest,
                         file: StaticString = #filePath, line: UInt = #line) async -> AuthRefreshOutcome {
        guard let outcome = await AuthTestTimeLimit.within(5, { await c.refresh(r) }) else {
            XCTFail("the flight deadline did not release the caller within 5 s", file: file, line: line)
            return .failed(AuthRecoveryFailure(reason: .refreshOther))
        }
        return outcome
    }

    private func timeoutFailure(_ outcome: AuthRefreshOutcome,
                                file: StaticString = #filePath, line: UInt = #line) -> AuthRecoveryFailure? {
        guard case .failed(let f) = outcome else {
            XCTFail("expected a failed outcome, got \(outcome)", file: file, line: line)
            return nil
        }
        return f
    }

    // MARK: - (2) flight deadline

    func test_aHungRefresherEndsTheFlightWithATransientTimeout() async {
        let (c, _) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()
        let started = Date()

        let outcome = await bounded(c, request(store: store, refresher: { token in
            net.hit(token: token)
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
        }))
        let elapsed = Date().timeIntervalSince(started)
        defer { hang.release() }

        guard let f = timeoutFailure(outcome) else { return }
        XCTAssertEqual(f.reason, .flightTimeout)
        XCTAssertFalse(f.isFinal, "a hung request says nothing about the credentials")
        XCTAssertFalse(f.provesCredentialLoss)
        XCTAssertGreaterThanOrEqual(elapsed, 0.25, "the flight must run until its deadline")
        XCTAssertLessThan(elapsed, 5, "and not a moment longer")
        XCTAssertEqual(net.calls, 1)
    }

    func test_everyCallerJoinedToAHungFlightIsReleased() async {
        let (c, _) = makeCoordinator(deadline: 0.5)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            net.hit(token: token)
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
        }

        let triggers: [AuthRefreshTrigger] = [.rest401, .wsAuthFailed, .external, .rest401, .proactive]
        let requests: [AuthRefreshRequest] = triggers.map {
            request($0, store: store, refresher: refresher, ignoreCooldown: $0 == .proactive)
        }
        let outcomes = await withTaskGroup(of: AuthRefreshOutcome.self) { group -> [AuthRefreshOutcome] in
            for r in requests {
                group.addTask { await self.bounded(c, r) }
            }
            var all: [AuthRefreshOutcome] = []
            for await o in group { all.append(o) }
            return all
        }
        defer { hang.release() }

        XCTAssertEqual(outcomes.count, 5, "every waiter returns")
        XCTAssertEqual(net.calls, 1, "they all shared the one flight")
        for o in outcomes {
            XCTAssertEqual(o.failure?.reason, .flightTimeout, "\(o)")
        }
    }

    func test_afterTheDeadlineTheSlotIsFreeAndACallerOfANewerSessionStartsAFreshFlight() async {
        let (c, _) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            let n = net.hit(token: token)
            if n == 1 {
                await hang.wait()
                return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
            }
            return AuthTokenSet(accessToken: "A6", refreshToken: "R6", expiresInSec: 900)
        }
        defer { hang.release() }

        let first = await bounded(c, request(store: store, refresher: refresher))
        XCTAssertEqual(first.failure?.reason, .flightTimeout)

        // Another path (a login) moved the store on to a pair the hung request never saw.
        store.overwrite(access: "A5", refresh: "R5")
        // The proactive refresh ignores the cooldown the timeout started.
        let second = await bounded(c, request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))

        XCTAssertTrue(second.isSuccess, "a hung flight must not be joined forever: \(second)")
        XCTAssertEqual(net.tokens, ["R0", "R5"], "the second caller did NOT join the abandoned flight")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A6", refresh: "R6"))
    }

    func test_aHungRenewerEndsTheFlightToo() async {
        let (c, _) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        let hang = Hang()

        let outcome = await bounded(c, request(store: store, renewer: {
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
        }))
        defer { hang.release() }

        XCTAssertEqual(outcome.failure?.reason, .flightTimeout)
        XCTAssertFalse(outcome.failure?.provesCredentialLoss ?? true)
    }

    func test_theTimeoutStartsTheOrdinaryLadderAndOnlyTheProactiveRefreshSkipsIt() async {
        let (c, _) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            net.hit(token: token)
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
        }
        defer { hang.release() }

        let first = await bounded(c, request(store: store, refresher: refresher))
        XCTAssertEqual(first.failure?.retryAfterSec, AuthRefreshCoordinator.backoffSeconds(forFailures: 1))

        // A REST/socket caller fails fast inside the cooldown, with the reason that started it.
        let second = await bounded(c, request(store: store, refresher: refresher))
        XCTAssertEqual(second.failure?.reason, .cooldown)
        XCTAssertEqual(second.failure?.underlyingReason, .flightTimeout)
        XCTAssertEqual(second.failure?.provesCredentialLoss, false)
        XCTAssertEqual(net.calls, 1, "no second request inside the cooldown")
    }

    func test_aLateResultIsStillWrittenWithCompareAndSwapWhenNothingNewerExists() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()

        let outcome = await bounded(c, request(store: store, refresher: { _ in
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
        }))
        XCTAssertEqual(outcome.failure?.reason, .flightTimeout)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"),
                       "nothing is written before the answer arrives")

        hang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)
        // The server rotated the pair when it answered; dropping it would lose the new token.
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A-late", refresh: "R-late"))
        XCTAssertTrue(probe.text.contains("cas_checked=1"), probe.text)
    }

    func test_aLateResultNeverOverwritesANewerPair() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()

        let outcome = await bounded(c, request(store: store, refresher: { _ in
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
        }))
        XCTAssertEqual(outcome.failure?.reason, .flightTimeout)

        // Meanwhile another path (a login, a refresh outside this flight) moved the store on.
        store.overwrite(access: "A-newer", refresh: "R-newer")

        hang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A-newer", refresh: "R-newer"),
                       "the late result lost the compare-and-swap and is discarded")
    }

    func test_aLateResultNeverResurrectsASignedOutStore() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()

        _ = await bounded(c, request(store: store, refresher: { _ in
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: nil)
        }))
        store.overwrite(access: nil, refresh: nil)   // logout while the answer is still on the wire

        hang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: nil, refresh: nil))
    }

    func test_theDeadlineCancelsACooperativeRefresher() async {
        let (c, _) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let cancelled = Probe()

        let outcome = await bounded(c, request(store: store, refresher: { _ in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                cancelled.raise()
                throw error
            }
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }))

        XCTAssertEqual(outcome.failure?.reason, .flightTimeout)
        let seen = await eventually { cancelled.raised }
        XCTAssertTrue(seen, "the abandoned work is cancelled so a cooperative closure stops")
    }

    func test_aRejectionThatArrivesAfterTheDeadlineNeverStartsTheRenewLeg() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let renews = Probe()

        let outcome = await bounded(c, request(store: store, refresher: { _ in
            await hang.wait()
            throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
        }, renewer: {
            renews.hit()
            return AuthTokenSet(accessToken: "A-renewed", refreshToken: "R-renewed", expiresInSec: nil)
        }))
        XCTAssertEqual(outcome.failure?.reason, .flightTimeout)

        hang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)
        XCTAssertEqual(renews.calls, 0,
                       "callers were released long ago: a late rejection must not spend device-renew budget")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"))
    }

    func test_aFlightThatFinishesInTimeIsNotTouchedByTheDeadline() async {
        let (c, probe) = makeCoordinator(deadline: 5)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let net = Probe()
        let started = Date()

        let outcome = await bounded(c, request(store: store, refresher: { token in
            net.hit(token: token)
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }))

        XCTAssertTrue(outcome.isSuccess)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "does not wait for the deadline")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"))
        XCTAssertFalse(probe.text.contains("flight deadline"), probe.text)
        XCTAssertFalse(probe.text.contains("late flight result"), probe.text)
    }

    func test_theDefaultDeadlineSitsAboveThreeRESTRequestTimeouts() {
        // Refresh + challenge + renew in a row, each up to the REST session's 15 s idle timeout.
        XCTAssertGreaterThan(AuthRefreshCoordinator.defaultFlightDeadlineSec, 45)
        XCTAssertLessThanOrEqual(AuthRefreshCoordinator.defaultFlightDeadlineSec, 60)
    }

    // MARK: - (1) which failures prove the credentials are gone

    /// What a REST caller (or the launch `getProfile`) gets from one real coordinator flight.
    private func failure(store: AuthCredentialStore?,
                         refresher: AuthRefreshRequest.Refresher? = nil,
                         renewer: AuthRefreshRequest.Renewer? = nil) async -> AuthRecoveryFailure? {
        let c = AuthRefreshCoordinator()
        let r = AuthRefreshRequest(trigger: .rest401, staleAccessToken: "A0", callerRefreshToken: store == nil ? "R0" : nil,
                                   store: store, refresher: refresher, renewer: renewer)
        return await c.refresh(r).failure
    }

    func test_everyTransientOutcomeOfARealFlightFailsToProveALoss() async {
        let rejected: AuthRefreshRequest.Refresher = { _ in throw AuthRecoveryFailure(reason: .refreshRejected, status: 401) }
        let cases: [(String, AuthRecoveryFailure?)] = [
            ("refresh: network",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"),
                           refresher: { _ in throw AuthRecoveryFailure(reason: .refreshNetwork) })),
            ("refresh: 5xx",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"),
                           refresher: { _ in throw AuthRecoveryFailure(reason: .refreshServerError, status: 503) })),
            ("refresh: 429",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"),
                           refresher: { _ in throw AuthRecoveryFailure(reason: .refreshServerError, status: 429, retryAfterSec: 60) })),
            ("refresh: unclassified",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"),
                           refresher: { _ in throw AuthRecoveryFailure(reason: .refreshOther) })),
            ("rejected, renew: network",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"), refresher: rejected,
                           renewer: { throw AuthRecoveryFailure(reason: .renewNetwork) })),
            ("rejected, renew: Keychain locked",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"), refresher: rejected,
                           renewer: { throw AuthRecoveryFailure(reason: .renewKeychainLocked) })),
            ("rejected, renew: bad signature / raced nonce (401)",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"), refresher: rejected,
                           renewer: { throw AuthRecoveryFailure(reason: .renewRejected, status: 401) })),
            ("rejected, renew: 5xx",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"), refresher: rejected,
                           renewer: { throw AuthRecoveryFailure(reason: .renewServerError, status: 500) })),
            ("rejected, renew: 429",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"), refresher: rejected,
                           renewer: { throw AuthRecoveryFailure(reason: .renewServerError, status: 429, retryAfterSec: 60) })),
            ("rejected, store-backed but no renewer (half-wired builder)",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"), refresher: rejected)),
            ("no refresh token, renew: clock skew (400)",
             await failure(store: InMemoryAuthCredentialStore(access: "A0", refresh: nil),
                           renewer: { throw AuthRecoveryFailure(reason: .renewRejected, status: 400) })),
        ]
        for (name, f) in cases {
            guard let f else { XCTFail("\(name): the flight did not fail"); continue }
            XCTAssertFalse(f.isFinal, "\(name)")
            XCTAssertFalse(f.provesCredentialLoss, "\(name): \(f.logFields)")
        }
    }

    func test_anUnreadableStoreAndTheCooldownAreNotALossEither() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        store.setUnreadable(status: -25308)
        let unreadable = await failure(store: store, refresher: { _ in
            XCTFail("the refresh token must not be spent on a store that cannot be read")
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        })
        XCTAssertEqual(unreadable?.reason, .storeUnreadable)
        XCTAssertEqual(unreadable?.provesCredentialLoss, false)

        // Several callers at cold start: the first fails transiently, the rest hit the cooldown.
        let c = AuthRefreshCoordinator()
        let shared = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let first = await c.refresh(request(store: shared, refresher: { _ in throw AuthRecoveryFailure(reason: .refreshNetwork) }))
        XCTAssertEqual(first.failure?.provesCredentialLoss, false)
        for _ in 0..<3 {
            let again = await c.refresh(request(store: shared, refresher: { _ in
                XCTFail("inside the cooldown nobody goes to the network")
                return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
            }))
            XCTAssertEqual(again.failure?.reason, .cooldown)
            XCTAssertEqual(again.failure?.provesCredentialLoss, false,
                           "a cooldown after a TRANSIENT failure must not read as a revoked session")
        }
    }

    func test_theRenewBudgetWaitAfterATransientRenewFailureIsNotALoss() async {
        let c = AuthRefreshCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        let renewer: AuthRefreshRequest.Renewer = { throw AuthRecoveryFailure(reason: .renewRejected, status: 401) }
        let first = await c.refresh(request(store: store, renewer: renewer, ignoreCooldown: true))
        XCTAssertEqual(first.failure?.provesCredentialLoss, false)
        let second = await c.refresh(request(.proactive, store: store, renewer: renewer, ignoreCooldown: true))
        XCTAssertEqual(second.failure?.reason, .renewBudget)
        XCTAssertEqual(second.failure?.provesCredentialLoss, false)
    }

    func test_theDefinitiveOutcomesDoProveALoss() async {
        // device-renew 403: the server revoked the device.
        let revoked = await failure(
            store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"),
            refresher: { _ in throw AuthRecoveryFailure(reason: .refreshRejected, status: 401) },
            renewer: { throw AuthRecoveryFailure(reason: .renewRejected, status: 403, isFinal: true) })
        XCTAssertEqual(revoked?.provesCredentialLoss, true, "\(String(describing: revoked))")

        // No device credential left to renew with.
        let noDevice = await failure(
            store: InMemoryAuthCredentialStore(access: "A0", refresh: nil),
            renewer: { throw AuthRecoveryFailure(reason: .renewNoDeviceId, isFinal: true) })
        XCTAssertEqual(noDevice?.provesCredentialLoss, true)
        let noKey = await failure(
            store: InMemoryAuthCredentialStore(access: "A0", refresh: nil),
            renewer: { throw AuthRecoveryFailure(reason: .renewKeyNotProvisioned, isFinal: true) })
        XCTAssertEqual(noKey?.provesCredentialLoss, true)

        // Signed out: the store holds nothing.
        let signedOut = await failure(
            store: InMemoryAuthCredentialStore(access: nil, refresh: nil),
            refresher: { _ in throw AuthRecoveryFailure(reason: .refreshOther) })
        XCTAssertEqual(signedOut?.reason, .signedOut)
        XCTAssertEqual(signedOut?.provesCredentialLoss, true)

        // Refresh token rejected and nothing else to try, for a client with no store: nothing
        // else in the process shares its session, so the rejection is the answer.
        let rejectedAlone = await failure(
            store: nil,
            refresher: { _ in throw AuthRecoveryFailure(reason: .refreshRejected, status: 401) })
        XCTAssertEqual(rejectedAlone?.provesCredentialLoss, true)

        // A client with no recovery path at all (login, onboarding): its 401 is the answer.
        let nothing = await failure(store: nil)
        XCTAssertEqual(nothing?.reason, .noRecoveryPath)
        XCTAssertEqual(nothing?.provesCredentialLoss, true)
    }

    func test_theCooldownOfADefinitiveFailureStaysDefinitive() async {
        let c = AuthRefreshCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        let renewer: AuthRefreshRequest.Renewer = { throw AuthRecoveryFailure(reason: .renewRejected, status: 403, isFinal: true) }
        let first = await c.refresh(request(store: store, renewer: renewer))
        XCTAssertEqual(first.failure?.provesCredentialLoss, true)
        let second = await c.refresh(request(store: store, renewer: renewer))
        XCTAssertEqual(second.failure?.reason, .cooldown)
        XCTAssertEqual(second.failure?.provesCredentialLoss, true,
                       "a revoked device does not become 'transient' because the second caller arrived in the cooldown")
    }

    func test_theReasonCodesTheRestClientAddsAreNotLosses() {
        XCTAssertFalse(AuthRecoveryFailure(reason: .flightTimeout).provesCredentialLoss)
        XCTAssertFalse(AuthRecoveryFailure(reason: .rejectedAfterRecovery, status: 401).provesCredentialLoss)
        XCTAssertEqual(AuthRecoveryReason.flightTimeout.rawValue, "flight_timeout")
        XCTAssertEqual(AuthRecoveryReason.rejectedAfterRecovery.rawValue, "rejected_after_recovery")
    }

    // MARK: - (3) a store-backed client without a renewer must not poison the shared flight

    func test_aJoinerWithARenewerHealsWhenTheFlightItJoinedHadNone() async {
        let (c, probe) = makeCoordinator(deadline: 5)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let refreshes = Probe()
        let renews = Probe()
        let rejecting: AuthRefreshRequest.Refresher = { token in
            refreshes.hit(token: token)
            await hang.wait()
            throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
        }
        let renewer: AuthRefreshRequest.Renewer = {
            renews.hit()
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }
        defer { hang.release() }

        // A dial-time client, store-backed but built without the device-renew leg, starts the flight.
        let firstRequest = request(.wsAuthFailed, store: store, refresher: rejecting)
        let first = Task { await c.refresh(firstRequest) }
        let started = await eventually { refreshes.calls == 1 }
        XCTAssertTrue(started)
        // The socket recovery (it has a renewer) joins it while the request is still on the wire.
        let joinerRequest = request(.rest401, store: store, refresher: rejecting, renewer: renewer)
        let joiner = Task { await c.refresh(joinerRequest) }
        let joined = await eventually { probe.text.contains("refresh joined") }
        XCTAssertTrue(joined, probe.text)
        hang.release()

        let firstOutcome = await first.value
        let joinerOutcome = await joiner.value

        XCTAssertEqual(firstOutcome.failure?.reason, .refreshRejected)
        XCTAssertEqual(firstOutcome.failure?.isFinal, false,
                       "store-backed + no renewer is not a verdict on the session")
        XCTAssertEqual(firstOutcome.failure?.provesCredentialLoss, false)
        guard case .refreshed(let tokens, let path) = joinerOutcome else {
            XCTFail("the joiner has a renewer and must heal: \(joinerOutcome)\n\(probe.text)")
            return
        }
        XCTAssertEqual(path, .deviceRenew)
        XCTAssertEqual(tokens.accessToken, "A1")
        XCTAssertEqual(renews.calls, 1)
        XCTAssertEqual(refreshes.calls, 1, "the rejected refresh token is not presented again")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"))
    }

    func test_aRenewerEquippedCallerIsNotHeldBackByTheCooldownOfARenewerlessFlight() async {
        let (c, _) = makeCoordinator(deadline: 5)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let refreshes = Probe()
        let renews = Probe()
        let rejecting: AuthRefreshRequest.Refresher = { token in
            refreshes.hit(token: token)
            throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
        }

        let first = await c.refresh(request(.wsAuthFailed, store: store, refresher: rejecting))
        XCTAssertEqual(first.failure?.reason, .refreshRejected)
        XCTAssertEqual(first.failure?.isFinal, false)

        // Another renewer-less caller inside the cooldown still fails fast, and it is not final either.
        let cooling = await c.refresh(request(.rest401, store: store, refresher: rejecting))
        XCTAssertEqual(cooling.failure?.reason, .cooldown)
        XCTAssertEqual(cooling.failure?.underlyingReason, .refreshRejected)
        XCTAssertEqual(cooling.failure?.isFinal, false)
        XCTAssertEqual(cooling.failure?.provesCredentialLoss, false)

        // A caller that can run device-renew is let through and heals the session.
        let healed = await c.refresh(request(.rest401, store: store, refresher: rejecting, renewer: {
            renews.hit()
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }))
        guard case .refreshed(_, let path) = healed else {
            XCTFail("expected a device-renew heal, got \(healed)")
            return
        }
        XCTAssertEqual(path, .deviceRenew)
        XCTAssertEqual(renews.calls, 1)
        XCTAssertEqual(refreshes.calls, 1, "the dead refresh token was presented once only")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"))
    }

    // MARK: - (4) an abandoned flight never lets its refresh token be presented twice

    func test_noSecondPresentationWhileTheAbandonedFlightMayStillBeOnTheWire() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            let n = net.hit(token: token)
            if n == 1 {
                await hang.wait()
                throw AuthRecoveryFailure(reason: .refreshNetwork)   // the token is still alive
            }
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }
        defer { hang.release() }

        let first = await bounded(c, request(store: store, refresher: refresher))
        XCTAssertEqual(first.failure?.reason, .flightTimeout)

        // The proactive refresh ignores the cooldown: only the abandoned marker can stop it.
        let second = await bounded(c, request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        XCTAssertEqual(second.failure?.reason, .flightTimeout, "\(second)")
        XCTAssertEqual(second.failure?.isFinal, false)
        XCTAssertEqual(net.calls, 1, "the token is on the wire already: no second presentation, no network call")
        XCTAssertTrue(probe.text.contains("abandoned_flight_live=1"), probe.text)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"))

        // The abandoned work ends: the marker goes with it and the token can be used again.
        hang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)
        let third = await bounded(c, request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        XCTAssertTrue(third.isSuccess, "\(third)")
        XCTAssertEqual(net.tokens, ["R0", "R0"])
    }

    func test_theAbandonedMarkerExpiresWhenTheWorkNeverReportsBack() async {
        let (c, _) = makeCoordinator()   // deadline 0.3 s: the marker lives 2 x 0.3 s after it
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            let n = net.hit(token: token)
            if n == 1 {
                await hang.wait()   // never answers within this test
            }
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }
        defer { hang.release() }

        _ = await bounded(c, request(store: store, refresher: refresher))
        let during = await bounded(c, request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        XCTAssertEqual(during.failure?.reason, .flightTimeout)
        XCTAssertEqual(net.calls, 1)

        let markerSeconds = 0.3 * AuthRefreshCoordinator.abandonedMarkerFactor
        try? await Task.sleep(nanoseconds: UInt64((markerSeconds + 0.3) * 1_000_000_000))
        let after = await bounded(c, request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        XCTAssertTrue(after.isSuccess, "a request that never answers cannot block the session for good: \(after)")
        XCTAssertEqual(net.tokens, ["R0", "R0"])
    }

    func test_theLateResultOfAnAbandonedFlightIsAdoptedByTheNextCaller() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()

        let first = await bounded(c, request(store: store, refresher: { token in
            net.hit(token: token)
            await hang.wait()
            return AuthTokenSet(accessToken: "A-late", refreshToken: "R-late", expiresInSec: 900)
        }))
        XCTAssertEqual(first.failure?.reason, .flightTimeout)
        hang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A-late", refresh: "R-late"))

        // A REST 401 of a client still on A0 finds the late result in the store: no network call.
        let next = await bounded(c, request(.rest401, store: store, refresher: { _ in
            XCTFail("the late result is adopted, nothing is presented")
            return AuthTokenSet(accessToken: "A-x", refreshToken: "R-x", expiresInSec: nil)
        }))
        guard case .adopted(let tokens) = next else {
            XCTFail("expected the late pair to be adopted, got \(next)")
            return
        }
        XCTAssertEqual(tokens.accessToken, "A-late")
        XCTAssertEqual(net.calls, 1)
    }

    // MARK: - (5) an abandoned flight writes no shared state when it finally answers

    func test_aLateRejectionOfAnAbandonedFlightDoesNotMarkTheTokenDead() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            let n = net.hit(token: token)
            if n == 1 {
                await hang.wait()
                throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
            }
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }
        defer { hang.release() }

        let first = await bounded(c, request(store: store, refresher: refresher))
        XCTAssertEqual(first.failure?.reason, .flightTimeout)
        hang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)

        // Had the zombie recorded its rejection, R0 would now be "known dead" and never presented.
        let second = await bounded(c, request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        XCTAssertTrue(second.isSuccess, "\(second)\n\(probe.text)")
        XCTAssertEqual(net.tokens, ["R0", "R0"], "the zombie's rejection is not remembered")
        XCTAssertFalse(probe.text.contains("refresh_token_known_dead=1"), probe.text)
    }

    func test_aLateRenewFailureOfAnAbandonedFlightDoesNotStartTheRenewCooldown() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let renewHang = Hang()
        let renews = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            switch token {
            case "R5": return AuthTokenSet(accessToken: "A6", refreshToken: "R6", expiresInSec: 900)
            default: throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
            }
        }
        defer { renewHang.release() }

        // Flight 1: refresh rejected, then the renew leg hangs until the deadline cuts the flight.
        let first = await bounded(c, request(store: store, refresher: refresher, renewer: {
            await renewHang.wait()
            throw AuthRecoveryFailure(reason: .renewServerError, status: 429, retryAfterSec: 60)
        }))
        XCTAssertEqual(first.failure?.reason, .flightTimeout)

        // A newer session (login) and a newer flight succeed meanwhile.
        store.overwrite(access: "A5", refresh: "R5")
        let newer = await bounded(c, request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        XCTAssertTrue(newer.isSuccess, "\(newer)")

        // The zombie finally answers with a failure that WOULD start the 10 minute renew cooldown.
        renewHang.release()
        let landed = await eventually { probe.text.contains("late flight result") }
        XCTAssertTrue(landed, probe.text)

        // The session needs device-renew once more: it must not find the zombie's cooldown.
        store.overwrite(access: "A7", refresh: "R7")
        let again = await bounded(c, request(.proactive, store: store, refresher: refresher, renewer: {
            renews.hit()
            return AuthTokenSet(accessToken: "A8", refreshToken: "R8", expiresInSec: 900)
        }, ignoreCooldown: true))
        guard case .refreshed(_, let path) = again else {
            XCTFail("the renew leg must be open: \(again)\n\(probe.text)")
            return
        }
        XCTAssertEqual(path, .deviceRenew)
        XCTAssertEqual(renews.calls, 1)
    }
}

import XCTest
@testable import QAudionEngine

/// 2026-10-03 — two properties of the process-wide `AuthRefreshCoordinator` that the single
/// flight makes load-bearing (see the header of `AuthRefreshCoordinator.swift`):
///
///   1. A flight has an overall deadline. Without one, a request that hangs keeps the one
///      slot forever and every later caller joins it.
///   2. Which failures PROVE the credentials are gone (`provesCredentialLoss`), the only ones
///      the REST client may answer with `BCryptoError.unauthorized` (a forced QR re-pair).
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

        let outcome = await c.refresh(request(store: store, refresher: { token in
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
                group.addTask { await c.refresh(r) }
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

    func test_afterTheDeadlineTheSlotIsFreeAndALaterCallerStartsAFreshFlight() async {
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
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }

        let first = await c.refresh(request(store: store, refresher: refresher))
        XCTAssertEqual(first.failure?.reason, .flightTimeout)

        // The proactive refresh ignores the cooldown the timeout started.
        let second = await c.refresh(request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        defer { hang.release() }

        XCTAssertTrue(second.isSuccess, "a hung flight must not be joined forever: \(second)")
        XCTAssertEqual(net.calls, 2, "the second caller did NOT join the abandoned flight")
        XCTAssertEqual(net.tokens, ["R0", "R0"],
                       "the timeout neither spends nor marks dead the refresh token: it is presented again")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"))
    }

    func test_aHungRenewerEndsTheFlightToo() async {
        let (c, _) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        let hang = Hang()

        let outcome = await c.refresh(request(store: store, renewer: {
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

        let first = await c.refresh(request(store: store, refresher: refresher))
        XCTAssertEqual(first.failure?.retryAfterSec, AuthRefreshCoordinator.backoffSeconds(forFailures: 1))

        // A REST/socket caller fails fast inside the cooldown, with the reason that started it.
        let second = await c.refresh(request(store: store, refresher: refresher))
        XCTAssertEqual(second.failure?.reason, .cooldown)
        XCTAssertEqual(second.failure?.underlyingReason, .flightTimeout)
        XCTAssertEqual(second.failure?.provesCredentialLoss, false)
        XCTAssertEqual(net.calls, 1, "no second request inside the cooldown")
    }

    func test_aLateResultIsStillWrittenWithCompareAndSwapWhenNothingNewerExists() async {
        let (c, probe) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()

        let outcome = await c.refresh(request(store: store, refresher: { _ in
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

        let outcome = await c.refresh(request(store: store, refresher: { _ in
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

        _ = await c.refresh(request(store: store, refresher: { _ in
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

        let outcome = await c.refresh(request(store: store, refresher: { _ in
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

        let outcome = await c.refresh(request(store: store, refresher: { _ in
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

        let outcome = await c.refresh(request(store: store, refresher: { token in
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

        // Refresh token rejected and nothing else to try.
        let rejectedAlone = await failure(
            store: InMemoryAuthCredentialStore(access: "A0", refresh: "R0"),
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
}

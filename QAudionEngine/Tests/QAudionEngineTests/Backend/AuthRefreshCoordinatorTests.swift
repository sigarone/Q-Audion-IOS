import XCTest
@testable import QAudionEngine

/// 2026-10-02 — one refresh single flight per process, compare-and-swap persistence, and
/// observable healing (see the header of `AuthRefreshCoordinator.swift` for the incident).
///
/// Everything here is in memory: an `InMemoryAuthCredentialStore` stands in for the
/// Keychain and each test builds its own `AuthRefreshCoordinator`, so no test shares
/// backoff state with another or with the process-wide `.shared`.
final class AuthRefreshCoordinatorTests: XCTestCase {

    // MARK: - helpers

    /// Thread-safe call counter / log recorder for the `@Sendable` closures below.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _lines: [(AuthLogLevel, String)] = []
        private var _tokensSeen: [String] = []

        func hit(token: String? = nil) -> Int {
            lock.withLock {
                _calls += 1
                if let t = token { _tokensSeen.append(t) }
                return _calls
            }
        }
        var calls: Int { lock.withLock { _calls } }
        var tokensSeen: [String] { lock.withLock { _tokensSeen } }
        func log(_ level: AuthLogLevel, _ line: String) { lock.withLock { _lines.append((level, line)) } }
        var lines: [(AuthLogLevel, String)] { lock.withLock { _lines } }
        var text: String { lines.map { $0.1 }.joined(separator: "\n") }
    }

    private func makeCoordinator(_ probe: Probe = Probe(),
                                 now: @escaping @Sendable () -> Date = { Date() }) -> (AuthRefreshCoordinator, Probe) {
        let c = AuthRefreshCoordinator(now: now)
        c.setLogger { level, line in probe.log(level, line) }
        return (c, probe)
    }

    private func tokens(_ n: Int) -> AuthTokenSet {
        AuthTokenSet(accessToken: "A\(n)", refreshToken: "R\(n)", expiresInSec: 900)
    }

    private func request(_ trigger: AuthRefreshTrigger,
                         stale: String? = nil,
                         store: AuthCredentialStore?,
                         caller: String? = nil,
                         refresher: AuthRefreshRequest.Refresher? = nil,
                         renewer: AuthRefreshRequest.Renewer? = nil,
                         ignoreCooldown: Bool = false) -> AuthRefreshRequest {
        AuthRefreshRequest(trigger: trigger, staleAccessToken: stale, callerRefreshToken: caller,
                           store: store, refresher: refresher, renewer: renewer,
                           ignoreCooldown: ignoreCooldown)
    }

    // MARK: - (1) one flight

    func test_twoConcurrentTriggersMakeOneNetworkCall() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator()
        let probe = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            _ = probe.hit(token: token)
            try await Task.sleep(nanoseconds: 250_000_000)
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }

        // The proactive timer and a REST 401 on a different client, started together.
        async let proactive = coordinator.refresh(request(.proactive, store: store, refresher: refresher))
        async let rest401 = coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: refresher))
        let (a, b) = await (proactive, rest401)

        XCTAssertEqual(probe.calls, 1, "two triggers with the same refresh token must share one network call")
        XCTAssertEqual(probe.tokensSeen, ["R0"])
        XCTAssertEqual(a.tokens?.accessToken, "A1")
        XCTAssertEqual(b.tokens?.accessToken, "A1")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"))
    }

    func test_manyConcurrentCallersMakeOneNetworkCall() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator()
        let probe = Probe()
        let refresher: AuthRefreshRequest.Refresher = { _ in
            _ = probe.hit()
            try await Task.sleep(nanoseconds: 250_000_000)
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }
        let outcomes = await withTaskGroup(of: AuthRefreshOutcome.self) { group -> [AuthRefreshOutcome] in
            for i in 0..<8 {
                let trigger: AuthRefreshTrigger = i % 2 == 0 ? .rest401 : .wsAuthFailed
                group.addTask {
                    await coordinator.refresh(self.request(trigger, stale: "A0", store: store, refresher: refresher))
                }
            }
            var all: [AuthRefreshOutcome] = []
            for await o in group { all.append(o) }
            return all
        }
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(outcomes.count, 8)
        XCTAssertTrue(outcomes.allSatisfy { $0.tokens?.accessToken == "A1" })
    }

    /// A caller that arrives after the flight finished still holds the access token that
    /// was rejected: it must find the new pair in the store, not spend the new refresh token.
    func test_aLateCallerAdoptsTheStoredPairInsteadOfRefreshingAgain() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, probe) = makeCoordinator()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { _ in
            _ = net.hit()
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }
        let first = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: refresher))
        let late = await coordinator.refresh(request(.wsAuthFailed, stale: "A0", store: store, refresher: refresher))

        XCTAssertEqual(net.calls, 1)
        if case .refreshed = first {} else { XCTFail("first caller should have refreshed: \(first)") }
        if case .adopted(let t) = late {
            XCTAssertEqual(t.accessToken, "A1")
            XCTAssertEqual(t.refreshToken, "R1")
        } else {
            XCTFail("late caller should have adopted the stored pair: \(late)")
        }
        XCTAssertTrue(probe.text.contains("adopted"), "adoption is logged")
    }

    func test_theRefreshTokenComesFromTheStoreNotFromTheCallersStaleCopy() async {
        let store = InMemoryAuthCredentialStore(access: "A5", refresh: "R5")
        let (coordinator, _) = makeCoordinator()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            _ = net.hit(token: token)
            return AuthTokenSet(accessToken: "A6", refreshToken: "R6", expiresInSec: nil)
        }
        // The caller's provider was built before the last rotation and still holds R0 / A0.
        // (No stale-access adoption here: this is the proactive refresh.)
        _ = await coordinator.refresh(request(.proactive, store: store, caller: "R0", refresher: refresher))
        XCTAssertEqual(net.tokensSeen, ["R5"], "must present the stored token, never the stale copy")
    }

    func test_withoutAStoreEachClientUsesItsOwnCopyAndNothingIsPersisted() async {
        let (coordinator, _) = makeCoordinator()
        let net = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            _ = net.hit(token: token)
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }
        let out = await coordinator.refresh(request(.rest401, stale: "A0", store: nil, caller: "R0", refresher: refresher))
        XCTAssertEqual(net.tokensSeen, ["R0"])
        XCTAssertEqual(out.tokens?.accessToken, "A1")
    }

    // MARK: - (2) compare-and-swap

    func test_aStaleResultIsDiscardedAndNeverOverwritesANewerPair() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, probe) = makeCoordinator()
        // While our refresh is on the wire, another path (a login, a renew outside the
        // coordinator) rotates the pair in the store.
        let refresher: AuthRefreshRequest.Refresher = { _ in
            store.overwrite(access: "A-newer", refresh: "R-newer")
            return AuthTokenSet(accessToken: "A-stale-result", refreshToken: "R-stale-result", expiresInSec: nil)
        }
        let out = await coordinator.refresh(request(.proactive, store: store, refresher: refresher))

        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A-newer", refresh: "R-newer"),
                       "the older pair must not be written over the newer one")
        if case .adopted(let t) = out {
            XCTAssertEqual(t.accessToken, "A-newer")
            XCTAssertEqual(t.refreshToken, "R-newer")
        } else {
            XCTFail("a discarded result must resolve to the pair the store holds: \(out)")
        }
        XCTAssertTrue(probe.text.contains("stale result discarded"), "the discard is logged")
    }

    func test_aFreshResultIsPersistedWhenTheStoreStillHoldsTheSentToken() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator()
        let out = await coordinator.refresh(request(.proactive, store: store, refresher: { _ in
            AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }))
        if case .refreshed(_, let via) = out { XCTAssertEqual(via, .refresh) } else { XCTFail("\(out)") }
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"))
    }

    func test_casLeavesTheStoredRefreshTokenAloneWhenTheServerReturnsNone() throws {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let ok = try store.compareAndSwap(
            expectedRefresh: "R0", with: AuthTokenSet(accessToken: "A1", refreshToken: nil, expiresInSec: nil))
        XCTAssertTrue(ok)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R0"))
    }

    func test_casRefusesWhenTheExpectedTokenIsNotTheStoredOne() throws {
        let store = InMemoryAuthCredentialStore(access: "A9", refresh: "R9")
        let ok = try store.compareAndSwap(
            expectedRefresh: "R0", with: AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil))
        XCTAssertFalse(ok)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A9", refresh: "R9"))
    }

    func test_nilAndEmptyRefreshTokensCompareEqual() {
        XCTAssertTrue(AuthRefreshCoordinator.sameRefreshToken(nil, ""))
        XCTAssertTrue(AuthRefreshCoordinator.sameRefreshToken("", nil))
        XCTAssertTrue(AuthRefreshCoordinator.sameRefreshToken("x", "x"))
        XCTAssertFalse(AuthRefreshCoordinator.sameRefreshToken("x", "y"))
        XCTAssertFalse(AuthRefreshCoordinator.sameRefreshToken("x", nil))
    }

    // MARK: - (3) healing: rejected refresh goes to device-renew

    func test_aRejectedRefreshTokenGoesStraightToDeviceRenew() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R-dead")
        let (coordinator, probe) = makeCoordinator()
        let refreshCalls = Probe()
        let renewCalls = Probe()
        let out = await coordinator.refresh(request(
            .wsAuthFailed, stale: "A0", store: store,
            refresher: { _ in
                _ = refreshCalls.hit()
                throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
            },
            renewer: {
                _ = renewCalls.hit()
                return AuthTokenSet(accessToken: "A-renewed", refreshToken: "R-renewed", expiresInSec: 900)
            }))

        XCTAssertEqual(refreshCalls.calls, 1)
        XCTAssertEqual(renewCalls.calls, 1, "a rejected refresh must be followed by exactly one device-renew")
        if case .refreshed(let t, let via) = out {
            XCTAssertEqual(via, .deviceRenew)
            XCTAssertEqual(t.accessToken, "A-renewed")
        } else {
            XCTFail("\(out)")
        }
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A-renewed", refresh: "R-renewed"),
                       "the renewed pair is persisted over the dead token")
        XCTAssertTrue(probe.text.contains("reason=refresh_rejected"), "the rejection is logged with its reason code")
    }

    func test_aRefreshTokenRejectedWithNoRenewPathIsFinal() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R-dead")
        let (coordinator, _) = makeCoordinator()
        let out = await coordinator.refresh(request(
            .rest401, stale: "A0", store: store,
            refresher: { _ in throw AuthRecoveryFailure(reason: .refreshRejected, status: 401) }))
        XCTAssertEqual(out.failure?.reason, .refreshRejected)
        XCTAssertEqual(out.failure?.isFinal, true)
    }

    func test_aNetworkFailureOfTheRefreshIsNotFinal() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator()
        let out = await coordinator.refresh(request(
            .rest401, stale: "A0", store: store,
            refresher: { _ in throw AuthRecoveryFailure(reason: .refreshNetwork) }))
        XCTAssertEqual(out.failure?.reason, .refreshNetwork)
        XCTAssertEqual(out.failure?.isFinal, false)
    }

    // MARK: - (3b) backoff / cooldown

    func test_afterAFailureNonForcedCallersWaitOutTheCooldownButTheProactiveRefreshDoesNot() async {
        let clock = Clock0()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator(now: { clock.now })
        let net = Probe()
        let failing: AuthRefreshRequest.Refresher = { _ in
            _ = net.hit()
            throw AuthRecoveryFailure(reason: .refreshNetwork)
        }

        let first = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: failing))
        XCTAssertEqual(first.failure?.retryAfterSec, 5)
        XCTAssertEqual(net.calls, 1)

        // Inside the cooldown a REST caller fails fast, no network.
        let second = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: failing))
        XCTAssertEqual(net.calls, 1)
        XCTAssertEqual(second.failure?.reason, .cooldown)
        XCTAssertEqual(second.failure?.underlyingReason, .refreshNetwork)

        // The proactive / foreground refresh ignores the cooldown (and doubles the next one).
        let forced = await coordinator.refresh(request(.proactive, store: store, refresher: failing, ignoreCooldown: true))
        XCTAssertEqual(net.calls, 2)
        XCTAssertEqual(forced.failure?.retryAfterSec, 15)

        // After the cooldown the REST caller tries again and a success clears the state.
        clock.advance(by: 20)
        let ok: AuthRefreshRequest.Refresher = { _ in
            _ = net.hit()
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }
        let third = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: ok))
        XCTAssertEqual(net.calls, 3)
        XCTAssertTrue(third.isSuccess)
        XCTAssertEqual(AuthRefreshCoordinator.backoffSeconds(forFailures: 1), 5)
        XCTAssertEqual(AuthRefreshCoordinator.backoffSeconds(forFailures: 4), 120)
        XCTAssertEqual(AuthRefreshCoordinator.backoffSeconds(forFailures: 40), 120)
    }

    func test_anUnreadableStoreFailsWithoutSpendingTheRefreshToken() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        store.setUnreadable(status: -25308)
        let (coordinator, probe) = makeCoordinator()
        let net = Probe()
        let out = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: { _ in
            _ = net.hit()
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }))
        XCTAssertEqual(net.calls, 0)
        XCTAssertEqual(out.failure?.reason, .storeUnreadable)
        XCTAssertEqual(out.failure?.isFinal, false)
        XCTAssertTrue(probe.text.contains("reason=keychain_unreadable"))
    }

    // MARK: - (5) a signed-out store is never resurrected, no tokens cross accounts

    /// A compact JWT shaped like the server's access token (`uid` and `sub` carry the user id).
    /// The signature is junk: the coordinator only reads the claim.
    private func jwt(uid: String, jti: String = "1") -> String {
        func b64url(_ object: [String: Any]) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(["alg": "none", "typ": "JWT"])
        let payload = b64url(["uid": uid, "sub": uid, "jti": jti])
        return "\(header).\(payload).sig"
    }

    func test_anEmptyStoreIsNeverResurrectedByACallersOwnRefreshToken() async throws {
        // Logged out: the Keychain was cleared, but a client built before that (an upload in
        // flight, the socket's recovery task) still holds its own copy of an old refresh token.
        let store = InMemoryAuthCredentialStore(access: nil, refresh: nil)
        let (coordinator, probe) = makeCoordinator()
        let refreshes = Probe()
        let renews = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            _ = refreshes.hit(token: token)
            return AuthTokenSet(accessToken: "A-back", refreshToken: "R-back", expiresInSec: 900)
        }
        let renewer: AuthRefreshRequest.Renewer = {
            _ = renews.hit()
            return AuthTokenSet(accessToken: "A-renewed", refreshToken: "R-renewed", expiresInSec: 900)
        }

        let triggers: [AuthRefreshTrigger] = [.rest401, .wsAuthFailed, .external, .proactive]
        for trigger in triggers {
            let out = await coordinator.refresh(request(
                trigger, stale: "A-old", store: store, caller: "R-old",
                refresher: refresher, renewer: renewer, ignoreCooldown: true))
            XCTAssertEqual(out.failure?.reason, .signedOut, "\(trigger)")
            XCTAssertEqual(out.failure?.isFinal, true, "\(trigger)")
            XCTAssertNil(out.tokens, "\(trigger)")
        }

        XCTAssertEqual(refreshes.calls, 0, "no network call may be made on a logged-out device")
        XCTAssertEqual(renews.calls, 0)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: nil, refresh: nil),
                       "nothing may be written back into the emptied store")
        XCTAssertTrue(probe.text.contains("reason=signed_out"))
        XCTAssertFalse(probe.text.contains("R-old"), "no token in the logs")
    }

    func test_aStoreWithoutARefreshTokenNeverFallsBackToTheCallersCopy() async throws {
        // Access token present, refresh token absent: still a session, one that can renew by
        // device key, but a caller's own (possibly stale) refresh token is not the way back.
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        let (coordinator, _) = makeCoordinator()
        let refreshes = Probe()
        let renews = Probe()
        let out = await coordinator.refresh(request(
            .rest401, stale: "A0", store: store, caller: "R-old",
            refresher: { token in
                _ = refreshes.hit(token: token)
                return AuthTokenSet(accessToken: "A-back", refreshToken: "R-back", expiresInSec: 900)
            },
            renewer: {
                _ = renews.hit()
                return AuthTokenSet(accessToken: "A-renewed", refreshToken: "R-renewed", expiresInSec: 900)
            }))

        XCTAssertEqual(refreshes.calls, 0, "the caller's copy must never be presented when a store is attached")
        XCTAssertEqual(renews.calls, 1)
        XCTAssertEqual(out.tokens?.accessToken, "A-renewed")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A-renewed", refresh: "R-renewed"))
    }

    func test_aFlightThatLosesTheRaceToALogoutWritesNothing() async throws {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator()
        let out = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: { _ in
            // Logout while the call is on the wire.
            store.overwrite(access: nil, refresh: nil)
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }))

        XCTAssertFalse(out.isSuccess)
        XCTAssertEqual(out.failure?.reason, .casLost)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: nil, refresh: nil),
                       "a result that arrives after the logout must not sign the device back in")
    }

    func test_theStoredPairOfAnotherAccountIsNeverHandedToAClientOfTheOldOne() async throws {
        let alice = jwt(uid: "alice")
        let bob = jwt(uid: "bob")
        // Alice logged out, Bob logged in; a client built for Alice gets a 401 afterwards.
        let store = InMemoryAuthCredentialStore(access: bob, refresh: "R-bob")
        let (coordinator, probe) = makeCoordinator()
        let refreshes = Probe()

        let triggers: [AuthRefreshTrigger] = [.rest401, .wsAuthFailed, .external]
        for trigger in triggers {
            let out = await coordinator.refresh(request(
                trigger, stale: alice, store: store, caller: "R-alice",
                refresher: { token in
                    _ = refreshes.hit(token: token)
                    return AuthTokenSet(accessToken: "A-x", refreshToken: "R-x", expiresInSec: nil)
                }))
            XCTAssertEqual(out.failure?.reason, .accountChanged, "\(trigger)")
            XCTAssertEqual(out.failure?.isFinal, true, "\(trigger)")
            XCTAssertNil(out.tokens, "\(trigger): Bob's tokens must not reach Alice's client")
        }

        XCTAssertEqual(refreshes.calls, 0, "Bob's refresh token must not be spent for Alice's client")
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: bob, refresh: "R-bob"))
        XCTAssertTrue(probe.text.contains("reason=account_changed"))
    }

    func test_aNewerPairOfTheSameAccountIsStillAdopted() async {
        let first = jwt(uid: "alice", jti: "1")
        let second = jwt(uid: "alice", jti: "2")
        let store = InMemoryAuthCredentialStore(access: second, refresh: "R2")
        let (coordinator, _) = makeCoordinator()
        let out = await coordinator.refresh(request(.rest401, stale: first, store: store, refresher: { _ in
            XCTFail("an already rotated pair must be adopted, not refreshed again")
            return AuthTokenSet(accessToken: "A-x", refreshToken: "R-x", expiresInSec: nil)
        }))
        if case .adopted(let t) = out {
            XCTAssertEqual(t.accessToken, second)
        } else {
            XCTFail("\(out)")
        }
    }

    func test_aResultThatLostTheRaceToAnotherAccountsLoginIsNotHandedOver() async throws {
        let alice = jwt(uid: "alice", jti: "1")
        let aliceNext = jwt(uid: "alice", jti: "2")
        let bob = jwt(uid: "bob")
        let store = InMemoryAuthCredentialStore(access: alice, refresh: "R-alice")
        let (coordinator, _) = makeCoordinator()
        let out = await coordinator.refresh(request(.rest401, stale: alice, store: store, refresher: { _ in
            // Logout, then a login as Bob, while Alice's refresh is on the wire.
            store.overwrite(access: bob, refresh: "R-bob")
            return AuthTokenSet(accessToken: aliceNext, refreshToken: "R-alice-2", expiresInSec: nil)
        }))

        XCTAssertEqual(out.failure?.reason, .accountChanged)
        XCTAssertNil(out.tokens)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: bob, refresh: "R-bob"),
                       "Alice's result must not overwrite Bob's pair")
    }

    func test_theAccountOfAnAccessTokenIsReadFromItsClaims() {
        XCTAssertEqual(AuthRefreshCoordinator.accountId(ofAccessToken: jwt(uid: "u-1")), "u-1")
        XCTAssertNil(AuthRefreshCoordinator.accountId(ofAccessToken: "opaque"))
        XCTAssertNil(AuthRefreshCoordinator.accountId(ofAccessToken: "a.b.c"))
        XCTAssertTrue(AuthRefreshCoordinator.sameAccount("opaque", jwt(uid: "x")), "undecodable: never blocks")
        XCTAssertTrue(AuthRefreshCoordinator.sameAccount(jwt(uid: "x", jti: "1"), jwt(uid: "x", jti: "2")))
        XCTAssertFalse(AuthRefreshCoordinator.sameAccount(jwt(uid: "x"), jwt(uid: "y")))
    }

    func test_resetBackoffForgetsTheCooldownTheRenewCooldownAndTheDeadToken() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R-dead")
        let (coordinator, _) = makeCoordinator()
        let renewFails: AuthRefreshRequest.Renewer = { throw AuthRecoveryFailure(reason: .renewServerError, status: 503) }
        let rejected: AuthRefreshRequest.Refresher = { _ in throw AuthRecoveryFailure(reason: .refreshRejected, status: 401) }
        _ = await coordinator.refresh(request(.proactive, store: store, refresher: rejected, renewer: renewFails,
                                              ignoreCooldown: true))
        let cooling = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: rejected,
                                                        renewer: renewFails))
        XCTAssertEqual(cooling.failure?.reason, .cooldown, "precondition: the failed session is cooling down")

        // New session: a fresh login, a fresh refresh token. Nothing of the old one is remembered.
        coordinator.resetBackoff()
        store.overwrite(access: "A9", refresh: "R-new")
        let net = Probe()
        let out = await coordinator.refresh(request(.rest401, stale: "A9", store: store, refresher: { token in
            _ = net.hit(token: token)
            return AuthTokenSet(accessToken: "A10", refreshToken: "R10", expiresInSec: nil)
        }, renewer: renewFails))
        XCTAssertTrue(out.isSuccess)
        XCTAssertEqual(net.tokensSeen, ["R-new"])
    }

    func test_aFlightThatStartedBeforeALogoutLeavesNoCooldownForTheNextSession() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator()
        _ = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: { _ in
            coordinator.resetBackoff() // logout / login while the call is on the wire
            throw AuthRecoveryFailure(reason: .refreshNetwork)
        }))

        let net = Probe()
        let next = await coordinator.refresh(request(.rest401, stale: "A0", store: store, refresher: { _ in
            _ = net.hit()
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }))
        XCTAssertEqual(net.calls, 1, "the old session's failure must not put the new session into cooldown")
        XCTAssertTrue(next.isSuccess)
    }

    // MARK: - (6) renew only on rejection, paced by the server's budget

    func test_aRefreshThatFailedForAnyReasonButRejectionMakesZeroRenewCalls() async {
        let failures: [(String, AuthRecoveryFailure)] = [
            ("network", AuthRecoveryFailure(reason: .refreshNetwork)),
            ("5xx", AuthRecoveryFailure(reason: .refreshServerError, status: 503)),
            ("429", AuthRecoveryFailure(reason: .refreshServerError, status: 429, retryAfterSec: 60)),
            ("other", AuthRecoveryFailure(reason: .refreshOther)),
        ]
        for (name, failure) in failures {
            let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
            let (coordinator, _) = makeCoordinator()
            let renews = Probe()
            let out = await coordinator.refresh(request(
                .rest401, stale: "A0", store: store,
                refresher: { _ in throw failure },
                renewer: {
                    _ = renews.hit()
                    return AuthTokenSet(accessToken: "A-renewed", refreshToken: "R-renewed", expiresInSec: nil)
                }))
            XCTAssertEqual(renews.calls, 0, "\(name): a transient refresh failure must not spend renew budget")
            XCTAssertEqual(out.failure?.reason, failure.reason, name)
            XCTAssertEqual(out.failure?.isFinal, false, name)
        }
    }

    func test_aRefresh429WaitsAtLeastItsRetryAfter() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let (coordinator, _) = makeCoordinator()
        let out = await coordinator.refresh(request(
            .rest401, stale: "A0", store: store,
            refresher: { _ in throw AuthRecoveryFailure(reason: .refreshServerError, status: 429, retryAfterSec: 90) }))
        XCTAssertEqual(out.failure?.retryAfterSec, 90, "the ladder's first step is 5 s; Retry-After raises it")
    }

    func test_aRenewFailureHoldsTheRenewLegBackAndARejectedTokenIsNotPresentedAgain() async {
        let clock = Clock0()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R-dead")
        let (coordinator, probe) = makeCoordinator(now: { clock.now })
        let refreshes = Probe()
        let renews = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            _ = refreshes.hit(token: token)
            throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
        }
        let renewer: AuthRefreshRequest.Renewer = {
            _ = renews.hit()
            throw AuthRecoveryFailure(reason: .renewServerError, status: 503)
        }
        func attempt() async -> AuthRefreshOutcome {
            // The proactive refresh ignores the ordinary cooldown, like the foreground and push-wake paths.
            await coordinator.refresh(request(.proactive, store: store, refresher: refresher, renewer: renewer,
                                              ignoreCooldown: true))
        }

        let first = await attempt()
        XCTAssertEqual(refreshes.calls, 1)
        XCTAssertEqual(renews.calls, 1)
        XCTAssertEqual(first.failure?.reason, .renewServerError)
        XCTAssertEqual(first.failure?.retryAfterSec, AuthRefreshCoordinator.renewCooldownFloorSec,
                       "a renew failure waits at least 10 minutes (6 per hour)")

        // The 5 s ladder step, a foreground, a push wake: nothing may leave the device.
        clock.advance(by: 5)
        let second = await attempt()
        XCTAssertEqual(refreshes.calls, 1, "the refresh token the server rejected is not presented again")
        XCTAssertEqual(renews.calls, 1, "device-renew waits out its budget")
        XCTAssertEqual(second.failure?.reason, .renewBudget)
        XCTAssertEqual(second.failure?.underlyingReason, .renewServerError)
        XCTAssertEqual(second.failure?.retryAfterSec, AuthRefreshCoordinator.renewCooldownFloorSec - 5)
        XCTAssertTrue(probe.text.contains("reason=renew_budget"))
        XCTAssertTrue(probe.text.contains("refresh_token_known_dead=1"))

        // Past the budget the renew runs again; the dead refresh token still stays out of it.
        clock.advance(by: 601)
        _ = await attempt()
        XCTAssertEqual(renews.calls, 2)
        XCTAssertEqual(refreshes.calls, 1)
    }

    func test_aRejectedTokenIsRememberedAsDeadOnlyForHalfAnHour() async {
        let clock = Clock0()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R-dead")
        let (coordinator, _) = makeCoordinator(now: { clock.now })
        let refreshes = Probe()
        let refresher: AuthRefreshRequest.Refresher = { token in
            _ = refreshes.hit(token: token)
            throw AuthRecoveryFailure(reason: .refreshRejected, status: 401)
        }
        func attempt() async -> AuthRefreshOutcome {
            // No renew path: a rejected token is final here, and every attempt is a real decision.
            await coordinator.refresh(request(.proactive, store: store, refresher: refresher, ignoreCooldown: true))
        }

        let first = await attempt()
        XCTAssertEqual(first.failure?.isFinal, true)
        XCTAssertEqual(refreshes.calls, 1)

        clock.advance(by: 600)
        let second = await attempt()
        XCTAssertEqual(refreshes.calls, 1, "within the memory window the dead token is not presented again")
        XCTAssertEqual(second.failure?.reason, .refreshRejected)
        XCTAssertEqual(second.failure?.isFinal, true)

        clock.advance(by: TimeInterval(AuthRefreshCoordinator.deadTokenMemorySec))
        _ = await attempt()
        XCTAssertEqual(refreshes.calls, 2, "after the window a spurious rejection can heal")
    }

    func test_aRenewRetryAfterIsHonouredAboveTheFloorAndCapped() async {
        let cases: [(Int, Int)] = [
            (60, 600),        // the server's usual Retry-After: never below the 10 minute floor
            (1200, 1200),     // longer than the floor: honoured
            (999_999, 3600),  // absurd: capped at an hour
        ]
        for (retryAfter, expected) in cases {
            let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
            let (coordinator, _) = makeCoordinator()
            let out = await coordinator.refresh(request(
                .proactive, store: store,
                renewer: { throw AuthRecoveryFailure(reason: .renewServerError, status: 429, retryAfterSec: retryAfter) },
                ignoreCooldown: true))
            XCTAssertEqual(out.failure?.retryAfterSec, expected, "Retry-After \(retryAfter)")
        }
    }

    func test_aFailureThatNeverLeftTheDeviceDoesNotSpendTheRenewBudget() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        let (coordinator, _) = makeCoordinator()
        let renews = Probe()
        let renewer: AuthRefreshRequest.Renewer = {
            _ = renews.hit()
            throw AuthRecoveryFailure(reason: .renewKeychainLocked)
        }
        // A locked Keychain heals as soon as the user unlocks the phone: the next attempt must run.
        for _ in 0..<3 {
            let out = await coordinator.refresh(request(.proactive, store: store, renewer: renewer, ignoreCooldown: true))
            XCTAssertEqual(out.failure?.reason, .renewKeychainLocked)
        }
        XCTAssertEqual(renews.calls, 3)
    }

    func test_aRenewThatWorksClearsTheRenewCooldown() async {
        let clock = Clock0()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        let (coordinator, _) = makeCoordinator(now: { clock.now })
        let renews = Probe()
        let outcomes: [Bool] = [false, true, true]  // fail, then succeed, then be called again
        let renewer: AuthRefreshRequest.Renewer = {
            let n = renews.hit()
            if !outcomes[n - 1] { throw AuthRecoveryFailure(reason: .renewServerError, status: 503) }
            return AuthTokenSet(accessToken: "A\(n)", refreshToken: "R\(n)", expiresInSec: nil)
        }
        func attempt() async -> AuthRefreshOutcome {
            await coordinator.refresh(request(.proactive, store: store, renewer: renewer, ignoreCooldown: true))
        }
        _ = await attempt()
        clock.advance(by: 601)
        let ok = await attempt()
        XCTAssertTrue(ok.isSuccess)
        // No cooldown left over: the very next attempt runs.
        let again = await attempt()
        XCTAssertTrue(again.isSuccess)
        XCTAssertEqual(renews.calls, 3)
    }

    // MARK: - (4) every renew failure path logs a reason code, no secrets

    private func renewFailureLine(_ error: Error,
                                  file: StaticString = #filePath, line: UInt = #line) async -> (AuthRecoveryFailure?, String, [(AuthLogLevel, String)]) {
        let probe = Probe()
        let client = BCryptoRestClient(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: "SECRET-ACCESS", refreshToken: "SECRET-REFRESH"))
        let coordinator = AuthRefreshCoordinator()
        coordinator.setLogger { level, text in probe.log(level, text) }
        client.authCoordinator = coordinator
        client.credentialStore = InMemoryAuthCredentialStore(access: "SECRET-ACCESS", refresh: "SECRET-REFRESH")
        client.setTokenRefresher { _ in throw BCryptoError.unauthorized }
        client.setDeviceRenewFallback { throw error }

        let outcome = await client.refreshSession(trigger: .rest401)
        return (outcome.failure, probe.text, probe.lines)
    }

    func test_everyRenewFailurePathIsLoggedWithItsReasonCode() async {
        let cases: [(String, Error, AuthRecoveryReason, Bool)] = [
            ("no device id", AuthRenewPreconditionError.noDeviceId, .renewNoDeviceId, true),
            ("ed25519 key not provisioned", BCryptoDeviceRenewClient.Error.ed25519PrivateNotProvisioned,
             .renewKeyNotProvisioned, true),
            ("keychain locked", KeyVaultError.deviceLocked, .renewKeychainLocked, false),
            ("keychain error", KeyVaultError.loadFailed(-34018), .renewKeychainError, false),
            ("network", URLError(.notConnectedToInternet), .renewNetwork, false),
            ("server revoked device", BCryptoDeviceRenewClient.Error.serverRejected(.httpError(403)),
             .renewRejected, true),
            ("server bad signature", BCryptoDeviceRenewClient.Error.serverRejected(.unauthorized),
             .renewRejected, false),
            ("server 5xx", BCryptoDeviceRenewClient.Error.serverRejected(.httpError(503)),
             .renewServerError, false),
            ("malformed challenge", BCryptoDeviceRenewClient.Error.malformedNonceHex,
             .renewMalformedChallenge, false),
            ("challenge GET 5xx", BCryptoError.httpError(502), .renewServerError, false),
            ("rate limited, Retry-After", BCryptoRateLimitedError(retryAfterSec: 120), .renewServerError, false),
            ("rate limited, no header", BCryptoDeviceRenewClient.Error.serverRejected(.httpError(429)),
             .renewServerError, false),
        ]
        for (name, error, reason, isFinal) in cases {
            let (failure, text, lines) = await renewFailureLine(error)
            XCTAssertEqual(failure?.reason, reason, name)
            XCTAssertEqual(failure?.isFinal, isFinal, name)
            XCTAssertTrue(text.contains("reason=\(reason.rawValue)"), "\(name): no log line carries the reason code\n\(text)")
            XCTAssertTrue(text.contains("renew step failed"), "\(name): the renew step failure is logged")
            XCTAssertTrue(lines.contains { $0.0 == .warn || $0.0 == .error },
                          "\(name): must log at warn or error")
            XCTAssertFalse(text.contains("SECRET"), "\(name): logs must never contain a token")
        }
    }

    func test_aServerStatusIsLoggedAsANumber() async {
        let (failure, text, _) = await renewFailureLine(BCryptoDeviceRenewClient.Error.serverRejected(.httpError(412)))
        XCTAssertEqual(failure?.status, 412)
        XCTAssertTrue(text.contains("status=412"), text)
    }

    // MARK: - REST client + provider wiring

    func test_twoClientsWithTheSameStoreShareOneRefresh() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let coordinator = AuthRefreshCoordinator()
        let net = Probe()
        func makeClient() -> BCryptoRestClient {
            let c = BCryptoRestClient(config: BackendConfig(
                serverUrl: "https://example.invalid", accessToken: "A0", refreshToken: "R0"))
            c.authCoordinator = coordinator
            c.credentialStore = store
            c.setTokenRefresher { token in
                _ = net.hit(token: token)
                try await Task.sleep(nanoseconds: 250_000_000)
                return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
            }
            return c
        }
        let a = makeClient()
        let b = makeClient()

        // The app's proactive refresh (through one provider's client) and a REST 401 on another.
        async let x = a.refreshSession(trigger: .proactive, ignoreCooldown: true)
        async let y = b.refreshSession(trigger: .rest401)
        let (ox, oy) = await (x, y)

        XCTAssertEqual(net.calls, 1)
        XCTAssertTrue(ox.isSuccess)
        XCTAssertTrue(oy.isSuccess)
        // Both clients end up on the same, new tokens.
        XCTAssertEqual(a.accessToken, "A1")
        XCTAssertEqual(b.accessToken, "A1")
        XCTAssertEqual(a.refreshToken, "R1")
        XCTAssertEqual(b.refreshToken, "R1")
    }

    func test_appliedTokensReachTheProvidersTransportsWithoutBeingPersistedTwice() async {
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let provider = BCryptoBackendProvider(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: "A0", refreshToken: "R0"))
        let persisted = Probe()
        provider.onTokenRotated = { _, _ in _ = persisted.hit() }
        provider.credentialStore = store
        provider.getRestClient().authCoordinator = AuthRefreshCoordinator()
        provider.getRestClient().setTokenRefresher { _ in
            AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }

        let outcome = await provider.refreshSession(trigger: .proactive, ignoreCooldown: true)

        XCTAssertTrue(outcome.isSuccess)
        XCTAssertEqual(provider.config.accessToken, "A1")
        XCTAssertEqual(provider.config.refreshToken, "R1")
        XCTAssertEqual(persisted.calls, 0,
                       "the coordinator already wrote the pair with compare-and-swap; onTokenRotated must not write it again")
    }

    func test_applyTokenPairStillPersistsByDefault() {
        let provider = BCryptoBackendProvider(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: "A0", refreshToken: "R0"))
        let persisted = Probe()
        provider.onTokenRotated = { _, _ in _ = persisted.hit() }
        provider.applyTokenPair(access: "A1", refresh: "R1")
        XCTAssertEqual(persisted.calls, 1, "a fresh login still persists through onTokenRotated")
        provider.applyTokenPair(access: "A2", refresh: "R2", persist: false)
        XCTAssertEqual(persisted.calls, 1)
    }

    // MARK: - the socket's verdict

    private func verdict(forRenewError error: Error) async -> AuthRecoveryVerdict? {
        let provider = BCryptoBackendProvider(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: "A0", refreshToken: nil))
        provider.credentialStore = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        provider.getRestClient().authCoordinator = AuthRefreshCoordinator()
        provider.getRestClient().setDeviceRenewFallback { throw error }
        let ws = provider.getWebSocketClient()
        return await ws.onAuthFailedRecover?()
    }

    func test_aTransientRecoveryFailureDoesNotParkTheSocket() async {
        for error in [KeyVaultError.deviceLocked as Error,
                      URLError(.timedOut) as Error,
                      BCryptoDeviceRenewClient.Error.serverRejected(.httpError(503)) as Error] {
            let v = await verdict(forRenewError: error)
            if case .transient(let retry)? = v {
                XCTAssertGreaterThan(retry, 0, "\(error)")
            } else {
                XCTFail("\(error) must not park the socket, got \(String(describing: v))")
            }
        }
    }

    func test_onlyAConfirmedRevocationOrMissingCredentialParksTheSocket() async {
        for error in [AuthRenewPreconditionError.noDeviceId as Error,
                      BCryptoDeviceRenewClient.Error.ed25519PrivateNotProvisioned as Error,
                      BCryptoDeviceRenewClient.Error.serverRejected(.httpError(403)) as Error] {
            let v = await verdict(forRenewError: error)
            XCTAssertEqual(v, .revoked, "\(error)")
        }
    }

    func test_aSuccessfulRecoveryResumesTheSocket() async {
        let provider = BCryptoBackendProvider(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: "A0", refreshToken: nil))
        provider.credentialStore = InMemoryAuthCredentialStore(access: "A0", refresh: nil)
        provider.getRestClient().authCoordinator = AuthRefreshCoordinator()
        provider.getRestClient().setDeviceRenewFallback {
            AuthTokenSet(accessToken: "A-renewed", refreshToken: "R-renewed", expiresInSec: 900)
        }
        let v = await provider.getWebSocketClient().onAuthFailedRecover?()
        XCTAssertEqual(v, .recovered)
        XCTAssertEqual(provider.config.accessToken, "A-renewed")
    }
}

/// A clock the cooldown test can move.
private final class Clock0: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { t } }
    func advance(by seconds: TimeInterval) { lock.withLock { t = t.addingTimeInterval(seconds) } }
}

// MARK: - 429 classification and the typed error the recovery endpoints throw

final class AuthRateLimitTests: XCTestCase {

    override func tearDown() {
        AuthRateLimitStubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Retry-After parsing

    func test_retryAfterIsParsedAsDeltaSecondsOnly() {
        XCTAssertEqual(BCryptoRateLimitedError.parse("60"), 60)
        XCTAssertEqual(BCryptoRateLimitedError.parse(" 120 "), 120)
        XCTAssertEqual(BCryptoRateLimitedError.parse("1.2"), 2, "rounded up, never shorter than asked")
        XCTAssertEqual(BCryptoRateLimitedError.parse("999999"), 3600, "capped at an hour")
        XCTAssertNil(BCryptoRateLimitedError.parse("Wed, 21 Oct 2026 07:28:00 GMT"), "an HTTP-date is not used")
        XCTAssertNil(BCryptoRateLimitedError.parse("-5"))
        XCTAssertNil(BCryptoRateLimitedError.parse("0"))
        XCTAssertNil(BCryptoRateLimitedError.parse("nan"))
        XCTAssertNil(BCryptoRateLimitedError.parse(""))
        XCTAssertNil(BCryptoRateLimitedError.parse(nil))
    }

    // MARK: classifier

    func test_aRefresh429IsAServerErrorThatWaitsAtLeastAMinute() {
        let withHeader = AuthFailureClassifier.classifyRefresh(BCryptoRateLimitedError(retryAfterSec: 120))
        XCTAssertEqual(withHeader.reason, .refreshServerError)
        XCTAssertEqual(withHeader.status, 429)
        XCTAssertEqual(withHeader.retryAfterSec, 120)
        XCTAssertFalse(withHeader.isFinal)

        XCTAssertEqual(AuthFailureClassifier.classifyRefresh(BCryptoRateLimitedError(retryAfterSec: 5)).retryAfterSec, 60,
                       "never below the 60 s floor")
        XCTAssertEqual(AuthFailureClassifier.classifyRefresh(BCryptoRateLimitedError(retryAfterSec: nil)).retryAfterSec, 60)
        XCTAssertEqual(AuthFailureClassifier.classifyRefresh(BCryptoError.httpError(429)).retryAfterSec, 60)
    }

    func test_aRenew429IsAServerErrorThatWaitsAtLeastAMinute() {
        let withHeader = AuthFailureClassifier.classifyRenew(BCryptoRateLimitedError(retryAfterSec: 300))
        XCTAssertEqual(withHeader.reason, .renewServerError)
        XCTAssertEqual(withHeader.status, 429)
        XCTAssertEqual(withHeader.retryAfterSec, 300)
        XCTAssertFalse(withHeader.isFinal)

        XCTAssertEqual(AuthFailureClassifier.classifyRenew(BCryptoRateLimitedError(retryAfterSec: nil)).retryAfterSec, 60)
        let wrapped = AuthFailureClassifier.classifyRenew(BCryptoDeviceRenewClient.Error.serverRejected(.httpError(429)))
        XCTAssertEqual(wrapped.reason, .renewServerError)
        XCTAssertEqual(wrapped.retryAfterSec, 60)
        XCTAssertEqual(AuthFailureClassifier.classifyRenew(BCryptoError.httpError(503)).retryAfterSec, 0,
                       "a 5xx carries no pacing hint of its own")
    }

    // MARK: the REST client

    private func makeClient() -> BCryptoRestClient {
        BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://auth.test", accessToken: "tok"),
            testURLProtocolClasses: [AuthRateLimitStubProtocol.self])
    }

    private func thrown(_ operation: () async throws -> Data) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    func test_aRecoveryEndpoint429ThrowsATypedErrorWithRetryAfter() async {
        AuthRateLimitStubProtocol.handler = { request in
            AuthRateLimitStubProtocol.response(for: request, status: 429, retryAfter: "120")
        }
        let client = makeClient()

        let renew = await thrown { try await client.post("/api/v1/auth/device-renew", body: Data("{}".utf8)) }
        XCTAssertEqual(renew as? BCryptoRateLimitedError, BCryptoRateLimitedError(retryAfterSec: 120))

        let challenge = await thrown { try await client.get("/api/v1/auth/device-challenge?device_id=abc") }
        XCTAssertEqual(challenge as? BCryptoRateLimitedError, BCryptoRateLimitedError(retryAfterSec: 120),
                       "the query string of the challenge GET must not hide the endpoint")

        let refresh = await thrown { try await client.post("/api/v1/auth/refresh", body: Data("{}".utf8)) }
        XCTAssertEqual(refresh as? BCryptoRateLimitedError, BCryptoRateLimitedError(retryAfterSec: 120))
    }

    func test_aRecoveryEndpoint429WithoutAHeaderStillThrowsTheTypedError() async {
        AuthRateLimitStubProtocol.handler = { request in
            AuthRateLimitStubProtocol.response(for: request, status: 429, retryAfter: nil)
        }
        let renew = await thrown { try await makeClient().post("/api/v1/auth/device-renew", body: Data("{}".utf8)) }
        XCTAssertEqual(renew as? BCryptoRateLimitedError, BCryptoRateLimitedError(retryAfterSec: nil))
    }

    func test_every429OnAnyOtherEndpointStaysAPlainHttpError() async {
        AuthRateLimitStubProtocol.handler = { request in
            AuthRateLimitStubProtocol.response(for: request, status: 429, retryAfter: "120")
        }
        let client = makeClient()
        for path in ["/api/v1/profile", "/api/v1/auth/login", "/api/v1/auth/device-challenge-other"] {
            let error = await thrown { try await client.get(path) }
            guard let bc = error as? BCryptoError, case .httpError(let status) = bc else {
                XCTFail("\(path): expected BCryptoError.httpError(429), got \(String(describing: error))")
                continue
            }
            XCTAssertEqual(status, 429, path)
        }
    }

    func test_aRecoveryEndpointThatAnswers503KeepsItsPlainHttpError() async {
        AuthRateLimitStubProtocol.handler = { request in
            AuthRateLimitStubProtocol.response(for: request, status: 503, retryAfter: "30")
        }
        let error = await thrown { try await makeClient().post("/api/v1/auth/device-renew", body: Data("{}".utf8)) }
        guard let bc = error as? BCryptoError, case .httpError(let status) = bc else {
            XCTFail("expected BCryptoError.httpError(503), got \(String(describing: error))")
            return
        }
        XCTAssertEqual(status, 503)
    }
}

private final class AuthRateLimitStubProtocol: URLProtocol {
    /// Answers every request with this status and optional `Retry-After`.
    static var handler: ((URLRequest) -> (status: Int, retryAfter: String?))?

    static func response(for request: URLRequest, status: Int, retryAfter: String?) -> (status: Int, retryAfter: String?) {
        (status, retryAfter)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = AuthRateLimitStubProtocol.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let answer = handler(request)
        var headers: [String: String] = [:]
        if let retryAfter = answer.retryAfter { headers["Retry-After"] = retryAfter }
        guard let http = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                         headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -2))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

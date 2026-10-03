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

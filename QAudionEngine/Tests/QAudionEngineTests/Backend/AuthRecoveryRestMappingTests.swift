import XCTest
@testable import QAudionEngine

/// 2026-10-03 — what the REST client says when a 401 could not be healed.
///
/// `BCryptoError.unauthorized` is the one error the app answers with `clearToken()` and a forced
/// QR re-pair (the launch `getProfile` catch). Before this, EVERY failed recovery surfaced as
/// `.unauthorized`, and with the process-wide coordinator one transient failure (a cooldown, a
/// dropped connection, a 5xx, a locked Keychain) reaches several callers at once at cold start.
/// Now only a failure that PROVES the credentials are gone may say so; every other failure is a
/// `BCryptoSessionRecoveryError`, which nothing treats as a reason to wipe a token.
///
/// The REST client is built with a stub `URLProtocol` that answers 401 (so the recovery runs)
/// and an in-memory credential store in place of the Keychain.
final class AuthRecoveryRestMappingTests: XCTestCase {

    override func tearDown() {
        RecoveryStubProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - helpers

    private func makeClient(store: InMemoryAuthCredentialStore?,
                            coordinator: AuthRefreshCoordinator = AuthRefreshCoordinator()) -> BCryptoRestClient {
        let client = BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://auth.test", accessToken: "A0", refreshToken: "R0"),
            testURLProtocolClasses: [RecoveryStubProtocol.self])
        client.authCoordinator = coordinator
        client.credentialStore = store
        return client
    }

    private func thrown(_ operation: () async throws -> Data) async -> Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    private func isUnauthorized(_ error: Error?) -> Bool {
        guard let bc = error as? BCryptoError, case .unauthorized = bc else { return false }
        return true
    }

    /// One `GET /api/v1/profile` (the launch call) through a client whose recovery legs fail
    /// with the given errors. The stub answers 401, so the recovery cascade always runs.
    private func profileError(refreshError: Error?, renewError: Error?,
                              store: InMemoryAuthCredentialStore?) async -> Error? {
        RecoveryStubProtocol.handler = { _ in 401 }
        let client = makeClient(store: store)
        if let refreshError {
            client.setTokenRefresher { _ in throw refreshError }
        }
        if let renewError {
            client.setDeviceRenewFallback { throw renewError }
        }
        return await thrown { try await client.get("/api/v1/profile") }
    }

    // MARK: - transient failures never say "credentials gone"

    func test_aTransientRecoveryFailureSurfacesAsATransientErrorNeverAsUnauthorized() async {
        let rejected: Error = BCryptoError.unauthorized
        let cases: [(String, Error?, Error?, AuthRecoveryReason)] = [
            ("refresh: offline", URLError(.notConnectedToInternet), nil, .refreshNetwork),
            ("refresh: timeout", URLError(.timedOut), nil, .refreshNetwork),
            ("refresh: 503", BCryptoError.httpError(503), nil, .refreshServerError),
            ("refresh: 429", BCryptoRateLimitedError(retryAfterSec: 30), nil, .refreshServerError),
            ("rejected, renew: offline", rejected, URLError(.timedOut), .renewNetwork),
            ("rejected, renew: Keychain locked", rejected, KeyVaultError.deviceLocked, .renewKeychainLocked),
            ("rejected, renew: bad signature", rejected,
             BCryptoDeviceRenewClient.Error.serverRejected(.unauthorized), .renewRejected),
            ("rejected, renew: 503", rejected,
             BCryptoDeviceRenewClient.Error.serverRejected(.httpError(503)), .renewServerError),
        ]
        for (name, refreshError, renewError, reason) in cases {
            let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
            let error = await profileError(refreshError: refreshError, renewError: renewError, store: store)

            XCTAssertFalse(isUnauthorized(error), "\(name): a transient failure must never be .unauthorized")
            guard let recovery = error as? BCryptoSessionRecoveryError else {
                XCTFail("\(name): expected BCryptoSessionRecoveryError, got \(String(describing: error))")
                continue
            }
            XCTAssertEqual(recovery.failure.reason, reason, name)
            XCTAssertFalse(recovery.failure.provesCredentialLoss, name)
            XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"),
                           "\(name): the stored tokens are untouched")
        }
    }

    func test_severalCallersAtColdStartAllGetATransientErrorNotUnauthorized() async {
        // The scenario of the process-wide coordinator: one transient failure, several callers.
        RecoveryStubProtocol.handler = { _ in 401 }
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let client = makeClient(store: store)
        client.setTokenRefresher { _ in
            try await Task.sleep(nanoseconds: 150_000_000)
            throw URLError(.timedOut)
        }

        async let first = thrown { try await client.get("/api/v1/profile") }
        async let second = thrown { try await client.get("/api/v1/settings") }
        async let third = thrown { try await client.get("/api/v1/contacts") }
        let errors = await [first, second, third]

        for error in errors {
            XCTAssertFalse(isUnauthorized(error), "\(String(describing: error))")
            XCTAssertTrue(error is BCryptoSessionRecoveryError, "\(String(describing: error))")
        }
        // A caller arriving later, inside the cooldown, is still transient.
        let later = await thrown { try await client.get("/api/v1/profile") }
        XCTAssertTrue(later is BCryptoSessionRecoveryError, "\(String(describing: later))")
        XCTAssertEqual((later as? BCryptoSessionRecoveryError)?.failure.reason, .cooldown)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"))
    }

    func test_aRecoveryThatWorksButIsRejectedAgainIsNotALossOfCredentials() async {
        RecoveryStubProtocol.handler = { _ in 401 }   // even the fresh token is answered 401
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let client = makeClient(store: store)
        client.setTokenRefresher { _ in AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900) }

        let error = await thrown { try await client.get("/api/v1/profile") }

        XCTAssertFalse(isUnauthorized(error))
        XCTAssertEqual((error as? BCryptoSessionRecoveryError)?.failure.reason, .rejectedAfterRecovery)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"),
                       "the healed pair stays")
    }

    func test_aRecoveryThatWorksStillRetriesAndSucceeds() async {
        RecoveryStubProtocol.handler = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer A1" ? 200 : 401
        }
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let client = makeClient(store: store)
        client.setTokenRefresher { _ in AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900) }

        let error = await thrown { try await client.get("/api/v1/profile") }

        XCTAssertNil(error)
        XCTAssertEqual(client.accessToken, "A1")
    }

    func test_aHungRefreshFreesTheCallerWithATransientTimeoutNotUnauthorized() async {
        RecoveryStubProtocol.handler = { _ in 401 }
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let client = makeClient(store: store, coordinator: AuthRefreshCoordinator(flightDeadlineSec: 0.3))
        client.setTokenRefresher { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }
        let started = Date()

        // Fail fast, not hang, if the flight deadline is ever reverted.
        guard let released = await AuthTestTimeLimit.within(10, {
            await self.thrown { try await client.get("/api/v1/profile") }
        }) else {
            XCTFail("the flight deadline did not release the caller within 10 s")
            return
        }
        let error = released

        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the caller is released at the deadline")
        XCTAssertFalse(isUnauthorized(error))
        XCTAssertEqual((error as? BCryptoSessionRecoveryError)?.failure.reason, .flightTimeout)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"))
    }

    func test_theFileDownloadPathFollowsTheSameRule() async {
        RecoveryStubProtocol.handler = { _ in 401 }
        let transientStore = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let transient = makeClient(store: transientStore)
        transient.setTokenRefresher { _ in throw URLError(.timedOut) }
        let transientError = await thrown { try await transient.getFileEndpoint("/api/v1/files/x") }
        XCTAssertTrue(transientError is BCryptoSessionRecoveryError, "\(String(describing: transientError))")
        XCTAssertFalse(isUnauthorized(transientError))

        let revokedStore = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let revoked = makeClient(store: revokedStore)
        revoked.setTokenRefresher { _ in throw BCryptoError.unauthorized }
        revoked.setDeviceRenewFallback { throw BCryptoDeviceRenewClient.Error.serverRejected(.httpError(403)) }
        let revokedError = await thrown { try await revoked.getFileEndpoint("/api/v1/files/x") }
        XCTAssertTrue(isUnauthorized(revokedError), "\(String(describing: revokedError))")
    }

    // MARK: - definitive loss still says so

    func test_aDefinitiveLossOfCredentialsSurfacesAsUnauthorized() async {
        let rejected: Error = BCryptoError.unauthorized
        let cases: [(String, Error?, Error?)] = [
            ("device revoked (renew 403)", rejected,
             BCryptoDeviceRenewClient.Error.serverRejected(.httpError(403))),
            ("no device id", rejected, AuthRenewPreconditionError.noDeviceId),
            ("device key not provisioned", rejected,
             BCryptoDeviceRenewClient.Error.ed25519PrivateNotProvisioned),
        ]
        for (name, refreshError, renewError) in cases {
            let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
            let error = await profileError(refreshError: refreshError, renewError: renewError, store: store)
            XCTAssertTrue(isUnauthorized(error), "\(name): got \(String(describing: error))")
        }
    }

    func test_aRejectedRefreshTokenWithNoRenewPathIsALossOnlyForAClientWithoutAStore() async {
        // No store: nothing else in the process shares this session, the rejection is the answer.
        let alone = await profileError(refreshError: BCryptoError.unauthorized, renewError: nil, store: nil)
        XCTAssertTrue(isUnauthorized(alone), "\(String(describing: alone))")

        // A store-backed client that merely lacks a renewer may be a half-wired builder: another
        // client of the same store can still heal the session, so this must not wipe it.
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let backed = await profileError(refreshError: BCryptoError.unauthorized, renewError: nil, store: store)
        XCTAssertFalse(isUnauthorized(backed), "\(String(describing: backed))")
        XCTAssertEqual((backed as? BCryptoSessionRecoveryError)?.failure.reason, .refreshRejected)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"))
    }

    func test_aSignedOutStoreIsAnUnauthorizedAnswerWithNoNetworkCall() async {
        RecoveryStubProtocol.handler = { _ in 401 }
        let client = makeClient(store: InMemoryAuthCredentialStore(access: nil, refresh: nil))
        client.setTokenRefresher { _ in
            XCTFail("a signed-out store must never be refreshed")
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: nil)
        }
        let error = await thrown { try await client.get("/api/v1/profile") }
        XCTAssertTrue(isUnauthorized(error), "\(String(describing: error))")
    }

    func test_aClientWithNoRecoveryPathKeepsItsPlain401() async {
        // Login / onboarding: no store, no refresher, no renewer. The 401 is the answer.
        RecoveryStubProtocol.handler = { _ in 401 }
        let client = makeClient(store: nil)
        let error = await thrown { try await client.get("/api/v1/profile") }
        XCTAssertTrue(isUnauthorized(error), "\(String(describing: error))")
    }

    // MARK: - the launch decision

    func test_onlyADefinitiveUnauthorizedForTheLaunchedSessionClearsIt() {
        let transient: [Error] = [
            BCryptoSessionRecoveryError(failure: AuthRecoveryFailure(
                reason: .cooldown, retryAfterSec: 5, underlyingReason: .refreshNetwork)),
            BCryptoSessionRecoveryError.rejectedAfterRecovery,
            BCryptoSessionRecoveryError(failure: AuthRecoveryFailure(reason: .flightTimeout)),
            URLError(.timedOut),
            URLError(.notConnectedToInternet),
            CancellationError(),
            BCryptoError.httpError(503),
            BCryptoError.httpError(429),
            BCryptoError.decodingError,
            BCryptoError.paymentRequired,
            BCryptoRateLimitedError(retryAfterSec: 30),
            KeyVaultError.deviceLocked,
        ]
        for error in transient {
            XCTAssertFalse(AuthSessionLossPolicy.shouldClearSession(
                after: error, requestAccessToken: "A0", storedAccessToken: "A0"), "\(error)")
        }

        let gone = BCryptoError.unauthorized
        XCTAssertTrue(AuthSessionLossPolicy.shouldClearSession(
            after: gone, requestAccessToken: "A0", storedAccessToken: "A0"))
        XCTAssertTrue(AuthSessionLossPolicy.shouldClearSession(
            after: gone, requestAccessToken: "A0", storedAccessToken: nil),
                      "signed out: clearing an empty store is a no-op")
        XCTAssertTrue(AuthSessionLossPolicy.shouldClearSession(
            after: gone, requestAccessToken: "A0", storedAccessToken: ""))
        XCTAssertFalse(AuthSessionLossPolicy.shouldClearSession(
            after: gone, requestAccessToken: "A0", storedAccessToken: "A-of-another-login"),
                       "the store now holds a session that replaced the launched one: never wipe it")
    }

    func test_theLaunchPathWithATransientRefreshFailureKeepsTheTokens() async {
        // Exactly what AppState's launch does: getProfile through a store-backed client whose
        // refresh fails transiently, then asks the policy whether to wipe the session.
        for refreshError in [URLError(.timedOut) as Error,
                             BCryptoError.httpError(502) as Error,
                             BCryptoRateLimitedError(retryAfterSec: 60) as Error] {
            let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
            let error = await profileError(refreshError: refreshError, renewError: nil, store: store)
            let stored: String? = (try? store.load())?.access

            guard let error else {
                XCTFail("the launch request must fail here")
                continue
            }
            XCTAssertFalse(AuthSessionLossPolicy.shouldClearSession(
                after: error, requestAccessToken: "A0", storedAccessToken: stored),
                           "\(error) must not wipe the session")
            XCTAssertEqual(try? store.load(), AuthStoredCredentials(access: "A0", refresh: "R0"))
        }
    }
}

/// Answers every request with the status the test's handler picks (it can read the headers).
private final class RecoveryStubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Int)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = RecoveryStubProtocol.handler, let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: handler(request), httpVersion: "HTTP/1.1",
                                         headerFields: [:]) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

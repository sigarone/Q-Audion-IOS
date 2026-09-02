import XCTest
@testable import QAudionEngine

/// W-AUXPIN (2026-09-01) — pins the contract the App-side
/// `PinnedURLSession.auxiliary(for:)` relies on: the cached session for a
/// pinned config carries the REST client's own `CertPinningDelegate`, one
/// session is shared per host + trust configuration, and the kill switch
/// defaults to the pinned behaviour. See audit memory
/// reference_ios_stability_audit_2026_09_01 (P1 item 6).
///
/// No TLS handshake happens here: the delegate only decodes the pin string
/// into its set at init, and no request is ever sent.
final class PinnedSessionPolicyTests: XCTestCase {

    /// Any syntactically valid base64 works (two 32-byte values).
    private let testPins = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=,//////////////////////////////////////////8="

    // MARK: - Kill switch

    func test_killSwitch_defaultsToPinned() {
        XCTAssertTrue(PinnedSessionPolicy.auxiliaryClientsUsePinnedSession)
    }

    // MARK: - reuseKey

    func test_reuseKey_lowercasesHostAndDropsPathQueryFragment() {
        XCTAssertEqual(PinnedSessionPolicy.reuseKey(for: "https://VOIP.bcrypto.com/api/v1?x=1#f"),
                       "https://voip.bcrypto.com")
        XCTAssertEqual(PinnedSessionPolicy.reuseKey(for: "https://voip.bcrypto.com"),
                       "https://voip.bcrypto.com")
    }

    func test_reuseKey_keepsSchemeAndNonDefaultPort() {
        XCTAssertEqual(PinnedSessionPolicy.reuseKey(for: "http://localhost:8080/x"),
                       "http://localhost:8080")
        XCTAssertNotEqual(PinnedSessionPolicy.reuseKey(for: "https://voip.bcrypto.com"),
                          PinnedSessionPolicy.reuseKey(for: "https://voip.bcrypto.com:8443"))
    }

    func test_reuseKey_omitsSchemeDefaultPort() {
        XCTAssertEqual(PinnedSessionPolicy.reuseKey(for: "https://voip.bcrypto.com:443/api"),
                       "https://voip.bcrypto.com")
        XCTAssertEqual(PinnedSessionPolicy.reuseKey(for: "http://example.test:80"),
                       "http://example.test")
        // Non-default port on the other scheme is NOT a default and is kept.
        XCTAssertEqual(PinnedSessionPolicy.reuseKey(for: "https://example.test:80"),
                       "https://example.test:80")
    }

    func test_reuseKey_nilWithoutHost() {
        XCTAssertNil(PinnedSessionPolicy.reuseKey(for: ""))
        XCTAssertNil(PinnedSessionPolicy.reuseKey(for: "/relative/only"))
    }

    // MARK: - cacheKey

    func test_cacheKey_separatesTrustConfigurationsForSameHost() {
        let pinned = BackendConfig(serverUrl: "https://voip.bcrypto.com", certPinSha256B64: testPins)
        let plain = BackendConfig(serverUrl: "https://voip.bcrypto.com")
        XCTAssertNotEqual(PinnedSessionPolicy.cacheKey(for: pinned),
                          PinnedSessionPolicy.cacheKey(for: plain))
    }

    func test_cacheKey_ignoresPathAndHostCaseForSameTrust() {
        let a = BackendConfig(serverUrl: "https://voip.bcrypto.com", certPinSha256B64: testPins)
        let b = BackendConfig(serverUrl: "https://VOIP.bcrypto.com/api/v1", certPinSha256B64: testPins)
        XCTAssertEqual(PinnedSessionPolicy.cacheKey(for: a), PinnedSessionPolicy.cacheKey(for: b))
    }

    func test_cacheKey_unparseableServerUrlStillDeterministic() {
        let a = BackendConfig(serverUrl: "", certPinSha256B64: testPins)
        let b = BackendConfig(serverUrl: "", certPinSha256B64: testPins)
        XCTAssertEqual(PinnedSessionPolicy.cacheKey(for: a), PinnedSessionPolicy.cacheKey(for: b))
    }

    // MARK: - Cache + delegate (the contract the auxiliary clients rely on)

    func test_cachedSession_forPinnedConfig_carriesCertPinningDelegate() {
        let config = BackendConfig(serverUrl: "https://pinned-a.test.local", certPinSha256B64: testPins)
        let session = PinnedSessionCache.session(for: config)
        XCTAssertTrue(session.delegate is CertPinningDelegate)
        // Same delegate class the REST client itself installs for this config.
        XCTAssertTrue(BCryptoRestClient(config: config).urlSession.delegate is CertPinningDelegate)
    }

    func test_cachedSession_withoutPin_hasNoCustomDelegate() {
        let config = BackendConfig(serverUrl: "https://unpinned-b.test.local")
        XCTAssertNil(PinnedSessionCache.session(for: config).delegate)
    }

    func test_cachedSession_isSharedPerHostAndTrust() {
        let a = BackendConfig(serverUrl: "https://shared-c.test.local", certPinSha256B64: testPins)
        let b = BackendConfig(serverUrl: "https://SHARED-C.test.local/api/v1/telemetry", certPinSha256B64: testPins)
        XCTAssertTrue(PinnedSessionCache.session(for: a) === PinnedSessionCache.session(for: b))
    }

    func test_cachedSession_isDistinctAcrossHostsAndTrust() {
        let pinned = BackendConfig(serverUrl: "https://distinct-d.test.local", certPinSha256B64: testPins)
        let plain = BackendConfig(serverUrl: "https://distinct-d.test.local")
        let other = BackendConfig(serverUrl: "https://distinct-e.test.local", certPinSha256B64: testPins)
        XCTAssertFalse(PinnedSessionCache.session(for: pinned) === PinnedSessionCache.session(for: plain))
        XCTAssertFalse(PinnedSessionCache.session(for: pinned) === PinnedSessionCache.session(for: other))
    }

    func test_cachedSession_isNeverTheSharedSession() {
        let config = BackendConfig(serverUrl: "https://notshared-f.test.local", certPinSha256B64: testPins)
        XCTAssertFalse(PinnedSessionCache.session(for: config) === URLSession.shared)
    }
}

import XCTest
import QAudionEngine
@testable import QAudionApp

/// W-AUXPIN (2026-09-01) — App-side half of the contract pinned by
/// `PinnedSessionPolicyTests` (engine, CI): the auxiliary factory the four
/// bearer-token clients (telemetry, bug reporter, feedback, self-test) now
/// use derives its pin set from the SAME `BackendConfig.pinned(serverUrl:)`
/// the REST client uses, is cached per host, and is never `URLSession.shared`
/// while the kill switch is on. See audit memory
/// reference_ios_stability_audit_2026_09_01 (P1 item 6).
final class PinnedURLSessionAuxiliaryTests: XCTestCase {

    func testAuxiliaryFactoryUsesTheRestClientPinSetForTheVoipHost() throws {
        // The pin string the auxiliary session is built from is exactly the
        // one every BCryptoRestClient in the app is built from.
        let config = BackendConfig.pinned(serverUrl: PinnedServerHost.url)
        XCTAssertEqual(config.certPinSha256B64, PinnedServerHost.certChainPins)
        XCTAssertFalse(config.acceptSelfSignedCerts)

        let session = PinnedURLSession.auxiliary(for: PinnedServerHost.url)
        let delegate = try XCTUnwrap(session.delegate)
        // `CertPinningDelegate` is internal to QAudionEngine, so match its
        // runtime type name rather than casting across the module boundary.
        XCTAssertTrue(String(describing: type(of: delegate)).contains("CertPinningDelegate"))
    }

    func testAuxiliaryFactoryIsCachedPerHost() {
        let a = PinnedURLSession.auxiliary(for: PinnedServerHost.url)
        let b = PinnedURLSession.auxiliary(for: PinnedServerHost.url + "/api/v1")
        XCTAssertTrue(a === b)
    }

    func testAuxiliaryFactoryNeverReturnsSharedSessionWhileEnabled() {
        XCTAssertTrue(PinnedSessionPolicy.auxiliaryClientsUsePinnedSession)
        XCTAssertFalse(PinnedURLSession.auxiliary(for: PinnedServerHost.url) === URLSession.shared)
    }

    func testAuxiliaryFactoryForNonPinnedHostFallsBackToSystemTls() {
        // Same rule as BackendConfig.pinned(): a host that is not the VoIP
        // backend gets no pin — plain system chain validation, no delegate.
        XCTAssertNil(PinnedURLSession.auxiliary(for: "https://example.invalid").delegate)
    }
}

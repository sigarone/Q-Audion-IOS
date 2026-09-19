import XCTest
@testable import QAudionEngine

/// 2026-09-19 — the WebSocket client's handling of a rejected token.
///
/// Live capture: an iPhone whose sockets kept presenting a retired access token was
/// rejected (`bad_token`) about forty times in eight minutes, never ran its silent
/// recovery (the server's `error` frame never reaches the client, only the close does),
/// and every three failures moved the app onto the disaster-recovery node, whose database
/// does not hold this device, so messages and calls stopped arriving.
final class WebSocketAuthRecoveryTests: XCTestCase {

    // MARK: - what counts as an auth rejection

    func test_policyViolationWithAuthFailedReasonIsAnAuthRejection() {
        XCTAssertTrue(BCryptoWebSocketClient.isAuthRejectionClose(
            code: .policyViolation, reason: Data("auth_failed".utf8)))
    }

    func test_otherPolicyViolationReasonsAreNotAuthRejections() {
        // The server closes with policy violation for more than a bad token; a new
        // token fixes none of these.
        for reason in ["auth_timeout", "keys_revoked", "reconnect_rate_limited",
                       "inbound_rate_limit", "stale", ""] {
            XCTAssertFalse(
                BCryptoWebSocketClient.isAuthRejectionClose(
                    code: .policyViolation, reason: Data(reason.utf8)),
                "reason \(reason.debugDescription) must not start a token recovery")
        }
    }

    func test_otherCloseCodesAreNotAuthRejectionsEvenWithTheSameReason() {
        let reason = Data("auth_failed".utf8)
        let codes: [URLSessionWebSocketTask.CloseCode] =
            [.goingAway, .normalClosure, .abnormalClosure, .invalid]
        for code in codes {
            XCTAssertFalse(
                BCryptoWebSocketClient.isAuthRejectionClose(code: code, reason: reason),
                "close code \(code.rawValue) is not the server's auth rejection")
        }
    }

    func test_aPolicyViolationWithNoReasonIsNotAnAuthRejection() {
        XCTAssertFalse(BCryptoWebSocketClient.isAuthRejectionClose(code: .policyViolation, reason: nil))
    }

    // MARK: - failover

    func test_anAnsweredAuthRejectionNeverCountsTowardFailover() {
        XCTAssertFalse(BCryptoWebSocketClient.shouldSignalNodeStalled(
            attempt: 3, threshold: 3, authRejected: true))
        XCTAssertFalse(BCryptoWebSocketClient.shouldSignalNodeStalled(
            attempt: 40, threshold: 3, authRejected: true))
    }

    func test_unansweredFailuresStillTripFailoverAtTheThreshold() {
        XCTAssertFalse(BCryptoWebSocketClient.shouldSignalNodeStalled(
            attempt: 2, threshold: 3, authRejected: false))
        XCTAssertTrue(BCryptoWebSocketClient.shouldSignalNodeStalled(
            attempt: 3, threshold: 3, authRejected: false))
        XCTAssertTrue(BCryptoWebSocketClient.shouldSignalNodeStalled(
            attempt: 4, threshold: 3, authRejected: false))
    }

    // MARK: - which token a connection presents

    func test_aConnectionPrefersTheSharedStoresToken() {
        XCTAssertEqual(
            BCryptoWebSocketClient.tokenForConnect(stored: "stored", configured: "configured"),
            "stored")
    }

    func test_aConnectionFallsBackToItsOwnConfigWhenTheStoreHasNothing() {
        XCTAssertEqual(
            BCryptoWebSocketClient.tokenForConnect(stored: nil, configured: "configured"),
            "configured")
        XCTAssertEqual(
            BCryptoWebSocketClient.tokenForConnect(stored: "", configured: "configured"),
            "configured")
        XCTAssertNil(BCryptoWebSocketClient.tokenForConnect(stored: nil, configured: nil))
    }

    // MARK: - provider wiring

    func test_theProvidersSocketReadsTheStoredTokenAtConnect() {
        let provider = BCryptoBackendProvider(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: "stale", refreshToken: "r-stale"))
        provider.storedTokenPair = { (access: "fresh", refresh: "r-fresh") }

        let ws = provider.getWebSocketClient()

        XCTAssertEqual(ws.latestAccessToken?(), "fresh")
    }

    func test_recoveryAdoptsAStoredPairThatIsNewerThanTheRejectedToken() async {
        let provider = BCryptoBackendProvider(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: "stale", refreshToken: "r-stale"))
        provider.storedTokenPair = { (access: "fresh", refresh: "r-fresh") }
        let ws = provider.getWebSocketClient()

        let recovered = await ws.onAuthFailedRecover?()

        XCTAssertEqual(recovered, true)
        XCTAssertEqual(provider.config.accessToken, "fresh")
        XCTAssertEqual(provider.config.refreshToken, "r-fresh")
    }
}

import XCTest
@testable import QAudionEngine

/// A socket `authenticated` reply can carry a new token pair; the access token the socket
/// presented is retired at that moment, so the pair has to land in the store and in every
/// transport before anything else uses the old one.
final class WebSocketSessionReissueTests: XCTestCase {

    private func makeProvider(access: String = "A0", refresh: String = "R0")
        -> (BCryptoBackendProvider, InMemoryAuthCredentialStore) {
        let provider = BCryptoBackendProvider(config: BackendConfig(
            serverUrl: "https://example.invalid", accessToken: access, refreshToken: refresh))
        let store = InMemoryAuthCredentialStore(access: access, refresh: refresh)
        provider.credentialStore = store
        return (provider, store)
    }

    // MARK: - payload parsing

    func test_aCompletePairIsParsed() {
        let tokens = BCryptoWebSocketClient.reissuedTokens(from: [
            "user_id": "u1", "access_token": "A1", "refresh_token": "R1", "expires_in": 900,
        ])
        XCTAssertEqual(tokens?.accessToken, "A1")
        XCTAssertEqual(tokens?.refreshToken, "R1")
        XCTAssertEqual(tokens?.expiresInSec, 900)
    }

    func test_aReplyWithoutTokensIsNotAReissue() {
        XCTAssertNil(BCryptoWebSocketClient.reissuedTokens(from: ["user_id": "u1", "bin_relay": 1]))
    }

    func test_aHalfFormedPairIsIgnored() {
        let bad: [[String: Any]] = [
            ["access_token": "A1"],
            ["access_token": "A1", "refresh_token": "R1"],
            ["access_token": "A1", "refresh_token": "R1", "expires_in": 0],
            ["access_token": "", "refresh_token": "R1", "expires_in": 900],
            ["access_token": "A1", "refresh_token": "R1", "expires_in": "soon"],
        ]
        for payload in bad {
            XCTAssertNil(BCryptoWebSocketClient.reissuedTokens(from: payload), "\(payload.keys.sorted())")
        }
    }

    func test_theParsedPairNeverPrintsTheTokens() {
        let tokens = BCryptoWebSocketClient.reissuedTokens(from: [
            "access_token": "SECRET-A", "refresh_token": "SECRET-R", "expires_in": 900,
        ])
        XCTAssertFalse(String(describing: tokens as Any).contains("SECRET"))
    }

    // MARK: - adoption

    func test_theReissuedPairLandsInTheStoreAndInTheTransports() {
        let (provider, store) = makeProvider()

        let adopted = provider.adoptReissuedSession(
            AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900), presentedAccess: "A0")

        XCTAssertTrue(adopted)
        let held = try? store.load()
        XCTAssertEqual(held?.access, "A1")
        XCTAssertEqual(held?.refresh, "R1")
        XCTAssertEqual(provider.config.accessToken, "A1")
        XCTAssertEqual(provider.config.refreshToken, "R1")
    }

    func test_aPairIsNotAppliedOverAStoreThatMovedOn() {
        let (provider, store) = makeProvider()
        store.overwrite(access: "A-rest", refresh: "R-rest")

        let adopted = provider.adoptReissuedSession(
            AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900), presentedAccess: "A0")

        XCTAssertFalse(adopted)
        let held = try? store.load()
        XCTAssertEqual(held?.access, "A-rest")
        XCTAssertEqual(held?.refresh, "R-rest")
    }

    func test_aSignedOutStoreIsNeverWrittenInto() {
        let (provider, store) = makeProvider()
        store.overwrite(access: nil, refresh: nil)

        XCTAssertFalse(provider.adoptReissuedSession(
            AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900), presentedAccess: "A0"))
        XCTAssertNil((try? store.load())?.access)
    }

    func test_aPairWithoutARefreshTokenChangesNothing() {
        let (provider, store) = makeProvider()

        XCTAssertFalse(provider.adoptReissuedSession(
            AuthTokenSet(accessToken: "A1", refreshToken: nil, expiresInSec: 900), presentedAccess: "A0"))
        XCTAssertEqual((try? store.load())?.access, "A0")
    }

    func test_theProvidersSocketIsWiredToAdoptTheReissue() {
        let (provider, store) = makeProvider()
        let ws = provider.getWebSocketClient()

        ws.onSessionReissued?(AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900), "A0")

        XCTAssertEqual((try? store.load())?.access, "A1")
        XCTAssertEqual(provider.config.accessToken, "A1")
    }
}

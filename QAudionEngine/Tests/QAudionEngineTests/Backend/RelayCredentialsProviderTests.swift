import XCTest
@testable import QAudionEngine

final class RelayCredentialsProviderTests: XCTestCase {

    // MARK: - Fixtures

    private final class StubCallingApi: CallingApi, @unchecked Sendable {
        var fetchCount = 0
        var nextResponse: [RelayServer]
        var error: Error?

        init(_ servers: [RelayServer]) { self.nextResponse = servers }

        func sendCallOffer(recipientId: String, sdp: String) async throws {}
        func sendCallAnswer(recipientId: String, sdp: String) async throws {}
        func sendIceCandidate(recipientId: String, candidate: String) async throws {}
        func sendHangup(recipientId: String) async throws {}
        func sendOpaqueMessage(recipientId: String, data: Data) async throws {}

        func getRelays() async throws -> [RelayServer] {
            fetchCount += 1
            if let err = error { throw err }
            return nextResponse
        }
    }

    // MARK: - Tests

    func testFirstCallFetches() async throws {
        let api = StubCallingApi([RelayServer(urls: ["turn:relay.example:3478"], ttl: 3600)])
        let p = RelayCredentialsProvider(api: api)
        let bundle = try await p.credentials()
        XCTAssertEqual(api.fetchCount, 1)
        XCTAssertEqual(bundle.servers.count, 1)
        XCTAssertGreaterThan(bundle.expiresAtEpochMs, RelayCredentialsProvider.RelayBundle.nowMs())
    }

    func testCachedBundleReused() async throws {
        let api = StubCallingApi([RelayServer(urls: ["turn:r.example:3478"], ttl: 3600)])
        let p = RelayCredentialsProvider(api: api)
        _ = try await p.credentials()
        _ = try await p.credentials()
        _ = try await p.credentials()
        XCTAssertEqual(api.fetchCount, 1, "subsequent calls should hit the cache")
    }

    func testForceRefreshHitsNetwork() async throws {
        let api = StubCallingApi([RelayServer(urls: ["turn:r.example:3478"], ttl: 3600)])
        let p = RelayCredentialsProvider(api: api)
        _ = try await p.credentials()
        _ = try await p.credentials(forceRefresh: true)
        XCTAssertEqual(api.fetchCount, 2)
    }

    func testInvalidateClearsCache() async throws {
        let api = StubCallingApi([RelayServer(urls: ["turn:r.example:3478"], ttl: 3600)])
        let p = RelayCredentialsProvider(api: api)
        _ = try await p.credentials()
        await p.invalidate()
        _ = try await p.credentials()
        XCTAssertEqual(api.fetchCount, 2)
    }

    func testCurrentOrRefreshReturnsNilOnError() async {
        struct Boom: Error {}
        let api = StubCallingApi([])
        api.error = Boom()
        let p = RelayCredentialsProvider(api: api)
        let bundle = await p.currentOrRefresh()
        XCTAssertNil(bundle)
    }

    func testRelayServerOptionalCredentialsDecode() throws {
        // STUN-only server: no username / credential.
        let json = "{\"urls\":[\"stun:stun.example.com\"]}".data(using: .utf8)!
        let server = try JSONDecoder().decode(RelayServer.self, from: json)
        XCTAssertEqual(server.urls, ["stun:stun.example.com"])
        XCTAssertNil(server.username)
        XCTAssertNil(server.credential)
        XCTAssertEqual(server.ttl, 3600) // default
    }

    func testRelayResponseSnakeCaseDecode() throws {
        let json = """
        {
          "relays": [{"urls": ["turn:r.example:3478"], "username": "u", "credential": "c", "ttl_seconds": 1800}],
          "wss_turn_url": "wss://wss-turn.example",
          "onion_address": "abc.onion"
        }
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(RelayResponse.self, from: json)
        XCTAssertEqual(resp.relays.count, 1)
        XCTAssertEqual(resp.relays[0].ttl, 1800)
        XCTAssertEqual(resp.wssTurnUrl, "wss://wss-turn.example")
        XCTAssertEqual(resp.onionAddress, "abc.onion")
    }
}

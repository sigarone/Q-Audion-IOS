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
        let json = Data("{\"urls\":[\"stun:stun.example.com\"]}".utf8)
        let server = try JSONDecoder().decode(RelayServer.self, from: json)
        XCTAssertEqual(server.urls, ["stun:stun.example.com"])
        XCTAssertNil(server.username)
        XCTAssertNil(server.credential)
        XCTAssertEqual(server.ttl, 3600) // default
    }

    func testRelayResponseSnakeCaseDecode() throws {
        let json = Data("""
        {
          "relays": [{"urls": ["turn:r.example:3478"], "username": "u", "credential": "c", "ttl_seconds": 1800}],
          "wss_turn_url": "wss://wss-turn.example",
          "onion_address": "abc.onion"
        }
        """.utf8)
        let resp = try JSONDecoder().decode(RelayResponse.self, from: json)
        XCTAssertEqual(resp.relays.count, 1)
        XCTAssertEqual(resp.relays[0].ttl, 1800)
        XCTAssertEqual(resp.wssTurnUrl, "wss://wss-turn.example")
        XCTAssertEqual(resp.onionAddress, "abc.onion")
    }

    /// W-RELAYFLEET (2026-08-25) — the deployed `/api/v1/calling/relays`
    /// multi-group shape, spot-checked end to end. Groups 3..n (one per
    /// fresh VPN exit node) differ from groups 1–2 in exactly the ways a
    /// brittle parser would choke on: an EXTRA `node_id` key, `hostname`
    /// carrying the node IP, and `port` serialized as a STRING (the server
    /// builds it via SplitHostPort) where groups 1–2 send a NUMBER. The
    /// parser must tolerate all of it — plus unknown keys anywhere and
    /// url lists of different lengths — decode every group, and leave ICE
    /// to elect by measured RTT.
    func testRelayResponseMultiGroupFleetDecode() throws {
        let json = Data("""
        {
          "relays": [
            {"type": "turn", "hostname": "203.0.113.10", "port": 3478,
             "urls": ["stun:turn.example:3478", "turn:turn.example:3478?transport=udp", "turn:turn.example:3478?transport=tcp", "turns:turn.example:5349"],
             "username": "1756100000:fleet", "password": "p", "credential": "p", "ttl": 3600},
            {"type": "turn", "hostname": "203.0.113.10", "port": 3478,
             "urls": ["stun:203.0.113.10:3478", "turn:203.0.113.10:3478?transport=udp"],
             "username": "1756100000:fleet", "password": "p", "credential": "p", "ttl": 3600},
            {"type": "turn", "node_id": "node-fra-07", "hostname": "198.51.100.23", "port": "3478",
             "urls": ["stun:198.51.100.23:3478", "turn:198.51.100.23:3478?transport=udp"],
             "username": "1756100000:fleet", "password": "p", "credential": "p", "ttl": 3600,
             "some_future_key": {"nested": true}}
          ],
          "wss_turn_url": "wss://wss-turn.example",
          "masque_url": "https://masque.example"
        }
        """.utf8)
        let resp = try JSONDecoder().decode(RelayResponse.self, from: json)
        XCTAssertEqual(resp.relays.count, 3, "every group decodes — string port / node_id / unknown keys must not fail the batch")
        XCTAssertEqual(resp.relays[0].urls.count, 4)
        XCTAssertEqual(resp.relays[2].urls, ["stun:198.51.100.23:3478", "turn:198.51.100.23:3478?transport=udp"])
        XCTAssertEqual(resp.relays[2].username, "1756100000:fleet")
        XCTAssertEqual(resp.relays[2].credential, "p")
        XCTAssertEqual(resp.relays[2].ttl, 3600)
    }
}

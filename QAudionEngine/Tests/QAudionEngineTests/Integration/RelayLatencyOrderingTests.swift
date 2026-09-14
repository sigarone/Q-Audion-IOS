import XCTest
@testable import QAudionEngine

/// W-RELAYGEO (2026-08-26, best-practices audit item 5) — pins the pure
/// (no-networking) halves of relay latency ordering: `RelayOrdering.order`
/// and `RelayLatencyProbe.parseHostPort`. The networked half
/// (`StunClient.measureRttMs` / `RelayLatencyProbe.measureAll`) is not unit
/// tested here — same discipline as `StunClient`'s existing public-IP
/// discovery path, which also has no unit test coverage in this repo (real
/// UDP round trips are exercised live, not in CI).
final class RelayLatencyOrderingTests: XCTestCase {

    private func server(_ url: String) -> RelayServer {
        RelayServer(urls: [url], username: "u", credential: "c", ttl: 3600)
    }

    // MARK: - RelayOrdering.order

    func test_order_emptyRttMap_returnsServersUnchanged() {
        let servers = [server("turn:a:3478"), server("turn:b:3478")]
        let ordered = RelayOrdering.order(servers, rttMsByFirstUrl: [:])
        XCTAssertEqual(ordered, servers)
    }

    func test_order_singleServer_returnsUnchanged() {
        let servers = [server("turn:a:3478")]
        let ordered = RelayOrdering.order(servers, rttMsByFirstUrl: ["turn:a:3478": 50])
        XCTAssertEqual(ordered, servers)
    }

    func test_order_sortsAscendingByMeasuredRtt() {
        let slow = server("turn:slow:3478")
        let fast = server("turn:fast:3478")
        let medium = server("turn:medium:3478")
        let servers = [slow, fast, medium]
        let rtt: [String: Double] = [
            "turn:slow:3478": 300,
            "turn:fast:3478": 20,
            "turn:medium:3478": 120,
        ]
        let ordered = RelayOrdering.order(servers, rttMsByFirstUrl: rtt)
        XCTAssertEqual(ordered, [fast, medium, slow])
    }

    func test_order_unmeasuredServers_goAfterMeasuredButKeepOriginalRelativeOrder() {
        let unmeasuredA = server("turn:unmeasured-a:3478")
        let fast = server("turn:fast:3478")
        let unmeasuredB = server("turn:unmeasured-b:3478")
        let slow = server("turn:slow:3478")
        // Original order deliberately interleaves measured/unmeasured.
        let servers = [unmeasuredA, fast, unmeasuredB, slow]
        let rtt: [String: Double] = [
            "turn:fast:3478": 10,
            "turn:slow:3478": 200,
        ]
        let ordered = RelayOrdering.order(servers, rttMsByFirstUrl: rtt)
        // Measured entries first (ascending RTT), then unmeasured in their
        // ORIGINAL relative order (a before b), never invented.
        XCTAssertEqual(ordered, [fast, slow, unmeasuredA, unmeasuredB])
    }

    func test_order_tiedRtt_keepsOriginalRelativeOrder() {
        let first = server("turn:first:3478")
        let second = server("turn:second:3478")
        let servers = [first, second]
        let rtt: [String: Double] = [
            "turn:first:3478": 100,
            "turn:second:3478": 100,
        ]
        let ordered = RelayOrdering.order(servers, rttMsByFirstUrl: rtt)
        XCTAssertEqual(ordered, [first, second], "a stable sort must not swap equal-RTT entries")
    }

    func test_order_noServerHasAMeasurement_returnsUnchanged() {
        let servers = [server("turn:a:3478"), server("turn:b:3478")]
        // Map is non-empty but keyed to URLs neither server has — every
        // entry falls into "unmeasured", so this is equivalent to the
        // original order.
        let ordered = RelayOrdering.order(servers, rttMsByFirstUrl: ["turn:unrelated:3478": 5])
        XCTAssertEqual(ordered, servers)
    }

    // MARK: - RelayLatencyProbe.parseHostPort

    func test_parseHostPort_turnWithPort() {
        let result = RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:relay.example.com:3478")
        XCTAssertEqual(result?.host, "relay.example.com")
        XCTAssertEqual(result?.port, 3478)
    }

    func test_parseHostPort_stunWithPort() {
        let result = RelayLatencyProbe.parseHostPort(fromRelayUrl: "stun:stun.example.com:19302")
        XCTAssertEqual(result?.host, "stun.example.com")
        XCTAssertEqual(result?.port, 19302)
    }

    func test_parseHostPort_turnWithQueryParams_stripsQuery() {
        let result = RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:relay.example.com:3478?transport=udp")
        XCTAssertEqual(result?.host, "relay.example.com")
        XCTAssertEqual(result?.port, 3478)
    }

    func test_parseHostPort_bareHostNoPort_defaultsTo3478() {
        let result = RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:relay.example.com")
        XCTAssertEqual(result?.host, "relay.example.com")
        XCTAssertEqual(result?.port, 3478)
    }

    func test_parseHostPort_turnsScheme_excludedNotProbeable() {
        // TLS/DTLS-only TURN — a plain UDP STUN probe can't reach it.
        XCTAssertNil(RelayLatencyProbe.parseHostPort(fromRelayUrl: "turns:relay.example.com:5349"))
    }

    func test_parseHostPort_unknownScheme_returnsNil() {
        XCTAssertNil(RelayLatencyProbe.parseHostPort(fromRelayUrl: "https://relay.example.com"))
    }

    func test_parseHostPort_emptyHost_returnsNil() {
        XCTAssertNil(RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:"))
    }

    func test_parseHostPort_ipv4Host() {
        let result = RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:77.42.121.13:3479")
        XCTAssertEqual(result?.host, "77.42.121.13")
        XCTAssertEqual(result?.port, 3479)
    }

    // MARK: - RelayServer.region tolerant decode (W-RELAYGEO plumbing)

    func test_relayServer_decodesRegionField_whenPresent() throws {
        let json = """
        {"urls": ["turn:a:3478"], "ttl": 3600, "region": "eu-west"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RelayServer.self, from: json)
        XCTAssertEqual(decoded.region, "eu-west")
    }

    func test_relayServer_decodesGeoAlias_whenRegionAbsent() throws {
        let json = """
        {"urls": ["turn:a:3478"], "ttl": 3600, "geo": "fi"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RelayServer.self, from: json)
        XCTAssertEqual(decoded.region, "fi")
    }

    func test_relayServer_regionNil_whenAbsent_matchesEveryDeploymentToday() throws {
        let json = """
        {"urls": ["turn:a:3478"], "ttl": 3600}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RelayServer.self, from: json)
        XCTAssertNil(decoded.region)
    }

    // ─── W-STUNDUALSTACK (2026-08-30) ────────────────────────────────────

    func test_parseHostPort_bracketedIPv6LiteralKeepsAddressAndPort() {
        let r = RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:[2a02:2479:c9:b500::1]:3479?transport=udp")
        XCTAssertEqual(r?.host, "2a02:2479:c9:b500::1")
        XCTAssertEqual(r?.port, 3479)
    }

    func test_parseHostPort_bracketedIPv6WithoutPortDefaults() {
        let r = RelayLatencyProbe.parseHostPort(fromRelayUrl: "stun:[2a02:2479:c9:b500::1]")
        XCTAssertEqual(r?.host, "2a02:2479:c9:b500::1")
        XCTAssertEqual(r?.port, 3478)
    }

    func test_parseHostPort_bareIPv6LiteralIsAllAddress() {
        // The pre-fix behaviour split on the first colon and produced the
        // unresolvable host "2a02" with a garbage port parse.
        let r = RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:2a02:2479:c9:b500::1")
        XCTAssertEqual(r?.host, "2a02:2479:c9:b500::1")
        XCTAssertEqual(r?.port, 3478)
    }

    func test_parseHostPort_hostnameAndV4LiteralUnchanged() {
        // Regression guard: everything the server emits today.
        let a = RelayLatencyProbe.parseHostPort(fromRelayUrl: "turn:turn.bcrypto.com:3478?transport=udp")
        XCTAssertEqual(a?.host, "turn.bcrypto.com")
        XCTAssertEqual(a?.port, 3478)
        let b = RelayLatencyProbe.parseHostPort(fromRelayUrl: "stun:77.42.121.13:3479")
        XCTAssertEqual(b?.host, "77.42.121.13")
        XCTAssertEqual(b?.port, 3479)
    }

    func test_isIPLiteral_decidesTheRaceCorrectly() {
        // A literal names its family — no race; a hostname races both.
        XCTAssertTrue(StunClient.isIPLiteral("217.160.65.35"))
        XCTAssertTrue(StunClient.isIPLiteral("2a02:2479:c9:b500::1"))
        XCTAssertFalse(StunClient.isIPLiteral("turn.bcrypto.com"))
        XCTAssertFalse(StunClient.isIPLiteral("999.1.2.3.4"))
    }
}

import XCTest
@testable import QAudionEngine

/// What each mode of Settings > Trasporto really does: the ICE policy, which servers of the pool go to libwebrtc, whether
/// the WSS bridge is in the list, and what a custom TURN server (address, user name and password) does.
///
/// Before `TransportPlan`, `auto` and `p2p` built the same configuration, and so did `turn` and `relay`; these cases fail
/// when two modes become the same again, when p2p lets a TURN server in, or when relay stops being bridge-only.
/// The call controller and the transport check build their lists from this same type; they need a PeerConnection and a
/// network, so nothing here drives them.
final class TransportPlanTests: XCTestCase {

    private typealias Mode = TransportSettingsViewModel.Mode

    private let stunA = "stun:stun-a.example.test:3478"
    private let turnAUdp = "turn:turn-a.example.test:3478?transport=udp"
    private let turnATls = "turns:turn-a.example.test:5349?transport=tcp"
    private let stunB = "stun:stun-b.example.test:3478"
    private let turnB = "turn:turn-b.example.test:3478"
    private let bridgeUrl = "turn:127.0.0.1:50123?transport=udp"
    /// What the user types and the storage keeps: a TURN server with its own user name and password.
    private let customUrl = "turn:custom-user:custom-secret@custom.example.test:3478"
    /// The URL libwebrtc gets for it: no credentials inside.
    private let customIceUrl = "turn:custom.example.test:3478"
    /// A well formed address without credentials: not a custom server.
    private let customNoCredentials = "turn:custom.example.test:3478"

    /// A pool like the one the server sends: a STUN-only entry, a TURN entry with credentials, a mixed entry.
    private var pool: [RelayServer] {
        [
            RelayServer(urls: [stunA]),
            RelayServer(urls: [turnAUdp, turnATls], username: "user-a", credential: "secret-a"),
            RelayServer(urls: [stunB, turnB], username: "user-b", credential: "secret-b")
        ]
    }

    private func plan(_ mode: Mode, custom: String? = nil, bridge: Bool = false) -> TransportPlan {
        TransportPlan.make(mode: mode, customTurnUrl: custom.flatMap { URL(string: $0) }, bridgeAvailable: bridge)
    }

    private func urls(_ plan: TransportPlan, bridge: String? = nil) -> [String] {
        plan.urls(pool: pool, bridgeIceUrl: bridge)
    }

    private func isTurn(_ url: String) -> Bool { url.hasPrefix("turn:") || url.hasPrefix("turns:") }

    // MARK: - auto

    func test_autoIsPolicyAllWithTheWholePoolAndNoBridge() {
        let p = plan(.auto)
        XCTAssertEqual(p.icePolicy, .all)
        XCTAssertEqual(urls(p), [stunA, turnAUdp, turnATls, stunB, turnB], "auto keeps every server of the pool, in order")
        XCTAssertFalse(p.includeBridge)
        XCTAssertEqual(p.route, .serverPool)
    }

    func test_autoPutsTheBridgeFirstWhenOneStarted() {
        let p = plan(.auto, bridge: true)
        XCTAssertEqual(p.icePolicy, .all)
        XCTAssertEqual(urls(p, bridge: bridgeUrl), [bridgeUrl, stunA, turnAUdp, turnATls, stunB, turnB])
        XCTAssertEqual(p.route, .serverPoolWithBridge)
        // The bridge entry authenticates with the credentials of the first TURN entry of the pool.
        let first = p.servers(pool: pool, bridgeIceUrl: bridgeUrl).first
        XCTAssertEqual(first?.urls, [bridgeUrl])
        XCTAssertEqual(first?.username, "user-a")
        XCTAssertEqual(first?.credential, "secret-a")
    }

    func test_aBridgeThatDidNotStartIsNeverInvented() {
        // The plan says "include", but no ICE URL exists: nothing is listed.
        XCTAssertEqual(urls(plan(.auto, bridge: true), bridge: nil), [stunA, turnAUdp, turnATls, stunB, turnB])
        XCTAssertEqual(urls(plan(.relay, bridge: true), bridge: nil), [], "relay with no bridge URL lists nothing, not the pool")
    }

    // MARK: - p2p

    func test_p2pNeverListsATurnTurnsOrBridgeUrl() {
        for bridge in [false, true] {
            for custom in [nil, customUrl] as [String?] {
                let p = plan(.p2p, custom: custom, bridge: bridge)
                let list = urls(p, bridge: bridge ? bridgeUrl : nil)
                XCTAssertFalse(list.contains(where: isTurn), "p2p listed a TURN url: \(list) (bridge \(bridge), custom \(String(describing: custom)))")
                XCTAssertFalse(list.contains(bridgeUrl))
                XCTAssertFalse(list.contains(customIceUrl))
                XCTAssertFalse(p.includeBridge)
                XCTAssertEqual(p.icePolicy, .all)
                XCTAssertEqual(p.bridgeRole, .never)
            }
        }
    }

    func test_p2pKeepsTheStunServersOfThePoolAndDropsTheTurnUrlsOfMixedEntries() {
        let list = urls(plan(.p2p))
        XCTAssertEqual(list, [stunA, stunB], "the STUN url of the mixed entry stays, its TURN url goes")
        XCTAssertEqual(plan(.p2p).route, .directOnly)
    }

    func test_p2pDoesNotWantTheBridgeEvenWhenUdpIsBlocked() {
        XCTAssertFalse(plan(.p2p).wantsBridge(udpReachable: false))
        XCTAssertFalse(plan(.p2p).wantsBridge(udpReachable: true))
    }

    // MARK: - turn

    func test_turnIsPolicyRelayWithOnlyTheTurnServersOfThePoolAndNoBridge() {
        for bridge in [false, true] {
            let p = plan(.turn, bridge: bridge)
            XCTAssertEqual(p.icePolicy, .relay)
            XCTAssertEqual(urls(p, bridge: bridge ? bridgeUrl : nil), [turnAUdp, turnATls, turnB])
            XCTAssertFalse(p.includeBridge)
            XCTAssertFalse(p.wantsBridge(udpReachable: false))
            XCTAssertEqual(p.route, .poolTurn)
        }
    }

    // MARK: - relay

    func test_relayWithTheBridgeUsesOnlyTheBridge() {
        let p = plan(.relay, bridge: true)
        XCTAssertEqual(p.icePolicy, .relay)
        XCTAssertEqual(urls(p, bridge: bridgeUrl), [bridgeUrl], "no pool entry next to the bridge")
        XCTAssertEqual(p.route, .wssBridge)
        XCTAssertTrue(p.includeBridge)
        XCTAssertFalse(p.includePoolTurn)
    }

    func test_relayFallsBackToThePoolTurnServersWhenTheBridgeIsNotAvailable() {
        let p = plan(.relay, bridge: false)
        XCTAssertEqual(p.icePolicy, .relay, "the fallback keeps the relay policy: the call never goes direct")
        XCTAssertEqual(urls(p), [turnAUdp, turnATls, turnB])
        XCTAssertEqual(p.route, .poolTurnFallback)
        XCTAssertFalse(urls(p).contains(where: { $0.hasPrefix("stun") }))
    }

    func test_relayAlwaysWantsTheBridgeAndAutoOnlyWhenUdpLooksBlocked() {
        XCTAssertTrue(plan(.relay).wantsBridge(udpReachable: true))
        XCTAssertTrue(plan(.relay).wantsBridge(udpReachable: false))
        XCTAssertTrue(plan(.auto).wantsBridge(udpReachable: false))
        XCTAssertFalse(plan(.auto).wantsBridge(udpReachable: true))
    }

    // MARK: - the modes are no longer the same configuration

    func test_noTwoModesBuildTheSameConfiguration() {
        let configs: [(Mode, String)] = [
            (.auto, "\(plan(.auto).icePolicy)|\(urls(plan(.auto)))"),
            (.p2p, "\(plan(.p2p).icePolicy)|\(urls(plan(.p2p)))"),
            (.turn, "\(plan(.turn).icePolicy)|\(urls(plan(.turn)))"),
            (.relay, "\(plan(.relay, bridge: true).icePolicy)|\(urls(plan(.relay, bridge: true), bridge: bridgeUrl))")
        ]
        XCTAssertEqual(Set(configs.map { $0.1 }).count, Mode.allCases.count,
                       "two modes produce the same policy and server list: \(configs)")
        XCTAssertEqual(configs.count, Mode.allCases.count, "a mode is missing from this comparison")
    }

    func test_policyOfEveryModeAlone() {
        XCTAssertEqual(TransportPlan.icePolicy(for: .auto), .all)
        XCTAssertEqual(TransportPlan.icePolicy(for: .p2p), .all)
        XCTAssertEqual(TransportPlan.icePolicy(for: .turn), .relay)
        XCTAssertEqual(TransportPlan.icePolicy(for: .relay), .relay)
        for mode in Mode.allCases {
            for custom in [nil, customUrl] as [String?] {
                for bridge in [false, true] {
                    XCTAssertEqual(plan(mode, custom: custom, bridge: bridge).icePolicy, TransportPlan.icePolicy(for: mode),
                                   "the policy of \(mode) must not depend on the address or the bridge")
                }
            }
        }
    }

    // MARK: - custom TURN address

    func test_aCustomServerReplacesThePoolInAutoTurnAndRelay() {
        for mode in [Mode.auto, .turn, .relay] {
            let p = plan(mode, custom: customUrl, bridge: true)
            XCTAssertEqual(urls(p, bridge: bridgeUrl), [customIceUrl], "\(mode): the server is the whole list")
            XCTAssertEqual(p.route, .customServer)
            XCTAssertFalse(p.includeBridge, "\(mode): no bridge next to a custom server")
            XCTAssertFalse(p.wantsBridge(udpReachable: false), "\(mode): the bridge is not even started")
            XCTAssertEqual(p.icePolicy, TransportPlan.icePolicy(for: mode))
            XCTAssertFalse(p.customTurnIgnored)
            // libwebrtc refuses a TURN server without user name and password: the server has the ones the user wrote.
            let entry = p.servers(pool: pool, bridgeIceUrl: bridgeUrl).first
            XCTAssertEqual(entry?.username, "custom-user", "\(mode)")
            XCTAssertEqual(entry?.credential, "custom-secret", "\(mode)")
        }
    }

    func test_theCustomServerNeverReceivesTheCredentialsOfThePool() {
        let poolWithoutCredentials = [
            RelayServer(urls: [stunA]),
            RelayServer(urls: [turnAUdp]),
            RelayServer(urls: [turnB], username: "user-b", credential: "secret-b")
        ]
        let expected = [TransportIceServer(urls: [customIceUrl], username: "custom-user", credential: "custom-secret")]
        for mode in [Mode.auto, .turn, .relay] {
            let p = plan(mode, custom: customUrl, bridge: true)
            // Whatever the pool holds (credentials, none of them, nothing at all) and whether a bridge is up, the list is
            // the one server with its own credentials: the pool is not read.
            XCTAssertEqual(p.servers(pool: pool, bridgeIceUrl: bridgeUrl), expected, "\(mode): pool with credentials")
            XCTAssertEqual(p.servers(pool: poolWithoutCredentials, bridgeIceUrl: nil), expected, "\(mode): pool without")
            XCTAssertEqual(p.servers(pool: [], bridgeIceUrl: nil), expected, "\(mode): no pool at all")
            for entry in p.servers(pool: pool, bridgeIceUrl: bridgeUrl) {
                XCTAssertNotEqual(entry.username, "user-a", "\(mode): the pool user name went to the custom server")
                XCTAssertNotEqual(entry.credential, "secret-a", "\(mode): the pool password went to the custom server")
            }
        }
    }

    func test_anAddressWithoutCredentialsIsNotACustomServerAndNeverReachesTheList() {
        XCTAssertEqual(TransportCustomTurn.parse(customNoCredentials), .missingCredentials)
        for mode in Mode.allCases {
            for bridge in [false, true] {
                let p = plan(mode, custom: customNoCredentials, bridge: bridge)
                XCTAssertNil(p.customTurn, "\(mode)")
                XCTAssertFalse(p.customTurnIgnored, "\(mode): it is not a custom server, in p2p too")
                let list = urls(p, bridge: bridge ? bridgeUrl : nil)
                XCTAssertFalse(list.contains(customIceUrl), "\(mode): a TURN url without credentials went to the list")
                XCTAssertEqual(list, urls(plan(mode, custom: nil, bridge: bridge), bridge: bridge ? bridgeUrl : nil),
                               "\(mode): the plan is the one of no address")
                XCTAssertNotEqual(p.route, .customServer)
            }
        }
    }

    func test_everyTurnEntryTheListHandsOutHasCredentials() {
        // Whatever the mode, a TURN url never reaches libwebrtc without a user name and password.
        for mode in Mode.allCases {
            for custom in [nil, customUrl, customNoCredentials] as [String?] {
                for bridge in [false, true] {
                    let p = plan(mode, custom: custom, bridge: bridge)
                    for entry in p.servers(pool: pool, bridgeIceUrl: bridge ? bridgeUrl : nil)
                    where entry.urls.contains(where: isTurn) {
                        XCTAssertFalse((entry.username ?? "").isEmpty, "\(mode) custom \(String(describing: custom)) bridge \(bridge)")
                        XCTAssertFalse((entry.credential ?? "").isEmpty, "\(mode) custom \(String(describing: custom)) bridge \(bridge)")
                    }
                }
            }
        }
    }

    func test_aCustomServerIsIgnoredInP2PAndSaidSo() {
        let p = plan(.p2p, custom: customUrl)
        XCTAssertNil(p.customTurn)
        XCTAssertTrue(p.customTurnIgnored)
        XCTAssertEqual(urls(p), [stunA, stunB], "p2p keeps the pool STUN servers; the TURN server is not used")
    }

    func test_anAddressThatIsNotATurnAddressCountsAsNoAddress() {
        for bad in ["http://relay.example.test", "stun:host.example.test:3478", "turn://host.example.test:3478", "nonsense",
                    "turn:custom-user:custom-secret@host.example.test:0", customNoCredentials] {
            let p = plan(.relay, custom: bad, bridge: false)
            XCTAssertNil(p.customTurn, bad)
            XCTAssertFalse(p.customTurnIgnored, bad)
            XCTAssertEqual(urls(p), [turnAUdp, turnATls, turnB], "\(bad) must not replace the pool")
        }
    }

    // MARK: - address validation

    func test_validTurnAddresses() {
        let valid: [(String, String)] = [
            ("turn:u:p@hostname:3478", "turn:u:p@hostname:3478"),
            ("turns:u:p@hostname:5349", "turns:u:p@hostname:5349"),
            ("  turn:u:p@host.example.test  ", "turn:u:p@host.example.test"),
            ("TURN:u:p@Host.Example.Test:3478", "turn:u:p@Host.Example.Test:3478"),
            ("turn:u:p@relay-1.example.test:3478?transport=udp", "turn:u:p@relay-1.example.test:3478?transport=udp"),
            ("turn:u:p@203.0.113.7:3478", "turn:u:p@203.0.113.7:3478"),
            ("turn:u:p@host_name.example.test", "turn:u:p@host_name.example.test")
        ]
        for (typed, expected) in valid {
            XCTAssertEqual(TransportPlan.validatedCustomTurnUrl(typed)?.absoluteString, expected, typed)
        }
    }

    func test_invalidTurnAddresses() {
        let invalid = ["", "   ", "hostname", "turn:", "turns:", "turn:?transport=udp", "turn://hostname:3478",
                       "http://hostname:3478", "stun:hostname:3478", "turn:u:p@host name:3478", "turn:u:p@hostname:0",
                       "turn:u:p@hostname:65536", "turn:u:p@hostname:port", "turn:u:p@hostname:3478:1",
                       "turn:u:p@-host.example.test", "turn:u:p@.example.test", "turn:u:p@host/path:3478",
                       // Well formed, but without a user name and password: not usable.
                       "turn:hostname:3478", "turns:hostname:5349", "turn:hostname", "turn:u@hostname:3478",
                       "turn::p@hostname:3478", "turn:u:@hostname:3478", "turn:@hostname:3478"]
        for typed in invalid {
            XCTAssertNil(TransportPlan.validatedCustomTurnUrl(typed), "\"\(typed)\" must not be accepted")
        }
    }

    // MARK: - bridge credentials

    func test_theBridgeUsesTheCredentialsOfTheFirstTurnEntryOnly() {
        let creds = TransportPlan.poolTurnCredentials(in: pool)
        XCTAssertEqual(creds?.username, "user-a")
        XCTAssertEqual(creds?.credential, "secret-a")

        // The first TURN entry has none: the bridge is not started with another entry's credentials.
        let firstWithoutCredentials = [
            RelayServer(urls: [turnAUdp]),
            RelayServer(urls: [turnB], username: "user-b", credential: "secret-b")
        ]
        XCTAssertNil(TransportPlan.poolTurnCredentials(in: firstWithoutCredentials))

        XCTAssertNil(TransportPlan.poolTurnCredentials(in: [RelayServer(urls: [stunA])]), "no TURN entry, no credentials")
    }
}

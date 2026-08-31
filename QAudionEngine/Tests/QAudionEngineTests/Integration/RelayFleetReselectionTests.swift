import XCTest
@testable import QAudionEngine

final class RelayFleetReselectionTests: XCTestCase {

    func testExtractsHostsFromTheUrlShapesTheServerActuallyEmits() {
        let hosts = RelayFleetReselection.relayHosts(from: [
            "stun:turn.bcrypto.com:3478",
            "turn:turn.bcrypto.com:3478?transport=udp",
            "turn:turn.bcrypto.com:3478?transport=tcp",
            "turns:turn.bcrypto.com:5349?transport=tcp",
            "stun:79.16.214.84:3480",
            "turn:79.16.214.84:3480?transport=udp",
        ])
        XCTAssertEqual(hosts, ["turn.bcrypto.com", "79.16.214.84"])
    }

    func testUnbracketsAnIPv6Literal() {
        XCTAssertEqual(
            RelayFleetReselection.relayHosts(from: ["turn:[2a02:2479:c9:b500::1]:3478?transport=udp"]),
            ["2a02:2479:c9:b500::1"]
        )
    }

    func testDropsUrlsWithNoSchemeSeparatorInsteadOfInventingAHost() {
        XCTAssertEqual(RelayFleetReselection.relayHosts(from: ["turn.bcrypto.com", ""]), [])
    }

    func testRestartsWhenTheRelayInUseIsGoneFromTheFreshBundle() {
        XCTAssertTrue(RelayFleetReselection.shouldRestartIce(
            selectedRelayAddress: "79.16.214.84",
            freshRelayHosts: ["217.160.65.35", "77.42.121.13"]
        ))
    }

    func testDoesNotRestartWhenTheRelayInUseIsStillAdvertised() {
        XCTAssertFalse(RelayFleetReselection.shouldRestartIce(
            selectedRelayAddress: "77.42.121.13",
            freshRelayHosts: ["217.160.65.35", "77.42.121.13"]
        ))
    }

    func testDoesNotRestartADirectPairOrAnUnreadableOne() {
        let hosts: Set<String> = ["217.160.65.35"]
        XCTAssertFalse(RelayFleetReselection.shouldRestartIce(selectedRelayAddress: nil, freshRelayHosts: hosts))
        XCTAssertFalse(RelayFleetReselection.shouldRestartIce(selectedRelayAddress: "", freshRelayHosts: hosts))
        XCTAssertFalse(RelayFleetReselection.shouldRestartIce(selectedRelayAddress: "   ", freshRelayHosts: hosts))
    }

    func testRefusesToDecideWhenTheBundleCarriesNoComparableAddress() {
        // Hostname-only bundle, or a bundle we failed to fetch: "absent" would
        // mean "not resolved here", which is not a reason to disturb a call.
        XCTAssertFalse(RelayFleetReselection.shouldRestartIce(
            selectedRelayAddress: "79.16.214.84", freshRelayHosts: ["turn.bcrypto.com"]
        ))
        XCTAssertFalse(RelayFleetReselection.shouldRestartIce(
            selectedRelayAddress: "79.16.214.84", freshRelayHosts: []
        ))
    }
}

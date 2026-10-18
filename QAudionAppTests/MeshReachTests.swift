import XCTest
@testable import QAudionApp
import QAudionEngine

/// `MeshRuntime.reach(toNodeHex:in:)`: whether a contact's node can be reached
/// over the mesh RIGHT NOW, and through whom. Three UI and routing decisions
/// read it (the routing subtitle, the transport chip and
/// `ChatContainer.resolveMeshRoute`), so the rule is pinned over explicit peer
/// lists, without a radio:
///   - direct means a CONNECTED peer with that node id (a merely seen device is
///     not reachable);
///   - otherwise a connected peer that announces the target as its own
///     neighbour is a bridge, the first one in the list (the list is sorted
///     strongest signal first);
///   - one hop only: a stale or two-hop announcement is not evidence.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and
/// in the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class MeshReachTests: XCTestCase {

    private func peer(_ hex: String, connected: Bool = true, relays: [String] = []) -> MeshRuntimePeer {
        MeshRuntimePeer(
            nodeHex: hex, rssi: -60, connected: connected, radiusFraction: 0.5, relayNodeHexes: relays)
    }

    @MainActor
    func test_aConnectedPeerWithThatNodeIDIsDirectlyReachable() {
        let r = MeshRuntime.reach(toNodeHex: "aa", in: [peer("bb"), peer("aa")])
        XCTAssertTrue(r.reachable)
        XCTAssertNil(r.viaBridgeNodeHex, "direct, so no bridge")
    }

    @MainActor
    func test_aDeviceThatIsSeenButNotConnectedIsNotReachable() {
        let r = MeshRuntime.reach(toNodeHex: "aa", in: [peer("aa", connected: false)])
        XCTAssertFalse(r.reachable)
        XCTAssertNil(r.viaBridgeNodeHex)
    }

    @MainActor
    func test_aConnectedPeerThatAnnouncesTheTargetIsABridge() {
        let r = MeshRuntime.reach(toNodeHex: "aa", in: [peer("bb", relays: ["aa"])])
        XCTAssertTrue(r.reachable)
        XCTAssertEqual(r.viaBridgeNodeHex, "bb")
    }

    /// The announcement of a peer that is no longer connected is exactly the
    /// stale evidence the one-hop rule refuses.
    @MainActor
    func test_aPeerThatIsNotConnectedIsNeverABridge() {
        let r = MeshRuntime.reach(toNodeHex: "aa", in: [peer("bb", connected: false, relays: ["aa"])])
        XCTAssertFalse(r.reachable)
        XCTAssertNil(r.viaBridgeNodeHex)
    }

    /// The list is sorted strongest signal first, so the first connected peer
    /// that announces the target is the nearest bridge. Order decides.
    @MainActor
    func test_theNearestBridgeIsTheFirstConnectedOneThatAnnouncesTheTarget() {
        let near = peer("b1", relays: ["aa"])
        let far = peer("b2", relays: ["aa"])
        XCTAssertEqual(MeshRuntime.reach(toNodeHex: "aa", in: [near, far]).viaBridgeNodeHex, "b1")
        XCTAssertEqual(MeshRuntime.reach(toNodeHex: "aa", in: [far, near]).viaBridgeNodeHex, "b2")
    }

    /// A first bridge that is not connected is skipped for the next one that is.
    @MainActor
    func test_aDisconnectedPeerAheadInTheListDoesNotHideARealBridgeBehindIt() {
        let r = MeshRuntime.reach(
            toNodeHex: "aa",
            in: [peer("b1", connected: false, relays: ["aa"]), peer("b2", relays: ["aa"])])
        XCTAssertTrue(r.reachable)
        XCTAssertEqual(r.viaBridgeNodeHex, "b2")
    }

    @MainActor
    func test_aDirectConnectionWinsOverABridgeEvenWhenTheBridgeComesFirst() {
        let r = MeshRuntime.reach(toNodeHex: "aa", in: [peer("bb", relays: ["aa"]), peer("aa")])
        XCTAssertTrue(r.reachable)
        XCTAssertNil(r.viaBridgeNodeHex)
    }

    /// One hop from what is live: "bb" is connected and announces "cc", and
    /// "cc" announces "aa", but "cc" is not connected, so "aa" is two hops away
    /// through a device that is not there.
    @MainActor
    func test_twoHopsAwayIsNotReachable() {
        let r = MeshRuntime.reach(
            toNodeHex: "aa",
            in: [peer("bb", relays: ["cc"]), peer("cc", connected: false, relays: ["aa"])])
        XCTAssertFalse(r.reachable)
        XCTAssertNil(r.viaBridgeNodeHex)
    }

    @MainActor
    func test_nobodyInRangeIsNotReachable() {
        XCTAssertFalse(MeshRuntime.reach(toNodeHex: "aa", in: []).reachable)
        XCTAssertFalse(MeshRuntime.reach(toNodeHex: "aa", in: [peer("bb", relays: ["cc"])]).reachable)
    }
}

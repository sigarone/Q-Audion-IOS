import XCTest
@testable import QAudionEngine

/// docs/mesh/MESH_LINK_SPEC.md section 3.6.1: the collapse of links on which the node id is proved.
final class MeshVerifiedCollapseTests: XCTestCase {

    private let now: Int64 = 1_000_000

    private func link(_ key: String, central: Bool, bound: Int64, verified: Bool = true, node: String = "peer",
                      activity: Int64? = nil, subscribed: Bool = true) -> MeshLinkCandidate {
        MeshLinkCandidate(key: key, central: central, address: "addr-\(key)", subscribed: subscribed,
                          lastActivityMs: activity ?? now - 1_000, boundAtMs: bound, nodeHex: node, verified: verified)
    }

    private func closes(_ local: String, _ peer: String, _ links: [MeshLinkCandidate]) -> [String] {
        MeshNodeLinkPolicy.verifiedDuplicates(localHex: local, peerHex: peer, links: links, nowMs: now)
    }

    func testLowerNodeWithThreeOutgoingVerifiedLinksKeepsTheEarliest() {
        let links = [link("w:3", central: true, bound: 300), link("w:1", central: true, bound: 100),
                     link("w:2", central: true, bound: 200)]
        XCTAssertEqual(closes("aa", "peer", links), ["w:2", "w:3"])
    }

    func testHigherNodeKeepsItsEarliestOutgoingBesideThePreferredIncomingLink() {
        let links = [link("w:1", central: true, bound: 100), link("n:2", central: false, bound: 500)]
        XCTAssertEqual(closes("zz", "peer", links), [])
    }

    func testHigherNodeWithThreeOutgoingAndAnIncomingLowerCentralKeepsItsEarliestOutgoing() {
        let links = [link("w:3", central: true, bound: 300), link("w:1", central: true, bound: 100),
                     link("w:2", central: true, bound: 200), link("n:9", central: false, bound: 900)]
        XCTAssertEqual(closes("zz", "peer", links), ["w:2", "w:3"])
    }

    func testLowerNodeWithThreeOutgoingKeepsOne() {
        let links = [link("w:2", central: true, bound: 200), link("w:1", central: true, bound: 100),
                     link("w:3", central: true, bound: 300)]
        XCTAssertEqual(closes("aa", "peer", links).count, 2)
        XCTAssertFalse(closes("aa", "peer", links).contains("w:1"))
    }

    func testHealthAsymmetryNeverLeavesZeroLinks() {
        // X: lower central, Y: higher central. The lower end sees X unhealthy and Y healthy, the higher end sees X healthy.
        let stale = now - MeshLinkTiming.linkIdleTimeoutMs - 1
        let lowerView = [link("X", central: true, bound: 100, activity: stale), link("Y", central: false, bound: 200)]
        let higherView = [link("X", central: false, bound: 100), link("Y", central: true, bound: 200)]
        let closed = Set(closes("aa", "peer", lowerView)).union(closes("zz", "peer", higherView))
        XCTAssertFalse(Set(["X", "Y"]).isSubset(of: closed))
    }

    func testVerificationAsymmetryNeverLeavesZeroLinks() {
        // The lower end verified both links, the higher end only Y so far.
        let lowerView = [link("X", central: true, bound: 100), link("Y", central: false, bound: 200)]
        let higherView = [link("X", central: false, bound: 100, verified: false), link("Y", central: true, bound: 200)]
        let closed = Set(closes("aa", "peer", lowerView)).union(closes("zz", "peer", higherView))
        XCTAssertFalse(Set(["X", "Y"]).isSubset(of: closed))
    }

    func testRedialAfterAVerifiedCloseHasNoTimeLimitButEndsWithTheLastHealthyLink() {
        var memory = MeshRedialMemory()
        memory.note("addr", node: "peer", nowMs: now, verified: true)
        XCTAssertTrue(memory.blocks("addr", nowMs: now + 10 * MeshLinkTiming.collapseWindowMs, healthy: { _ in true }))
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 10 * MeshLinkTiming.collapseWindowMs, healthy: { _ in false }))
        XCTAssertFalse(memory.blocks("addr", nowMs: now, healthy: { _ in true }))
    }

    func testHigherNodeWithOnlyItsOwnOutgoingVerifiedLinksKeepsTheEarliest() {
        let links = [link("w:2", central: true, bound: 200), link("w:1", central: true, bound: 100)]
        XCTAssertEqual(closes("zz", "peer", links), ["w:2"])
    }

    func testLowerNodeNeverClosesIncomingLinks() {
        let links = [link("n:1", central: false, bound: 100), link("n:2", central: false, bound: 200)]
        XCTAssertEqual(closes("aa", "peer", links), [])
    }

    func testAnUnverifiedLinkIsNeverClosedOrPreferred() {
        let links = [link("w:1", central: true, bound: 100, verified: false), link("w:2", central: true, bound: 200),
                     link("w:3", central: true, bound: 300)]
        XCTAssertEqual(closes("aa", "peer", links), ["w:3"])
        XCTAssertEqual(closes("aa", "peer", [link("w:1", central: true, bound: 100, verified: false)]), [])
        XCTAssertEqual(closes("aa", "peer", [link("w:1", central: true, bound: 100, verified: false),
                                             link("w:2", central: true, bound: 200, verified: false)]), [])
        // With no verified link at all nothing changes, whatever the roles.
        XCTAssertEqual(closes("zz", "peer", [link("w:1", central: true, bound: 100, verified: false),
                                             link("n:2", central: false, bound: 50, verified: false)]), [])
    }

    func testAnIncomingLinkIsNeverReturned() {
        let links = [link("w:1", central: true, bound: 100), link("n:2", central: false, bound: 50),
                     link("n:3", central: false, bound: 60)]
        for local in ["aa", "zz"] {
            XCTAssertTrue(closes(local, "peer", links).allSatisfy { $0.hasPrefix("w:") })
        }
    }

    func testAnUnhealthyVerifiedLinkIsNotPreferred() {
        let stale = link("w:1", central: true, bound: 100, activity: now - MeshLinkTiming.linkIdleTimeoutMs - 1)
        let live = link("w:2", central: true, bound: 200)
        XCTAssertEqual(closes("aa", "peer", [stale, live]), ["w:1"])
        XCTAssertEqual(closes("aa", "peer", [stale]), [])
        let unsubscribed = link("w:3", central: true, bound: 50, subscribed: false)
        XCTAssertEqual(closes("aa", "peer", [unsubscribed, live]), [])
    }

    func testLinksOfAnotherNodeAreLeftAlone() {
        let other = link("w:9", central: true, bound: 10, node: "other")
        let links = [link("w:1", central: true, bound: 100), link("w:2", central: true, bound: 200)]
        XCTAssertEqual(closes("aa", "peer", [other] + links), ["w:2"])
    }

    func testAllowanceExhaustedLeavesTheLinkOpenAndUnused() {
        var guardTable = MeshCollapseGuard()
        for _ in 0..<MeshLinkTiming.collapseMaxPerWindow { XCTAssertTrue(guardTable.allow("w:2", nowMs: now)) }
        let links = [link("w:1", central: true, bound: 100), link("w:2", central: true, bound: 200),
                     link("w:3", central: true, bound: 300)]
        let plan = MeshNodeLinkPolicy.plan(toClose: closes("aa", "peer", links)) { guardTable.allow($0, nowMs: now) }
        XCTAssertEqual(plan.close, ["w:3"])
        XCTAssertEqual(plan.exclude, ["w:2"])
    }

    /// Both ends decide on the same links, each seeing its own side of every link (outgoing for one end is incoming for the
    /// other) with its own bind times. Each closes only its own outgoing links; the pair is never left without a link.
    func testTheTwoEndsNeverCloseAllTheLinksBetweenThePair() {
        // (key, the lower node is central, bind time on the lower node, bind time on the higher node)
        let shapes: [[(String, Bool, Int64, Int64)]] = [
            [("1", true, 100, 130), ("2", true, 200, 120), ("3", false, 300, 110)],
            [("1", false, 100, 130), ("2", false, 200, 120)],
            [("1", true, 100, 100), ("2", true, 100, 100), ("3", false, 100, 100), ("4", false, 100, 100)],
            [("1", true, 100, 100)],
            [("1", false, 100, 100), ("2", false, 50, 400), ("3", true, 70, 10)],
            [("1", true, 500, 10), ("2", true, 600, 20), ("3", false, 10, 900), ("4", false, 20, 800)],
        ]
        for shape in shapes {
            let lowerView = shape.map { link($0.0, central: $0.1, bound: $0.2) }
            let higherView = shape.map { link($0.0, central: !$0.1, bound: $0.3) }
            let lowerCloses = Set(closes("aa", "peer", lowerView))
            let higherCloses = Set(closes("zz", "peer", higherView))
            let all = Set(shape.map { $0.0 })
            XCTAssertFalse(all.isSubset(of: lowerCloses.union(higherCloses)), "every link closed in \(shape)")
            XCTAssertTrue(lowerCloses.isDisjoint(with: higherCloses), "one link closed by both ends in \(shape)")
        }
    }
}

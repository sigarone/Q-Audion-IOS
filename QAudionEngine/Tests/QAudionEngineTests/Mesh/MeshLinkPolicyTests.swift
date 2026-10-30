import CryptoKit
import XCTest
@testable import QAudionEngine

/// docs/mesh/MESH_LINK_SPEC.md sections 3.6, 8.4 and 13: links that claim one node, the paced ANNOUNCE, the `ann.sum` line
/// and the `tx.frame.fail` rate limit.
final class MeshLinkPolicyTests: XCTestCase {

    private let now: Int64 = 1_000_000

    private func link(_ key: String, central: Bool, created: Int64, activity: Int64? = nil, subscribed: Bool = true,
                      address: String? = nil) -> MeshLinkCandidate {
        MeshLinkCandidate(key: key, central: central, address: address ?? "addr-\(key)", subscribed: subscribed,
                          lastActivityMs: activity ?? created, boundAtMs: created)
    }

    private func close(_ local: String, _ peer: String, _ links: [MeshLinkCandidate]) -> Set<String> {
        Set(MeshNodeLinkPolicy.sameDeviceDuplicates(localHex: local, peerHex: peer, links: links))
    }

    // MARK: - Links that claim one node

    func testASingleLinkOrNoneIsNeverClosed() {
        XCTAssertEqual(close("aa", "bb", []), [])
        XCTAssertEqual(close("aa", "bb", [link("w:1", central: true, created: 1)]), [])
    }

    func testAnHonestSameAddressDuplicateIsCollapsedTheSameOneAtBothEnds() {
        // aa < bb. The link in the role where aa is central stays.
        let onA = [link("w:1", central: true, created: 10, address: "X"), link("n:2", central: false, created: 20, address: "X")]
        XCTAssertEqual(close("aa", "bb", onA), ["n:2"])
        let onB = [link("w:1", central: true, created: 10, address: "Y"), link("n:2", central: false, created: 20, address: "Y")]
        XCTAssertEqual(close("bb", "aa", onB), ["w:1"])
    }

    func testClaimantsWithDifferentAddressesAreNeverClosed() {
        let real = link("n:1", central: false, created: now - 60_000, activity: now - 1_000)
        let firstClaimant = link("w:2", central: true, created: now - 90_000, activity: now - 100)
        XCTAssertEqual(close("aa", "bb", [real, firstClaimant]), [])
        XCTAssertEqual(close("cc", "bb", [real, firstClaimant]), [])
        let rotated = (1...10).map { link("n:\($0)", central: false, created: now - 100_000 + Int64($0) * 5_000) }
        XCTAssertEqual(close("cc", "bb", rotated), [])
        XCTAssertEqual(close("aa", "bb", rotated + [link("w:x", central: true, created: 5)]), [])
    }

    func testAnUnsubscribedDuplicateIsNotConsidered() {
        let a = link("w:1", central: true, created: 10, address: "X")
        let b = link("n:2", central: false, created: 20, subscribed: false, address: "X")
        XCTAssertEqual(close("aa", "bb", [a, b]), [])
    }

    func testAClaimantThatBindsFirstCannotStopFramesReachingTheRealNodesLink() {
        let firstClaimant = link("n:1", central: false, created: now - 90_000, activity: now - 100)
        let real = link("w:2", central: true, created: now - 5_000, activity: now - 500)
        let targets = MeshNodeLinkPolicy.directTargets(links: [firstClaimant, real], nowMs: now)
        XCTAssertTrue(targets.contains("w:2"))
        XCTAssertTrue(targets.contains("n:1"))
        // Nothing is closed or excluded because of the claim.
        XCTAssertEqual(close("aa", "bb", [firstClaimant, real]), [])
    }

    func testOnlyHealthyLinksAreFrameTargets() {
        let idle = link("n:1", central: false, created: 10, activity: now - MeshLinkTiming.linkIdleTimeoutMs - 1)
        let unsubscribed = link("n:2", central: false, created: 10, activity: now, subscribed: false)
        let healthy = link("w:3", central: true, created: 10, activity: now - 1_000)
        XCTAssertEqual(MeshNodeLinkPolicy.directTargets(links: [idle, unsubscribed, healthy], nowMs: now), ["w:3"])
    }

    func testALinkBoundToANodeCannotRebindToAnotherOne() {
        XCTAssertTrue(MeshNodeLinkPolicy.mayBind(boundTo: nil, announced: "aa"))
        XCTAssertTrue(MeshNodeLinkPolicy.mayBind(boundTo: "aa", announced: "aa"))
        XCTAssertFalse(MeshNodeLinkPolicy.mayBind(boundTo: "aa", announced: "bb"))
    }

    func testALinkTheGuardRefusesToCloseIsExcludedNotKeptAsARoute() {
        let refused = MeshNodeLinkPolicy.plan(toClose: ["n:2"]) { _ in false }
        XCTAssertEqual(refused.close, [])
        XCTAssertEqual(refused.exclude, ["n:2"])
        let allowed = MeshNodeLinkPolicy.plan(toClose: ["n:2"]) { _ in true }
        XCTAssertEqual(allowed.close, ["n:2"])
        XCTAssertEqual(allowed.exclude, [])
    }

    func testWhenTheKeeperGoesTheSurvivorIsNoLongerADuplicateAndRoutableAtOnce() {
        let a = link("w:1", central: true, created: 10, address: "X")
        let b = link("n:2", central: false, created: 20, activity: now, address: "X")
        XCTAssertEqual(close("aa", "bb", [a, b]), ["n:2"])
        // The keeper is torn down: the decision runs again for the node with what is left.
        XCTAssertEqual(close("aa", "bb", [b]), [])
        XCTAssertEqual(MeshNodeLinkPolicy.directTargets(links: [b], nowMs: now), ["n:2"])
    }

    func testTheRedialMemoryBacksOffWhileAHealthyLinkExistsAndResetsWhenNoneDoes() {
        var memory = MeshRedialMemory()
        memory.note("addr", node: "node", nowMs: now)
        XCTAssertTrue(memory.blocks("addr", nowMs: now + 29_999, healthy: { _ in true }))
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 30_000, healthy: { _ in true }))
        memory.note("addr", node: "node", nowMs: now + 31_000)
        XCTAssertTrue(memory.blocks("addr", nowMs: now + 31_000 + 59_999, healthy: { _ in true }))
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 31_000 + 60_000, healthy: { _ in true }))
        memory.note("addr", node: "node", nowMs: now + 100_000)
        memory.note("addr", node: "node", nowMs: now + 200_000)
        memory.note("addr", node: "node", nowMs: now + 300_000)
        XCTAssertTrue(memory.blocks("addr", nowMs: now + 300_000 + 299_999, healthy: { _ in true }))
        // No healthy link to the node any more: forgotten, dialled like any other address.
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 300_001, healthy: { _ in false }))
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 300_002, healthy: { _ in true }))
        XCTAssertFalse(memory.blocks("other", nowMs: now, healthy: { _ in true }))
    }

    func testADialIsSkippedOnlyForTheIdentifierOfAHealthyLinkNeverForTheSameNodeElsewhere() {
        let healthy: Set<String> = ["AA-01"]
        XCTAssertTrue(MeshNodeLinkPolicy.dialBlockedByLink(target: "AA-01", healthyLinkIdentifiers: healthy))
        XCTAssertFalse(MeshNodeLinkPolicy.dialBlockedByLink(target: "BB-02", healthyLinkIdentifiers: healthy))
        XCTAssertFalse(MeshNodeLinkPolicy.dialBlockedByLink(target: "AA-01", healthyLinkIdentifiers: []))
    }

    func testARefusalLastsUntilItExpiresAndNothingElseClearsIt() {
        var table = MeshRefusalTable()
        table.refuse("central", untilMs: now + 30_000)
        XCTAssertTrue(table.isRefused("central", nowMs: now + 1))
        table.prune(nowMs: now + 10_000)
        XCTAssertTrue(table.isRefused("central", nowMs: now + 10_001))
        XCTAssertFalse(table.isRefused("other", nowMs: now))
        XCTAssertFalse(table.isRefused("central", nowMs: now + 30_000))
    }

    func testTheGuardBudgetIsPerLinkKeySoOneCannotUseUpAnothers() {
        var guardTable = MeshCollapseGuard()
        for i in 0..<MeshLinkTiming.collapseMaxPerWindow {
            XCTAssertTrue(guardTable.allow("n:addr1", nowMs: now + Int64(i)))
        }
        XCTAssertFalse(guardTable.allow("n:addr1", nowMs: now + 100))
        XCTAssertTrue(guardTable.allow("n:addr2", nowMs: now + 100))
        XCTAssertTrue(guardTable.allow("n:addr1", nowMs: now + MeshLinkTiming.collapseWindowMs + 10))
    }

    func testTheTablesAreCappedAndDropTheOldestEntry() {
        var guardTable = MeshCollapseGuard()
        for i in 0..<200 { XCTAssertTrue(guardTable.allow("k\(i)", nowMs: now + Int64(i))) }
        for i in 0..<MeshLinkTiming.collapseMaxPerWindow {
            XCTAssertTrue(guardTable.allow("k0", nowMs: now + 1_000 + Int64(i)))
        }
        var memory = MeshRedialMemory()
        for i in 0..<200 { memory.note("a\(i)", node: "n", nowMs: now + Int64(i)) }
        XCTAssertNil(memory.node(of: "a0"))
        XCTAssertEqual(memory.node(of: "a199"), "n")
        let box = Box()
        MeshLog.install(sink: { level, _, message in box.got.append((level, message)) })
        defer { MeshLog.install(sink: nil) }
        var throttle = MeshTxFailThrottle(windowMs: 60_000)
        for i in 0..<600 {
            throttle.warn(link: "c\(i)", ph: "aa", idx: 0, total: 1, reason: "timeout", nowMs: Int64(i))
        }
        throttle.warn(link: "c0", ph: "bb", idx: 0, total: 1, reason: "timeout", nowMs: 601)
        XCTAssertEqual(box.got.count, 601)
    }

    // MARK: - Fan-out cap and eviction

    private func data(_ key: String, bound: Int64, lastData: Int64, node: String? = "N", activity: Int64? = nil) -> MeshLinkCandidate {
        MeshLinkCandidate(key: key, central: false, address: "addr-\(key)", subscribed: true, lastActivityMs: activity ?? now - 1_000,
                          boundAtMs: bound, lastDataMs: lastData, nodeHex: node)
    }

    func testASendGoesToEveryHealthyLinkOfANodeUpToFourAndRanksOnlyAboveFour() {
        let links = [
            data("a", bound: 100, lastData: 0),
            data("b", bound: 200, lastData: now - 5_000),
            data("c", bound: 300, lastData: now - 1_000),
            data("d", bound: 50, lastData: now - 9_000),
        ]
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: links, nowMs: now), ["d", "a", "b", "c"])
        // Idle links never count.
        let idle = data("i", bound: 1, lastData: now - 1, activity: now - MeshLinkTiming.linkIdleTimeoutMs - 1)
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: links + [idle], nowMs: now), ["d", "a", "b", "c"])
        // Above four: the earliest bound first, then the most recent validated data.
        let flooders = (1...10).map { data("f\($0)", bound: 1_000 + Int64($0), lastData: now - Int64($0)) }
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [data("orig", bound: 10, lastData: 0)] + flooders, nowMs: now),
                       ["orig", "f1", "f2", "f3"])
    }

    func testClaimantsCannotPushTheRealNodeOutUnlessMoreThanFourAddressesClaimIt() {
        let real = data("real", bound: 500, lastData: now - 20_000)
        let four = [real] + (1...3).map { data("c\($0)", bound: 100 * Int64($0), lastData: 0) }
        XCTAssertTrue(MeshNodeLinkPolicy.fanOut(links: four, nowMs: now).contains("real"))
        // Junk keeps lastDataMs at 0, so the link with real data stays in once there are more than four.
        let six = four + (4...5).map { data("c\($0)", bound: 100 * Int64($0), lastData: 0) }
        let out = MeshNodeLinkPolicy.fanOut(links: six, nowMs: now)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out.first, "c1")
        XCTAssertTrue(out.contains("real"))
    }

    func testAFloodSkipsAllLinksOfTheNodeThePacketCameFromAndCapsEachOtherNode() {
        let links = [
            data("s1", bound: 100, lastData: now - 1_000, node: "SRC"),
            data("s2", bound: 110, lastData: now - 2_000, node: "SRC"),
            data("p1", bound: 100, lastData: now - 1_000, node: "P"),
            data("p2", bound: 110, lastData: now - 2_000, node: "P"),
            data("p3", bound: 120, lastData: now - 3_000, node: "P"),
            data("u1", bound: 100, lastData: 0, node: nil),
        ]
        XCTAssertEqual(MeshNodeLinkPolicy.floodTargets(links: links, excludingKey: "s1", excludingNode: "SRC", nowMs: now),
                       ["u1", "p1", "p2", "p3"])
        // Without an arrival node only the arrival link is left out.
        XCTAssertTrue(MeshNodeLinkPolicy.floodTargets(links: links, excludingKey: "s1", excludingNode: nil, nowMs: now).contains("s2"))
        let many = (1...7).map { data("m\($0)", bound: 100 + Int64($0), lastData: now - Int64($0), node: "M") }
        XCTAssertEqual(MeshNodeLinkPolicy.floodTargets(links: many, excludingKey: nil, excludingNode: nil, nowMs: now).count, 4)
    }

    func testARelayedPacketForADirectlyLinkedRecipientUsesTheRecipientsOwnLinks() {
        let links = [
            data("s1", bound: 100, lastData: now - 1_000, node: "SRC"),
            data("r1", bound: 100, lastData: now - 1_000, node: "REC"),
            data("r2", bound: 110, lastData: now - 2_000, node: "REC"),
            data("r3", bound: 120, lastData: now - 3_000, node: "REC"),
            data("o1", bound: 100, lastData: now - 1_000, node: "OTHER"),
        ]
        XCTAssertEqual(MeshNodeLinkPolicy.relayTargets(links: links, recipientNode: "REC", arrivalKey: "s1", arrivalNode: "SRC", nowMs: now),
                       ["r1", "r2", "r3"])
        // A recipient that is not linked is flooded to everyone but the source.
        XCTAssertEqual(MeshNodeLinkPolicy.relayTargets(links: links, recipientNode: "GONE", arrivalKey: "s1", arrivalNode: "SRC", nowMs: now),
                       ["o1", "r1", "r2", "r3"])
        // A recipient that is the node the packet came from is not sent back to it.
        XCTAssertEqual(MeshNodeLinkPolicy.relayTargets(links: links, recipientNode: "SRC", arrivalKey: "s1", arrivalNode: "SRC", nowMs: now),
                       ["o1", "r1", "r2", "r3"])
    }

    private func slot(_ key: String, central: Bool, bound: Int64, lastData: Int64, node: String?, subscribed: Bool = true,
                      activity: Int64? = nil) -> MeshLinkCandidate {
        MeshLinkCandidate(key: key, central: central, address: "addr-\(key)", subscribed: subscribed, lastActivityMs: activity ?? now - 1_000,
                          boundAtMs: bound, lastDataMs: lastData, nodeHex: node)
    }

    func testTheLongestIdleLinkIsEvictedFirstIdleSinceTheLaterOfItsLastDataAndItsBind() {
        let links = [
            slot("w:old-quiet", central: true, bound: now - 300_000, lastData: 0, node: "A"),
            slot("w:old-spent", central: true, bound: now - 400_000, lastData: now - 250_000, node: "B"),
            slot("w:busy", central: true, bound: now - 400_000, lastData: now - 1_000, node: "C"),
            slot("w:young-quiet", central: true, bound: now - 10_000, lastData: 0, node: "D"),
            slot("w:mid-quiet", central: true, bound: now - 100_000, lastData: 0, node: "E"),
            slot("n:other", central: false, bound: now - 500_000, lastData: 0, node: "F"),
            // Earlier-bound healthy links of nodes A, B and E keep the later ones from being the earliest of their node.
            slot("n:s-a", central: false, bound: now - 600_000, lastData: now - 1_000, node: "A"),
            slot("n:s-b", central: false, bound: now - 600_000, lastData: now - 1_000, node: "B"),
            slot("n:s-e", central: false, bound: now - 600_000, lastData: now - 1_000, node: "E"),
        ]
        XCTAssertEqual(MeshNodeLinkPolicy.evictionVictim(links: links, centralRole: true, excludingKey: "w:newcomer", nowMs: now), "w:old-quiet")
        XCTAssertEqual(MeshNodeLinkPolicy.evictionVictim(links: links.filter { $0.key != "w:old-quiet" }, centralRole: true,
                                                         excludingKey: "w:newcomer", nowMs: now), "w:old-spent")
        // A link that sent a single DATA packet is not squatting for good: it is evictable once it has been idle long enough.
        let squatter = slot("w:squat", central: true, bound: now - 500_000, lastData: now - 100_000, node: "G")
        let sibling = slot("n:sib", central: false, bound: now - 600_000, lastData: now - 1_000, node: "G")
        XCTAssertEqual(MeshNodeLinkPolicy.evictionVictim(links: [squatter, sibling], centralRole: true, excludingKey: nil, nowMs: now), "w:squat")
        // Busy, or too young, nothing to evict.
        let none = links.filter { $0.key == "w:busy" || $0.key == "w:young-quiet" }
        XCTAssertNil(MeshNodeLinkPolicy.evictionVictim(links: none, centralRole: true, excludingKey: nil, nowMs: now))
    }

    func testTheEarliestBoundHealthyLinkOfANodeIsProtected() {
        let only = slot("w:only", central: true, bound: now - 300_000, lastData: 0, node: "A")
        XCTAssertNil(MeshNodeLinkPolicy.evictionVictim(links: [only], centralRole: true, excludingKey: nil, nowMs: now))
        let later = slot("w:later", central: true, bound: now - 200_000, lastData: 0, node: "A")
        XCTAssertEqual(MeshNodeLinkPolicy.evictionVictim(links: [only, later], centralRole: true, excludingKey: nil, nowMs: now), "w:later")
        let idleEarlier = slot("w:idle", central: true, bound: now - 400_000, lastData: 0, node: "A",
                               activity: now - MeshLinkTiming.linkIdleTimeoutMs - 1)
        XCTAssertNil(MeshNodeLinkPolicy.evictionVictim(links: [only, idleEarlier], centralRole: true, excludingKey: "w:idle", nowMs: now))
    }

    func testANewcomerClaimingNodeXCannotMakeTheExistingLinkOfXEvictable() {
        let existing = slot("w:existing", central: true, bound: now - 300_000, lastData: 0, node: "X")
        let later = slot("w:later", central: true, bound: now - 200_000, lastData: 0, node: "X")
        let newcomer = slot("w:new", central: true, bound: now - 1_000, lastData: 0, node: "X")
        XCTAssertNil(MeshNodeLinkPolicy.evictionVictim(links: [existing, later, newcomer], centralRole: true, excludingKey: "w:new", nowMs: now))
        let other = slot("w:other", central: true, bound: now - 1_000, lastData: 0, node: "Y")
        XCTAssertEqual(MeshNodeLinkPolicy.evictionVictim(links: [existing, later, other], centralRole: true, excludingKey: "w:other", nowMs: now), "w:later")
    }

    func testALinkThatSubscribedAndDidNotAnnounceWithinThirtyFiveSecondsExpires() {
        XCTAssertFalse(MeshNodeLinkPolicy.unboundExpired(subscribedAtMs: now - 34_999, nodeHex: nil, nowMs: now))
        XCTAssertTrue(MeshNodeLinkPolicy.unboundExpired(subscribedAtMs: now - 35_001, nodeHex: nil, nowMs: now))
        XCTAssertFalse(MeshNodeLinkPolicy.unboundExpired(subscribedAtMs: now - 60_000, nodeHex: "A", nowMs: now))
        XCTAssertFalse(MeshNodeLinkPolicy.unboundExpired(subscribedAtMs: 0, nodeHex: nil, nowMs: now))
    }

    func testAnEvictedAddressIsNotDialledAgainInsideItsWindowAndTheWaitGrows() {
        var memory = MeshEvictionMemory()
        memory.note("addr", nowMs: now)
        XCTAssertTrue(memory.blocks("addr", nowMs: now + 29_999))
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 30_000))
        memory.note("addr", nowMs: now + 31_000)
        XCTAssertTrue(memory.blocks("addr", nowMs: now + 31_000 + 59_999))
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 31_000 + 60_000))
        XCTAssertFalse(memory.blocks("other", nowMs: now))
        // After a quiet quarter of an hour the wait starts over.
        memory.note("addr", nowMs: now + 2_000_000)
        XCTAssertFalse(memory.blocks("addr", nowMs: now + 2_000_000 + 30_000))
    }

    /// A deterministic walk of the dial, bind and make-room cycle with seven honest neighbours and six slots.
    private struct Mesh {
        let cap: Int
        let remember: Bool
        var memory = MeshEvictionMemory()
        var limiter = MeshEvictionLimiter()
        var links: [String: MeshLinkCandidate] = [:]
        var dials: [String: [Int64]] = [:]
        var evictions: [(address: String, at: Int64)] = []

        mutating func tick(_ addresses: [String], at now: Int64) {
            for a in addresses {
                if links[a] != nil || (remember && memory.blocks(a, nowMs: now)) { continue }
                if links.count >= cap + 1 { continue }
                dials[a, default: []].append(now)
                links[a] = MeshLinkCandidate(key: "w:\(a)", central: true, address: a, subscribed: true, lastActivityMs: now,
                                             boundAtMs: now, lastDataMs: 0, nodeHex: "node-\(a)")
                if links.count > cap { makeRoom(newcomer: a, at: now) }
            }
        }

        private mutating func makeRoom(newcomer: String, at now: Int64) {
            var victim = MeshNodeLinkPolicy.evictionVictim(links: Array(links.values), centralRole: true, excludingKey: "w:\(newcomer)", nowMs: now)
            if victim != nil, !limiter.allow(centralRole: true, nowMs: now) { victim = nil }
            let target = victim.map { String($0.dropFirst(2)) } ?? newcomer
            links.removeValue(forKey: target)
            evictions.append((target, now))
            if remember { memory.note(target, nowMs: now) }
        }
    }

    func testSevenNeighboursAndSixSlotsSettleInsteadOfCycling() {
        let addresses = (1...7).map { "a\($0)" }
        func run(remember: Bool) -> Mesh {
            var mesh = Mesh(cap: 6, remember: remember)
            var t = now
            while t < now + 600_000 {
                // The links stay alive: they all announce, none carries data.
                for key in mesh.links.keys {
                    if let l = mesh.links[key] {
                        mesh.links[key] = MeshLinkCandidate(key: l.key, central: l.central, address: l.address, subscribed: true,
                                                            lastActivityMs: t, boundAtMs: l.boundAtMs, lastDataMs: l.lastDataMs, nodeHex: l.nodeHex)
                    }
                }
                mesh.tick(addresses, at: t)
                t += 3_000
            }
            return mesh
        }
        let without = run(remember: false)
        let with = run(remember: true)
        let dialsWithout = without.dials.values.map { $0.count }.reduce(0, +)
        let dialsWith = with.dials.values.map { $0.count }.reduce(0, +)
        // Without the memory the seventh is redialled every tick: hundreds of dials. With it, a handful.
        XCTAssertGreaterThan(dialsWithout, 100)
        XCTAssertLessThan(dialsWith, 50)
        // No evicted address is dialled again inside the first wait.
        for eviction in with.evictions {
            let again = (with.dials[eviction.address] ?? []).filter { $0 > eviction.at && $0 < eviction.at + 30_000 }
            XCTAssertTrue(again.isEmpty, "\(eviction.address) redialled at \(again)")
        }
        XCTAssertLessThanOrEqual(with.links.count, 6)
    }

    func testANewcomerThatIsNotBoundAndSubscribedCannotMakeAnEviction() {
        XCTAssertFalse(MeshNodeLinkPolicy.canTriggerEviction(newcomer: slot("n:x", central: false, bound: now, lastData: 0, node: nil)))
        XCTAssertFalse(MeshNodeLinkPolicy.canTriggerEviction(newcomer: slot("n:x", central: false, bound: now, lastData: 0, node: "A", subscribed: false)))
        XCTAssertTrue(MeshNodeLinkPolicy.canTriggerEviction(newcomer: slot("n:x", central: false, bound: now, lastData: 0, node: "A")))
    }

    func testABurstOfNewcomersCannotEvictMoreThanOneLinkPerRolePerWindow() {
        var limiter = MeshEvictionLimiter()
        var evicted = 0
        for i in 0..<20 where limiter.allow(centralRole: true, nowMs: now + Int64(i) * 100) { evicted += 1 }
        XCTAssertEqual(evicted, 1)
        XCTAssertTrue(limiter.allow(centralRole: false, nowMs: now))
        XCTAssertTrue(limiter.allow(centralRole: true, nowMs: now + MeshLinkTiming.evictWindowMs))
    }

    // MARK: - Paced ANNOUNCE

    func testThePacerPicksTheMostOverdueLinkOneAtATime() {
        let t: Int64 = 100_000
        let last: [String: Int64] = ["a": t - 20_000, "b": t - 16_000, "c": t - 15_000, "d": t - 3_000]
        XCTAssertEqual(MeshAnnouncePacer.next(lastSentMs: last, nowMs: t), "a")
        var rest = last
        rest.removeValue(forKey: "a")
        XCTAssertEqual(MeshAnnouncePacer.next(lastSentMs: rest, nowMs: t + 1_000), "b")
        XCTAssertNil(MeshAnnouncePacer.next(lastSentMs: ["d": t - 3_000], nowMs: t))
        XCTAssertNil(MeshAnnouncePacer.next(lastSentMs: [:], nowMs: t))
    }

    func testFourteenLinksDueTogetherAreSpreadAndKeepTheirPeriod() {
        var last: [String: Int64] = [:]
        for i in 0..<14 { last["l\(i)"] = 0 }
        var sentAt: [String: [Int64]] = [:]
        var t = MeshLinkTiming.announceIntervalMs
        let end = 4 * MeshLinkTiming.announceIntervalMs
        while t <= end {
            if let key = MeshAnnouncePacer.next(lastSentMs: last, nowMs: t) {
                last[key] = t
                sentAt[key, default: []].append(t)
            }
            t += MeshLinkTiming.announceTickMs
        }
        let firstWave = sentAt.values.compactMap { $0.first }.sorted()
        XCTAssertEqual(firstWave.count, 14)
        for pair in zip(firstWave, firstWave.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1 - pair.0, MeshLinkTiming.announceTickMs)
        }
        for times in sentAt.values {
            for pair in zip(times, times.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.1 - pair.0, MeshLinkTiming.announceIntervalMs)
                XCTAssertLessThanOrEqual(pair.1 - pair.0, 2 * MeshLinkTiming.announceIntervalMs)
            }
        }
    }

    // MARK: - Log volume

    private final class Box: @unchecked Sendable { var got: [(MeshLog.Level, String)] = [] }

    func testTheSummaryWritesOneLinePerWindowAndNothingForAQuietOne() {
        let box = Box()
        MeshLog.install(sink: { level, _, message in box.got.append((level, message)) })
        defer { MeshLog.install(sink: nil) }
        var summary = MeshAnnounceSummary(startMs: 0)
        for i in 0..<30 { summary.recordTx(ok: i != 3) }
        for _ in 0..<26 { summary.recordRx(node: "n1", address: "addr1") }
        // Two nodes claimed from two distinct addresses each, one node from the same address.
        summary.recordRx(node: "n2", address: "addrA")
        summary.recordRx(node: "n2", address: "addrB")
        summary.recordRx(node: "n3", address: "addrC")
        summary.recordRx(node: "n3", address: "addrD")
        summary.flushIfDue(nowMs: 59_000, links: 4)
        XCTAssertTrue(box.got.isEmpty)
        summary.flushIfDue(nowMs: 60_000, links: 4)
        XCTAssertEqual(box.got.map { $0.1 }, ["ann.sum tx=30 fail=1 rx=30 links=4 claim=2 ver=0 unv=0 badsig=0 s=60"])
        XCTAssertEqual(box.got.first?.0, .info)
        summary.flushIfDue(nowMs: 120_000, links: 4)
        XCTAssertEqual(box.got.count, 1)
    }

    func testTxFailWarningsAreCountedAndReportedOnTheNextLine() {
        let box = Box()
        MeshLog.install(sink: { level, _, message in box.got.append((level, message)) })
        defer { MeshLog.install(sink: nil) }
        var throttle = MeshTxFailThrottle(windowMs: 60_000)
        throttle.warn(link: "c4", ph: "aa", idx: 0, total: 1, reason: "timeout", nowMs: 0)
        throttle.warn(link: "c4", ph: "bb", idx: 0, total: 1, reason: "timeout", nowMs: 15_000)
        throttle.warn(link: "c4", ph: "cc", idx: 0, total: 1, reason: "timeout", nowMs: 30_000)
        XCTAssertEqual(box.got.map { $0.1 }, ["tx.frame.fail link=c4 ph=aa idx=0 total=1 reason=timeout"])
        XCTAssertEqual(box.got.first?.0, .warn)
        throttle.warn(link: "c4", ph: "dd", idx: 0, total: 1, reason: "timeout", nowMs: 61_000)
        XCTAssertEqual(box.got[1].1, "tx.frame.fail link=c4 ph=dd idx=0 total=1 reason=timeout rep=2")
    }

    func testAnotherLinkOrReasonIsNotThrottled() {
        let box = Box()
        MeshLog.install(sink: { level, _, message in box.got.append((level, message)) })
        defer { MeshLog.install(sink: nil) }
        var throttle = MeshTxFailThrottle(windowMs: 60_000)
        throttle.warn(link: "c4", ph: "aa", idx: 0, total: 1, reason: "timeout", nowMs: 0)
        throttle.warn(link: "c5", ph: "aa", idx: 0, total: 1, reason: "timeout", nowMs: 0)
        throttle.warn(link: "c4", ph: "aa", idx: 0, total: 1, reason: "rejected", nowMs: 0)
        XCTAssertEqual(box.got.count, 3)
    }

    // MARK: - Signed ANNOUNCE (section 8.5)

    private func proofLink(_ key: String, bound: Int64, verified: Bool = false, failed: Bool = false, data: Int64 = 0,
                           node: String? = "N", central: Bool = false) -> MeshLinkCandidate {
        MeshLinkCandidate(key: key, central: central, address: "addr-\(key)", subscribed: true, lastActivityMs: now - 1_000,
                          boundAtMs: bound, lastDataMs: data, nodeHex: node, verified: verified, failed: failed)
    }

    func testAVerifiedLinkRanksFirstButNothingIsLeftOutOfASend() {
        let claimantFirst = proofLink("claimant", bound: 100)
        let real = proofLink("real", bound: 900, verified: true)
        // The verified link is first, the unverified one is still a target: a link believed verified may be dead or relayed.
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [claimantFirst, real], nowMs: now), ["real", "claimant"])
        XCTAssertEqual(MeshNodeLinkPolicy.floodTargets(links: [claimantFirst, real], excludingKey: nil, excludingNode: nil, nowMs: now),
                       ["real", "claimant"])
        // Without a verified link every healthy one is used, as before.
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [claimantFirst, proofLink("other", bound: 200)], nowMs: now), ["claimant", "other"])
        XCTAssertEqual(MeshNodeLinkPolicy.relayTargets(links: [claimantFirst, real], recipientNode: "N", arrivalKey: nil, arrivalNode: nil, nowMs: now),
                       ["real", "claimant"])
    }

    func testADeadVerifiedLinkCannotBlackholeTheNodeTheUnverifiedOneStillGetsTheFrame() {
        let deadVerified = MeshLinkCandidate(key: "dead", central: false, address: "a", subscribed: true, lastActivityMs: now - 200_000,
                                             boundAtMs: 10, lastDataMs: 0, nodeHex: "N", verified: true)
        let live = proofLink("live", bound: 500)
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [deadVerified, live], nowMs: now), ["live"])
        // Within the 120 s a link not yet reaped still counts, but it no longer excludes the live one.
        let fresh = MeshLinkCandidate(key: "dead", central: false, address: "a", subscribed: true, lastActivityMs: now - 100_000,
                                      boundAtMs: 10, lastDataMs: 0, nodeHex: "N", verified: true)
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [fresh, live], nowMs: now), ["dead", "live"])
    }

    func testABadSignatureNeverWinsButTheLinkStillWorks() {
        let failed = proofLink("failed", bound: 10, failed: true)
        let plain = proofLink("plain", bound: 500)
        let verified = proofLink("ok", bound: 900, verified: true)
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [failed, plain, verified], nowMs: now), ["ok", "plain", "failed"])
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [failed, plain], nowMs: now), ["plain", "failed"])
        // Alone, a link whose proof failed is still a target: messaging is never blocked.
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [failed], nowMs: now), ["failed"])
        // Above the cap a failed link ranks last.
        let many = (1...5).map { proofLink("u\($0)", bound: 100 + Int64($0)) } + [failed]
        XCTAssertFalse(MeshNodeLinkPolicy.fanOut(links: many, nowMs: now).contains("failed"))
    }

    func testAMissingProofDoesNotBreakSending() {
        let a = proofLink("a", bound: 100)
        let b = proofLink("b", bound: 200)
        XCTAssertEqual(MeshNodeLinkPolicy.fanOut(links: [a, b], nowMs: now), ["a", "b"])
        XCTAssertEqual(MeshNodeLinkPolicy.floodTargets(links: [a, b], excludingKey: nil, excludingNode: nil, nowMs: now).sorted(), ["a", "b"])
    }

    func testAboveFourLinksTheVerifiedOnesRankFirstAndAnUnverifiedNewcomerCannotEvictOne() {
        let unverified = (1...6).map { proofLink("u\($0)", bound: 100 + Int64($0)) }
        let ver = proofLink("v", bound: 5_000, verified: true)
        let out = MeshNodeLinkPolicy.fanOut(links: unverified + [ver], nowMs: now)
        XCTAssertEqual(out.first, "v")
        XCTAssertEqual(out.count, 4)
        // The earliest-bound verified link of a node is protected; a verified link that is not the earliest of its node is not.
        let old = MeshLinkCandidate(key: "w:old", central: true, address: "a", subscribed: true, lastActivityMs: now - 1_000,
                                    boundAtMs: now - 300_000, lastDataMs: 0, nodeHex: "A", verified: true)
        let sibling = MeshLinkCandidate(key: "n:sib", central: false, address: "b", subscribed: true, lastActivityMs: now - 1_000,
                                        boundAtMs: now - 600_000, lastDataMs: 0, nodeHex: "A")
        let newcomer = MeshLinkCandidate(key: "w:new", central: true, address: "c", subscribed: true, lastActivityMs: now - 1_000,
                                         boundAtMs: now - 1_000, lastDataMs: 0, nodeHex: "B")
        XCTAssertNil(MeshNodeLinkPolicy.evictionVictim(links: [old, sibling, newcomer], centralRole: true, excludingKey: "w:new", nowMs: now))
    }

    func testInAFullyVerifiedMeshANonEarliestIdleLinkOfANodeCanBeEvicted() {
        func v(_ key: String, _ node: String, _ bound: Int64) -> MeshLinkCandidate {
            MeshLinkCandidate(key: key, central: true, address: "addr-\(key)", subscribed: true, lastActivityMs: now - 1_000,
                              boundAtMs: bound, lastDataMs: 0, nodeHex: node, verified: true)
        }
        let a1 = v("w:a1", "A", now - 400_000)
        let a2 = v("w:a2", "A", now - 300_000)
        let b1 = v("w:b1", "B", now - 350_000)
        let newcomer = MeshLinkCandidate(key: "w:new", central: true, address: "c", subscribed: true, lastActivityMs: now - 1_000,
                                         boundAtMs: now - 1_000, lastDataMs: 0, nodeHex: "C")
        XCTAssertEqual(MeshNodeLinkPolicy.evictionVictim(links: [a1, a2, b1, newcomer], centralRole: true, excludingKey: "w:new", nowMs: now), "w:a2")
        // With one link per node every link is the earliest of its node, so none is evictable.
        XCTAssertNil(MeshNodeLinkPolicy.evictionVictim(links: [a1, b1, newcomer], centralRole: true, excludingKey: "w:new", nowMs: now))
    }

    func testTheEarliestVerifiedLinkOfANodeStaysProtectedEvenIfASpooferBoundEarlier() {
        func link(_ key: String, _ bound: Int64, verified: Bool = false, node: String = "X") -> MeshLinkCandidate {
            MeshLinkCandidate(key: key, central: true, address: "addr-\(key)", subscribed: true, lastActivityMs: now - 1_000,
                              boundAtMs: bound, lastDataMs: 0, nodeHex: node, verified: verified)
        }
        let spoofer = link("w:spoof", now - 500_000)
        let real = link("w:real", now - 300_000, verified: true)
        let third = link("w:third", now - 200_000)
        let newcomer = link("w:new", now - 1_000, node: "Y")
        XCTAssertEqual(MeshNodeLinkPolicy.evictionVictim(links: [spoofer, real, third, newcomer], centralRole: true, excludingKey: "w:new", nowMs: now), "w:third")
        XCTAssertNil(MeshNodeLinkPolicy.evictionVictim(links: [spoofer, real, newcomer], centralRole: true, excludingKey: "w:new", nowMs: now))
    }

    func testTheDryRunTreatsVerifiedLinksLikeTheEvictionDoes() {
        func v(_ key: String, _ node: String, _ bound: Int64) -> MeshLinkCandidate {
            MeshLinkCandidate(key: key, central: true, address: "addr-\(key)", subscribed: true, lastActivityMs: now - 1_000,
                              boundAtMs: bound, lastDataMs: 0, nodeHex: node, verified: true)
        }
        let onePerNode = (1...6).map { v("w:\($0)", "N\($0)", now - 300_000) }
        XCTAssertFalse(MeshNodeLinkPolicy.probationUseful(links: onePerNode, centralRole: true, nowMs: now, limiterAllows: true))
        let withSecond = onePerNode + [v("w:extra", "N1", now - 200_000)]
        XCTAssertTrue(MeshNodeLinkPolicy.probationUseful(links: withSecond, centralRole: true, nowMs: now, limiterAllows: true))
        XCTAssertFalse(MeshNodeLinkPolicy.probationUseful(links: withSecond, centralRole: true, nowMs: now, limiterAllows: false))
    }

    func testVerificationNeverDecidesWhichOfASameDevicePairIsClosed() {
        func pair(first: Bool, second: Bool) -> [MeshLinkCandidate] {
            [MeshLinkCandidate(key: "w:1", central: true, address: "X", subscribed: true, lastActivityMs: now, boundAtMs: 10,
                               nodeHex: "N", verified: first),
             MeshLinkCandidate(key: "n:2", central: false, address: "X", subscribed: true, lastActivityMs: now, boundAtMs: 20,
                               nodeHex: "N", verified: second)]
        }
        // The two ends may have verified different things; only the role rule decides, so both close the same link.
        XCTAssertEqual(Set(MeshNodeLinkPolicy.sameDeviceDuplicates(localHex: "aa", peerHex: "bb", links: pair(first: false, second: true))), ["n:2"])
        XCTAssertEqual(Set(MeshNodeLinkPolicy.sameDeviceDuplicates(localHex: "bb", peerHex: "aa", links: pair(first: false, second: true))), ["w:1"])
        XCTAssertEqual(Set(MeshNodeLinkPolicy.sameDeviceDuplicates(localHex: "aa", peerHex: "bb", links: pair(first: true, second: false))), ["n:2"])
    }

    func testAKeyIsPinnedToItsNodeIdAndADifferentKeyNeverReplacesThePin() {
        var cache = MeshVerifiedCache()
        let keyA = Data(repeating: 1, count: 32)
        let keyB = Data(repeating: 2, count: 32)
        XCTAssertTrue(cache.keyMatches("node", key: keyA, nowMs: now))
        cache.put("node", key: keyA, nowMs: now)
        XCTAssertTrue(cache.keyMatches("node", key: keyA, nowMs: now + 1))
        XCTAssertFalse(cache.keyMatches("node", key: keyB, nowMs: now + 1))
        // A different key does not replace a live pin, and the pin is not deleted before it expires.
        cache.put("node", key: keyB, nowMs: now + 2)
        XCTAssertTrue(cache.keyMatches("node", key: keyA, nowMs: now + 3))
        XCTAssertFalse(cache.keyMatches("node", key: keyB, nowMs: now + MeshLinkTiming.verifiedCacheTtlMs - 1))
        XCTAssertTrue(cache.keyMatches("node", key: keyB, nowMs: now + MeshLinkTiming.verifiedCacheTtlMs))
        XCTAssertTrue(cache.keyMatches("other", key: keyB, nowMs: now))
        for i in 0..<200 { cache.put("n\(i)", key: keyA, nowMs: now + Int64(i)) }
        XCTAssertLessThanOrEqual(cache.count, MeshLinkTiming.tableCap)
    }

    func testTheCacheIsNotATrustWindowOnlyAVerifiedProofMakesALinkVerified() {
        let state = MeshLinkProofState()
        XCTAssertFalse(state.verifiedAt(now))
        state.state = .failed
        XCTAssertFalse(state.verifiedAt(now))
        state.state = .verified
        XCTAssertTrue(state.verifiedAt(now))
    }

    func testTheProofIsResentEveryAnnouncePeriodUntilThePeerSaysItVerifiedUs() {
        let state = MeshLinkProofState()
        // Nothing to answer before the peer's challenge is known and our own ANNOUNCE went out.
        XCTAssertFalse(state.proofDue(nowMs: now, bound: true))
        state.peerNonce = Data(count: 16)
        XCTAssertFalse(state.proofDue(nowMs: now, bound: true))
        state.announceSent = true
        XCTAssertFalse(state.proofDue(nowMs: now, bound: false))
        XCTAssertTrue(state.proofDue(nowMs: now, bound: true))
        // An attempt (that may have failed to sign or to write) is retried at the next ANNOUNCE, not sooner.
        state.lastProofAttemptMs = now
        XCTAssertFalse(state.proofDue(nowMs: now + MeshLinkTiming.announceIntervalMs - 1, bound: true))
        XCTAssertTrue(state.proofDue(nowMs: now + MeshLinkTiming.announceIntervalMs, bound: true))
        // What we verified of the peer does not stop it: the peer may still lack OUR proof.
        state.state = .verified
        XCTAssertTrue(state.proofDue(nowMs: now + MeshLinkTiming.announceIntervalMs, bound: true))
        // pv=1 from the peer stops it.
        state.peerVerifiedUs = true
        XCTAssertFalse(state.proofDue(nowMs: now + 10 * MeshLinkTiming.announceIntervalMs, bound: true))
    }

    func testTheProofIsSentAtMostEightTimesPerLink() {
        let state = MeshLinkProofState()
        state.peerNonce = Data(count: 16)
        state.announceSent = true
        var t = now
        var sent = 0
        for _ in 0..<40 {
            if state.proofDue(nowMs: t, bound: true) {
                state.lastProofAttemptMs = t
                state.proofSends += 1
                sent += 1
            }
            t += MeshLinkTiming.announceIntervalMs
        }
        XCTAssertEqual(sent, MeshLinkTiming.proofMaxSends)
    }

    func testPvIsReadStrictlyAndEncodedOnlyWithAChallenge() {
        let node = "21fe31dfa154a261"
        func parse(_ pv: String) -> Bool? {
            let json = #"{"v":1,"node":"\#(node)","fp":"\#(node)","nbrs":[],"ch":"00112233445566778899aabbccddeeff","pv":\#(pv)}"#
            return MeshAnnounce.decode(Data(json.utf8))?.peerVerified
        }
        XCTAssertEqual(parse("1"), true)
        for bad in [#""1""#, "true", "1.0", "2", "0", "null", "[1]"] { XCTAssertEqual(parse(bad), false, "pv=\(bad)") }
        let announce = MeshAnnounce(nodeIdHex: node, identityFingerprintHex: node, challengeHex: "00112233445566778899aabbccddeeff", peerVerified: true)
        XCTAssertTrue(String(decoding: announce.encode(), as: UTF8.self).hasSuffix(#","ch":"00112233445566778899aabbccddeeff","pv":1}"#))
        // Without a challenge there is nothing to confirm: pv is not written.
        XCTAssertFalse(String(decoding: MeshAnnounce(nodeIdHex: node, identityFingerprintHex: node, peerVerified: true).encode(), as: UTF8.self).contains("pv"))
    }

    func testAtMostThreeProofsAreCheckedPerLink() {
        let state = MeshLinkProofState()
        XCTAssertTrue(state.takeVerifyAttempt())
        XCTAssertTrue(state.takeVerifyAttempt())
        XCTAssertTrue(state.takeVerifyAttempt())
        XCTAssertFalse(state.takeVerifyAttempt())
        XCTAssertFalse(state.takeVerifyAttempt())
    }

    func testProofsGoThroughThePerLinkRateLimit() {
        var gate = MeshRelayGate()
        var allowed = 0
        for _ in 0..<(MeshRelayGate.maxPerWindow + 10) {
            if gate.allowControl(linkKey: "l", nowMs: now) { allowed += 1 }
        }
        XCTAssertEqual(allowed, MeshRelayGate.maxPerWindow)
        XCTAssertTrue(gate.allowControl(linkKey: "other", nowMs: now))
        XCTAssertTrue(gate.allowControl(linkKey: "l", nowMs: now + MeshRelayGate.windowMs + 1))
    }

    func testAReplayedProofDoesNotVerifyOnAnotherLink() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data((0..<32).map { UInt8($0) }))
        let prover = try XCTUnwrap(MeshNodeId.from(identityKeyRaw: key.publicKey.rawRepresentation))
        let verifier = try MeshNodeId(hex: "21fe31dfa154a261")
        let pn = Data(repeating: 1, count: 16)
        let vn = Data(repeating: 2, count: 16)
        let message = try XCTUnwrap(MeshAnnounceProof.message(prover: prover, verifier: verifier, proverNonce: pn, verifierNonce: vn, proverIsCentral: true))
        let payload = try XCTUnwrap(MeshAnnounceProof.payload(publicKey: key.publicKey.rawRepresentation, signature: Data(try key.signature(for: message))))
        XCTAssertEqual(MeshAnnounceProof.verify(payload: payload, prover: prover, verifier: verifier, proverNonce: pn, verifierNonce: vn, proverIsCentral: true), .ok)
        // Another link has another challenge of ours: the captured proof fails there.
        XCTAssertEqual(MeshAnnounceProof.verify(payload: payload, prover: prover, verifier: verifier, proverNonce: pn,
                                                verifierNonce: Data(repeating: 9, count: 16), proverIsCentral: true), .badSignature)
        // A proof for another node id fails on the fingerprint check before the signature.
        XCTAssertEqual(MeshAnnounceProof.verify(payload: payload, prover: try MeshNodeId(hex: "0000000000000001"), verifier: verifier,
                                                proverNonce: pn, verifierNonce: vn, proverIsCentral: true), .nodeMismatch)
    }

    func testADryRunSaysTheProbationSlotIsUselessWhenNothingCouldBeEvicted() {
        let busy = (1...6).map {
            MeshLinkCandidate(key: "w:\($0)", central: true, address: "a\($0)", subscribed: true, lastActivityMs: now,
                              boundAtMs: now - 300_000, lastDataMs: now - 1_000, nodeHex: "N\($0)")
        }
        XCTAssertFalse(MeshNodeLinkPolicy.probationUseful(links: busy, centralRole: true, nowMs: now, limiterAllows: true))
        let quietOnly = busy.map {
            MeshLinkCandidate(key: $0.key, central: true, address: $0.address, subscribed: true, lastActivityMs: now,
                              boundAtMs: $0.boundAtMs, lastDataMs: 0, nodeHex: $0.nodeHex)
        }
        // Every quiet link is the only link of its node, so none may go.
        XCTAssertFalse(MeshNodeLinkPolicy.probationUseful(links: quietOnly, centralRole: true, nowMs: now, limiterAllows: true))
        let sibling = MeshLinkCandidate(key: "n:s", central: false, address: "s", subscribed: true, lastActivityMs: now,
                                        boundAtMs: now - 600_000, lastDataMs: 1, nodeHex: "N1")
        XCTAssertTrue(MeshNodeLinkPolicy.probationUseful(links: quietOnly + [sibling], centralRole: true, nowMs: now, limiterAllows: true))
        XCTAssertFalse(MeshNodeLinkPolicy.probationUseful(links: quietOnly + [sibling], centralRole: true, nowMs: now, limiterAllows: false))
    }

    func testTheIncomingRefusalAfterAnEvictionGrowsWithTheEvictionMemory() {
        var memory = MeshEvictionMemory()
        let first = memory.note("addr", nowMs: now)
        let second = memory.note("addr", nowMs: now + 61_000)
        let third = memory.note("addr", nowMs: now + 200_000)
        XCTAssertEqual(first, 30_000)
        XCTAssertEqual(second, 60_000)
        XCTAssertEqual(third, 120_000)
        XCTAssertEqual(max(MeshLinkTiming.evictRefuseMs, first), 60_000)
        XCTAssertEqual(max(MeshLinkTiming.evictRefuseMs, third), 120_000)
    }
}

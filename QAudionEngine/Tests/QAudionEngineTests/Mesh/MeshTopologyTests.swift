import XCTest
@testable import QAudionEngine

final class MeshTopologyTests: XCTestCase {

    private func nodeId(_ hex: String) throws -> MeshNodeId {
        try MeshNodeId(hex: hex)
    }

    func testDirectPeerCountReflectsRecordedAnnounces() throws {
        let topology = MeshTopology()
        XCTAssertEqual(topology.directPeerCount(), 0)
        topology.recordAnnounce(from: try nodeId("1111111111111111"), announcedNeighbors: [])
        topology.recordAnnounce(from: try nodeId("2222222222222222"), announcedNeighbors: [])
        XCTAssertEqual(topology.directPeerCount(), 2)
    }

    func testNextHopReturnsDirectNeighborWhenTargetIsDirect() throws {
        let topology = MeshTopology()
        let a = try nodeId("1111111111111111")
        topology.recordAnnounce(from: a, announcedNeighbors: [])
        XCTAssertEqual(topology.nextHop(for: a), a)
    }

    func testNextHopFindsTwoHopPath() throws {
        // local -> a -> b (target). `a` is a direct neighbor of us; `b` is
        // one of `a`'s announced neighbors.
        let topology = MeshTopology()
        let a = try nodeId("1111111111111111")
        let b = try nodeId("2222222222222222")
        topology.recordAnnounce(from: a, announcedNeighbors: [b])
        XCTAssertEqual(topology.nextHop(for: b), a)
    }

    func testNextHopFindsThreeHopPathWithinMaxHops() throws {
        let topology = MeshTopology()
        let a = try nodeId("1111111111111111")
        let b = try nodeId("2222222222222222")
        let c = try nodeId("3333333333333333")
        topology.recordAnnounce(from: a, announcedNeighbors: [b])
        topology.recordAnnounce(from: b, announcedNeighbors: [c])
        XCTAssertEqual(topology.nextHop(for: c, maxHops: 6), a)
    }

    func testNextHopReturnsNilWhenBeyondMaxHops() throws {
        let topology = MeshTopology()
        let a = try nodeId("1111111111111111")
        let b = try nodeId("2222222222222222")
        let c = try nodeId("3333333333333333")
        topology.recordAnnounce(from: a, announcedNeighbors: [b])
        topology.recordAnnounce(from: b, announcedNeighbors: [c])
        XCTAssertNil(topology.nextHop(for: c, maxHops: 1))
    }

    func testNextHopReturnsNilForUnknownTarget() throws {
        let topology = MeshTopology()
        topology.recordAnnounce(from: try nodeId("1111111111111111"), announcedNeighbors: [])
        XCTAssertNil(topology.nextHop(for: try nodeId("9999999999999999")))
    }

    func testNextHopForBroadcastIsAlwaysNil() throws {
        let topology = MeshTopology()
        topology.recordAnnounce(from: try nodeId("1111111111111111"), announcedNeighbors: [.broadcast])
        XCTAssertNil(topology.nextHop(for: .broadcast))
    }

    func testPruneDropsStaleNodesOnly() throws {
        let topology = MeshTopology()
        let a = try nodeId("1111111111111111")
        let b = try nodeId("2222222222222222")
        var now: Int64 = 0
        topology.clock = { now }

        topology.recordAnnounce(from: a, announcedNeighbors: [])
        now = 1_000
        topology.recordAnnounce(from: b, announcedNeighbors: [])

        // `a` is now 1000ms stale, `b` is fresh (0ms old).
        topology.prune(staleAfterMs: 500)
        XCTAssertEqual(topology.directPeerCount(), 1)
        XCTAssertEqual(topology.nextHop(for: b), b)
        XCTAssertNil(topology.nextHop(for: a))
    }

    func testReAnnounceRefreshesStaleness() throws {
        let topology = MeshTopology()
        let a = try nodeId("1111111111111111")
        var now: Int64 = 0
        topology.clock = { now }

        topology.recordAnnounce(from: a, announcedNeighbors: [])
        now = 1_000
        topology.recordAnnounce(from: a, announcedNeighbors: []) // re-announce refreshes lastAnnouncedAtMs

        topology.prune(staleAfterMs: 500)
        XCTAssertEqual(topology.directPeerCount(), 1)
    }
}

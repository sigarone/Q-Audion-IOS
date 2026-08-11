import XCTest
@testable import QAudionEngine

final class MeshRelayPolicyTests: XCTestCase {

    private func nodeId(_ hex: String) throws -> MeshNodeId {
        try MeshNodeId(hex: hex)
    }

    private func packet(sender: MeshNodeId, recipient: MeshNodeId, ttl: Int?) throws -> MeshPacket {
        try MeshPacket(type: .data, senderId: sender, recipientId: recipient, ttl: ttl, timestampMs: 0, payload: Data())
    }

    func testOwnPacketLoopingBackIsAlwaysDropped() throws {
        let local = try nodeId("0011223344556677")
        let p = try packet(sender: local, recipient: .broadcast, ttl: 5)
        let decision = MeshRelayPolicy.evaluate(
            packet: p, localNodeId: local, visiblePeerCount: 1, knownNextHop: nil
        )
        XCTAssertFalse(decision.shouldForward)
        XCTAssertEqual(decision.mode, .drop)
    }

    func testZeroOrNilTTLIsDropped() throws {
        let local = try nodeId("0011223344556677")
        let sender = try nodeId("8899aabbccddeeff")

        let zeroTTL = try packet(sender: sender, recipient: .broadcast, ttl: 0)
        XCTAssertFalse(MeshRelayPolicy.evaluate(packet: zeroTTL, localNodeId: local, visiblePeerCount: 1, knownNextHop: nil).shouldForward)

        let nilTTL = try packet(sender: sender, recipient: .broadcast, ttl: nil)
        XCTAssertFalse(MeshRelayPolicy.evaluate(packet: nilTTL, localNodeId: local, visiblePeerCount: 1, knownNextHop: nil).shouldForward)
    }

    func testKnownNextHopAlwaysPrefersDirectSend() throws {
        let local = try nodeId("0011223344556677")
        let sender = try nodeId("8899aabbccddeeff")
        let hop = try nodeId("1111111111111111")
        let p = try packet(sender: sender, recipient: .broadcast, ttl: 3)

        // Even with a huge peer count (which would otherwise damp flood
        // probability toward the floor), a known next hop always wins.
        let decision = MeshRelayPolicy.evaluate(
            packet: p, localNodeId: local, visiblePeerCount: 500, knownNextHop: hop,
            sampleUniform: { 0.999 } // would fail a probabilistic flood roll
        )
        XCTAssertTrue(decision.shouldForward)
        XCTAssertEqual(decision.mode, .directNextHop)
        XCTAssertEqual(decision.nextTTL, 2)
    }

    func testSparseNetworkAlwaysFloods() throws {
        let local = try nodeId("0011223344556677")
        let sender = try nodeId("8899aabbccddeeff")
        let p = try packet(sender: sender, recipient: .broadcast, ttl: 1)

        let decision = MeshRelayPolicy.evaluate(
            packet: p, localNodeId: local,
            visiblePeerCount: MeshRelayPolicy.denseNetworkFloor,
            knownNextHop: nil,
            sampleUniform: { 0.999 } // would fail if probability < 1.0
        )
        XCTAssertTrue(decision.shouldForward)
        XCTAssertEqual(decision.mode, .floodRebroadcast)
    }

    func testDenseNetworkCanDropBelowSampleThreshold() throws {
        let local = try nodeId("0011223344556677")
        let sender = try nodeId("8899aabbccddeeff")
        let p = try packet(sender: sender, recipient: .broadcast, ttl: 1)

        let decision = MeshRelayPolicy.evaluate(
            packet: p, localNodeId: local, visiblePeerCount: 1000, knownNextHop: nil,
            sampleUniform: { 0.9999 } // above even the floor probability
        )
        XCTAssertFalse(decision.shouldForward)
        XCTAssertEqual(decision.mode, .drop)
    }

    func testRelayProbabilityMonotonicNonIncreasingInPeerCount() {
        let ttl = MeshPacket.defaultTTL
        var previous = 1.0
        for peers in stride(from: MeshRelayPolicy.denseNetworkFloor, through: 500, by: 25) {
            let p = MeshRelayPolicy.relayProbability(visiblePeerCount: peers, ttl: ttl)
            XCTAssertLessThanOrEqual(p, previous + 1e-9)
            previous = p
        }
    }

    func testRelayProbabilityMonotonicNonDecreasingInTTLFraction() {
        let peers = 200
        var previous = 0.0
        for ttl in 0...MeshPacket.defaultTTL {
            let p = MeshRelayPolicy.relayProbability(visiblePeerCount: peers, ttl: ttl)
            XCTAssertGreaterThanOrEqual(p, previous - 1e-9)
            previous = p
        }
    }

    func testRelayProbabilityNeverBelowFloor() {
        for peers in [10, 100, 1_000, 100_000] {
            let p = MeshRelayPolicy.relayProbability(visiblePeerCount: peers, ttl: 0)
            XCTAssertGreaterThanOrEqual(p, MeshRelayPolicy.minRelayProbability - 1e-9)
        }
    }

    func testRelayProbabilityNeverAboveOne() {
        for peers in [0, 1, 4, 5] {
            for ttl in 0...10 {
                let p = MeshRelayPolicy.relayProbability(visiblePeerCount: peers, ttl: ttl)
                XCTAssertLessThanOrEqual(p, 1.0)
            }
        }
    }
}

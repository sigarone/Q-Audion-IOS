import Foundation

/// Pure relay/TTL forwarding policy. Deliberately holds ZERO CoreBluetooth
/// or UIKit type — every input is a plain value — so it is unit-testable on
/// the bare Swift Package Manager test target without a device or
/// simulator. All framework glue — actually reading the live peer count off
/// the transport's known-peers set, actually calling `send` to rebroadcast —
/// lives OUTSIDE this type, in the app-target transport/runtime.
public enum MeshRelayPolicy {

    public enum ForwardMode: Equatable { case directNextHop, floodRebroadcast, drop }

    public struct Decision: Equatable {
        public let shouldForward: Bool
        public let nextTTL: Int
        public let mode: ForwardMode
    }

    /// Peer count at or below which every eligible packet is relayed with
    /// probability 1.0 — "always relay in small networks".
    public static let denseNetworkFloor = 4

    /// Floor so a packet is never guaranteed to be dropped outright purely
    /// from network density.
    public static let minRelayProbability = 0.15

    /// - Parameters:
    ///   - packet: an inbound packet not (only) addressed to us — callers
    ///     typically only reach this function once they've already decided
    ///     the packet is also worth relaying (e.g. it's a broadcast, or
    ///     addressed to a different node).
    ///   - localNodeId: this device's own id, used only for a defensive
    ///     self-check (a packet whose sender is us should never reach here —
    ///     that would mean our own relay echoed back to us).
    ///   - visiblePeerCount: current directly-reachable peer count — the
    ///     dense-network damping input.
    ///   - knownNextHop: non-nil when the caller already resolved a direct
    ///     route to the packet's recipient via `MeshTopology.nextHop(for:)`.
    ///   - sampleUniform: injectable source of a uniform `[0,1)` draw —
    ///     defaults to `Double.random(in:)`, tests pass a deterministic stub.
    public static func evaluate(
        packet: MeshPacket,
        localNodeId: MeshNodeId,
        visiblePeerCount: Int,
        knownNextHop: MeshNodeId?,
        sampleUniform: () -> Double = { Double.random(in: 0..<1) }
    ) -> Decision {
        if packet.senderId == localNodeId {
            // Our own packet looping back through a relay — never re-relay it.
            return Decision(shouldForward: false, nextTTL: 0, mode: .drop)
        }
        guard let ttl = packet.ttl, ttl > 0 else {
            return Decision(shouldForward: false, nextTTL: 0, mode: .drop)
        }
        let nextTTL = ttl - 1

        if let knownNextHop {
            _ = knownNextHop // used only to gate the branch below; kept named for call-site clarity.
            // Prefer a direct send over a flood whenever a known path
            // exists, regardless of density/TTL.
            return Decision(shouldForward: true, nextTTL: nextTTL, mode: .directNextHop)
        }

        let probability = relayProbability(visiblePeerCount: visiblePeerCount, ttl: ttl)
        let forward = sampleUniform() < probability
        return Decision(
            shouldForward: forward,
            nextTTL: nextTTL,
            mode: forward ? .floodRebroadcast : .drop
        )
    }

    /// Relay probability curve: `1.0` in a small/sparse network (peer count
    /// at or below ``denseNetworkFloor``) or for a freshly-originated
    /// (high-TTL) packet; decays as `visiblePeerCount` grows so a dense mesh
    /// doesn't amplify a flood into a broadcast storm, floored at
    /// ``minRelayProbability`` so a packet is never guaranteed to die
    /// outright even in a crowded room.
    ///
    /// The exact curve/constants are placeholders pending real-world field
    /// measurement — this only commits to the SHAPE the functional spec
    /// requires: monotonically non-increasing in `visiblePeerCount`,
    /// monotonically non-decreasing in the TTL fraction `ttl / maxTTL`.
    static func relayProbability(visiblePeerCount: Int, ttl: Int, maxTTL: Int = MeshPacket.defaultTTL) -> Double {
        if visiblePeerCount <= denseNetworkFloor { return 1.0 }
        let ttlFraction = min(max(Double(ttl) / Double(maxTTL), 0.0), 1.0)
        let densityDamping = Double(denseNetworkFloor) / Double(visiblePeerCount)
        let probability = densityDamping + ttlFraction * (1.0 - densityDamping)
        return min(max(probability, minRelayProbability), 1.0)
    }
}

import Foundation

/// One link the transport can write to right now, as seen at the moment of the question: the node on the other end and
/// the neighbours that node announced (so it can act as a bridge).
public struct MeshLiveLink: Equatable, Hashable, Sendable {
    public let nodeHex: String
    public let announcedNeighborHexes: Set<String>

    public init(nodeHex: String, announcedNeighborHexes: Set<String> = []) {
        self.nodeHex = nodeHex
        self.announcedNeighborHexes = announcedNeighborHexes
    }
}

/// "Is this node reachable over Bluetooth right now": a pure read over the LIVE writable links, never over a list
/// published earlier. A dropped link stops counting the moment the transport removes it, so a send decided a moment
/// later goes to the network instead of being queued on a mesh with no links. A node behind a bridge counts only while
/// the bridge's own link is live.
public enum MeshLiveReach {
    public static func reach(
        toNodeHex targetNodeHex: String,
        liveLinks: [MeshLiveLink]
    ) -> (reachable: Bool, viaBridgeNodeHex: String?) {
        if liveLinks.contains(where: { $0.nodeHex == targetNodeHex }) {
            return (true, nil)
        }
        if let bridge = liveLinks.first(where: { $0.announcedNeighborHexes.contains(targetNodeHex) }) {
            return (true, bridge.nodeHex)
        }
        return (false, nil)
    }
}

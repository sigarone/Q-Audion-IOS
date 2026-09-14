import Foundation

/// In-memory, locally-built mesh topology view: each ANNOUNCE a peer sends
/// carries the set of nodes IT is directly connected to; accumulating those
/// across peers lets this device infer a route to a peer it cannot directly
/// reach — but only as far as its own direct neighbors' self-reported
/// neighbors, since ANNOUNCE packets are never relayed (see
/// `BleMeshTransport.handlePacket`'s `.announce` branch, which returns
/// before the flood-relay block), so the graph never grows past 2 levels.
///
/// ``nextHop(for:maxHops:)`` is consumed by ``MeshRuntime/sendData`` at the
/// point a message *originates*, to prefer a direct write to a known bridge
/// over a flood. It is NOT consulted again once a packet is in flight:
/// `MeshRelayPolicy/evaluate(packet:localNodeId:visiblePeerCount:knownNextHop:sampleUniform:)`'s
/// `knownNextHop` parameter is hard-coded to `nil` at every relay call site
/// in `handlePacket`, so an intermediate hop always floods rather than
/// directing the packet onward with its own topology view. This is a
/// materially weaker, origination-only version of true multi-hop source
/// routing — `MeshPacket.sourceRoute` exists on the wire for this purpose
/// but no caller ever populates it.
///
/// Holds no CoreBluetooth type — the graph-walk logic below is
/// unit-testable on the plain Swift Package Manager test target, even
/// though the graph itself is expected to persist for the whole
/// mesh-participation session (mirroring how a transport's known-peers set
/// is itself process-lifetime state).
public final class MeshTopology {

    public static let defaultMaxHops = 6

    private struct NeighborRecord {
        let neighbors: Set<MeshNodeId>
        let lastAnnouncedAtMs: Int64
    }

    private let lock = NSLock()
    private var graph: [MeshNodeId: NeighborRecord] = [:]
    private var insertionOrder: [MeshNodeId] = []

    /// Test/production clock seam.
    public var clock: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    public init() {}

    public func recordAnnounce(from: MeshNodeId, announcedNeighbors: Set<MeshNodeId>) {
        lock.lock()
        defer { lock.unlock() }
        if graph[from] == nil {
            insertionOrder.append(from)
        }
        graph[from] = NeighborRecord(neighbors: announcedNeighbors, lastAnnouncedAtMs: clock())
    }

    /// Count of nodes we've recorded a still-fresh ANNOUNCE from — the
    /// "visible peer count" ``MeshRelayPolicy`` dampens relay probability
    /// on.
    ///
    /// NOTE: this can lag the transport's own live-radio peer set since it
    /// only reflects ANNOUNCE packets actually received and not yet
    /// ``prune(staleAfterMs:)``d. A real wiring should reconcile the two, or
    /// pick one as the canonical source for ``MeshRelayPolicy`` callers —
    /// left as an open integration question, not resolved here.
    public func directPeerCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return graph.count
    }

    /// Best-effort breadth-first search over the accumulated neighbor graph
    /// for a route to `target`. Returns the first direct neighbor whose
    /// reachability tree contains `target` within `maxHops` — this is a
    /// "found a path" search, not a shortest-path search; a real
    /// implementation wanting the globally-shortest route would need a
    /// proper multi-source BFS instead of iterating candidates in insertion
    /// order, which this deliberately keeps simple.
    public func nextHop(for target: MeshNodeId, maxHops: Int = MeshTopology.defaultMaxHops) -> MeshNodeId? {
        lock.lock()
        defer { lock.unlock() }
        if target == .broadcast { return nil } // broadcast has no single next hop by definition
        for directNeighbor in insertionOrder {
            if directNeighbor == target { return directNeighbor }
            if reachable(from: directNeighbor, target: target, hopsLeft: maxHops - 1) { return directNeighbor }
        }
        return nil
    }

    /// Caller already holds `lock`.
    private func reachable(from: MeshNodeId, target: MeshNodeId, hopsLeft: Int) -> Bool {
        guard hopsLeft > 0 else { return false }
        var visited = Set<MeshNodeId>()
        var frontier = graph[from]?.neighbors ?? []
        var remaining = hopsLeft
        while !frontier.isEmpty && remaining > 0 {
            if frontier.contains(target) { return true }
            visited.formUnion(frontier)
            var next = Set<MeshNodeId>()
            for node in frontier {
                for neighbor in graph[node]?.neighbors ?? [] where !visited.contains(neighbor) {
                    next.insert(neighbor)
                }
            }
            frontier = next
            remaining -= 1
        }
        return false
    }

    /// Drops any node whose most recent ANNOUNCE is older than
    /// `staleAfterMs`. Caller invokes periodically (e.g. alongside
    /// ``MeshFragmentReassembler/sweepExpired(setTimeoutMs:)``) — this class
    /// runs no timer of its own.
    public func prune(staleAfterMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let stale = insertionOrder.filter { node in
            guard let record = graph[node] else { return false }
            return now - record.lastAnnouncedAtMs > staleAfterMs
        }
        for node in stale {
            graph.removeValue(forKey: node)
        }
        insertionOrder.removeAll { stale.contains($0) }
    }
}

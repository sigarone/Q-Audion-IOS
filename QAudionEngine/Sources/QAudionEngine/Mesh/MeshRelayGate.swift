import Foundation

/// The relay conditions of docs/mesh/MESH_LINK_SPEC.md section 9.2, in one place
/// so they can be tested without a radio.
///
/// A packet is relayed only if ALL of these hold: the mode relays (FULL); the type
/// is DATA or RECEIPT; the recipient is not this device; the sender is not this
/// device; a ttl is present and greater than zero; this device has not relayed it
/// before (identity: sender, recipient, type, timestamp, payload hash; ttl
/// excluded; the last 256 identities are remembered); the immediate link has
/// relayed at most 20 packets through this device in the current 10 s window; and
/// the relay probability draw (section 9.3) succeeds.
public struct MeshRelayGate {

    public static let rememberedIdentities = 256
    public static let maxPerWindow = 20
    public static let windowMs: Int64 = 10_000

    public enum SkipReason: String, Equatable, Sendable {
        case mode
        case ttl
        case dup
        case rate
    }

    public enum Decision: Equatable {
        /// Forward with `nextTTL`; `permille` is the probability that was applied.
        case forward(nextTTL: Int, permille: Int)
        /// A condition of 9.2 failed. `nil` for the types and addressing that are
        /// simply not relayed (no event is written for them).
        case skip(SkipReason?)
        /// Every condition held and the probability draw failed.
        case dropped(permille: Int)
    }

    private struct Window {
        var startMs: Int64
        var count: Int
    }

    private var windows: [String: Window] = [:]
    private var identityOrder: [String] = []
    private var identitySet: Set<String> = []

    public init() {}

    /// Number of relay identities currently remembered.
    public var rememberedCount: Int { identityOrder.count }

    /// Forgets the per-link window of a link that went away.
    public mutating func linkGone(_ linkKey: String) {
        windows.removeValue(forKey: linkKey)
    }

    /// - Parameters:
    ///   - payloadHash: the packet's `ph` (``MeshLog/payloadHash(_:)``).
    ///   - linkKey: the immediate link the packet arrived on.
    ///   - linkedNodes: distinct nodes currently linked (`n` of section 9.3).
    ///   - sample: a uniform draw in `[0, 1)`.
    public mutating func decide(
        packet: MeshPacket,
        payloadHash: String,
        linkKey: String,
        localNodeId: MeshNodeId,
        mode: MeshAntennaMode,
        linkedNodes: Int,
        nowMs: Int64,
        sample: () -> Double = { Double.random(in: 0..<1) }
    ) -> Decision {
        guard packet.type == .data || packet.type == .receipt else { return .skip(nil) }
        guard packet.recipientId != localNodeId, packet.senderId != localNodeId else { return .skip(nil) }
        guard mode.relays else { return .skip(.mode) }
        guard let ttl = packet.ttl, ttl > 0 else { return .skip(.ttl) }

        let identity = "\(packet.senderId.hex):\(packet.recipientId.hex):\(packet.type.rawValue):\(packet.timestampMs):\(payloadHash)"
        if identitySet.contains(identity) { return .skip(.dup) }

        // The window counts every packet this link asks us to relay, forwarded or not.
        if var window = windows[linkKey], nowMs - window.startMs <= Self.windowMs {
            window.count += 1
            windows[linkKey] = window
            if window.count > Self.maxPerWindow { return .skip(.rate) }
        } else {
            windows[linkKey] = Window(startMs: nowMs, count: 1)
        }

        let probability = MeshRelayPolicy.relayProbability(visiblePeerCount: linkedNodes, ttl: ttl)
        let permille = Int((probability * 1000).rounded())
        guard sample() < probability else { return .dropped(permille: permille) }

        remember(identity)
        return .forward(nextTTL: ttl - 1, permille: permille)
    }

    private mutating func remember(_ identity: String) {
        identitySet.insert(identity)
        identityOrder.append(identity)
        if identityOrder.count > Self.rememberedIdentities {
            let evicted = identityOrder.removeFirst()
            identitySet.remove(evicted)
        }
    }
}

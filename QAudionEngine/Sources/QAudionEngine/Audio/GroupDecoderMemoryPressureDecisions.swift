import Foundation

/// W-GRPMEMPRESSURE (2026-08-26) — pure eviction-ranking decision for
/// `GroupCallController`'s per-sender Opus decoder map
/// (`perSenderDecoders`). No memory-warning response existed anywhere in
/// the call stack before this: `GroupCallController` keeps one native
/// `OpusCodec` (a real libopus decoder handle plus the Deep PLC neural
/// concealment model, see `OpusCodec.init`) PER PEER for the ENTIRE call,
/// created on that peer's first frame and freed only at full call teardown
/// — a group call with many participants, several of whom go quiet for
/// long stretches, holds every one of those decoders regardless.
///
/// Contains NO `OpusCodec`/lock/notification state, so the ranking itself
/// is pinnable by unit tests without a live call — same discipline as
/// `RestartIceDecisions` in the WebRTC/ directory. The caller
/// (`GroupCallController.handleMemoryPressure`) owns the actual eviction
/// (removing entries from `perSenderDecoders`); this type only decides
/// WHICH senderIds to drop.
enum GroupDecoderMemoryPressureDecisions {

    /// Floor of most-recently-active per-sender decoders to keep across a
    /// memory-pressure event. Below this, evicting further barely helps
    /// (a handful of native decoder handles is not the dominant cost);
    /// above it, an inactive sender's decoder + Deep PLC model is pure
    /// standing cost for a peer nobody is currently hearing from.
    static let decoderFloor = 4

    /// Which sender ids to evict, given each currently-held decoder's last
    /// observed activity time. Returns the OLDEST `count - floor` senders
    /// by `lastActive` (never more than that — this only trims down TO the
    /// floor, never below it), or an empty array when there is nothing to
    /// trim (`lastActive.count <= floor`) or `floor` is negative (a
    /// defensively-rejected caller error, not a "evict everything" signal).
    ///
    /// A sender absent from `lastActive` cannot be evicted (there is
    /// nothing to rank it against) — callers are expected to keep
    /// `lastActive` in lockstep with the decoder map itself (one entry per
    /// currently-held decoder), which is exactly what
    /// `GroupCallController.handleIncomingFrame` already does.
    static func decodersToEvict(lastActive: [String: Date], floor: Int) -> [String] {
        guard floor >= 0, lastActive.count > floor else { return [] }
        let oldestFirst = lastActive.keys.sorted { a, b in
            (lastActive[a] ?? .distantPast) < (lastActive[b] ?? .distantPast)
        }
        return Array(oldestFirst.prefix(lastActive.count - floor))
    }
}

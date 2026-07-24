import Foundation

/// WIRE_SPEC §8.9 — the video-state BEACON rules, as pure functions.
///
/// Byte-for-byte the same rules as Android's `VideoStateBeacon.kt` and
/// Desktop's `VideoStateBeacon.ts`; the three copies exist because the state
/// lives in three different runtimes, not because the protocol differs.
///
/// ## Why a beacon at all
///
/// `call_video_state` used to be edge-triggered only: each side announced its
/// camera the moment it toggled, once, and never again. That makes the peer's
/// lane a value both sides must derive from a stream of edges — and every way
/// of losing one edge is unrecoverable:
///
/// - the announcement is sent while the peer's WS is stale (the same class of
///   bug already fixed for group fan-out): the edge is simply gone;
/// - the peer reconnects mid-call: it starts with no knowledge of our camera
///   and nothing ever tells it;
/// - two toggles race and arrive reordered: the older edge wins and pins the
///   lane to the wrong value permanently.
///
/// All three end with the two sides disagreeing for the rest of the call,
/// which is exactly the reported "voice → video → voice → video and then it
/// will not go back to voice on both sides".
///
/// ## The rules
///
/// A beacon is state-triggered: each side re-announces its CURRENT state on
/// change, on a ``heartbeatMs`` timer, and on WS reconnect, so a missed
/// announcement self-heals within one heartbeat.
///
/// Repeats need an ordering rule or a stale repeat could overwrite a fresh
/// toggle, so each announcement carries a per-(call, sender) monotonic `seq`
/// and the receiver applies last-writer-wins on it.
///
/// ## Interop
///
/// `seq`/`sending`/`screen` are additive optional fields on an existing
/// message the server relays verbatim (no server change). A peer that omits
/// `seq` is accepted unconditionally — exactly today's behaviour — so a new
/// client against an old one is never worse off, and the ordering protection
/// switches on by itself once both sides ship.
public enum VideoStateBeacon {

    /// Re-announce period while a call is up. Short enough that a lost edge is
    /// invisible to a human, cheap enough to be free against a socket already
    /// carrying 50 audio frames/s.
    public static let heartbeatMs: Int = 3_000

    /// First sequence number of a call. 0 means "never announced".
    public static let firstSeq: Int = 1

    /// Last-writer-wins. `lastSeq` is the highest seq accepted so far from this
    /// peer for this call (nil = nothing accepted yet).
    ///
    /// A legacy peer that omits `seq` is always accepted: it only ever sends
    /// edges, and dropping one would strand the lane — the very failure this
    /// exists to prevent.
    public static func shouldAccept(lastSeq: Int?, incomingSeq: Int?) -> Bool {
        guard let incomingSeq else { return true }
        guard let lastSeq else { return true }
        return incomingSeq > lastSeq
    }

    /// The seq to store after accepting. Never moves backwards, so a legacy
    /// (seq-less) announcement interleaved with numbered ones cannot reset the
    /// window and let an already-superseded repeat back in.
    public static func nextStoredSeq(lastSeq: Int?, acceptedSeq: Int?) -> Int? {
        guard let acceptedSeq else { return lastSeq }
        guard let lastSeq else { return acceptedSeq }
        return max(lastSeq, acceptedSeq)
    }

    /// Our next outbound seq for this call.
    public static func advance(_ currentSeq: Int) -> Int {
        currentSeq < firstSeq ? firstSeq : currentSeq + 1
    }

    /// Whether a beacon carrying `sending` must go out given what we last
    /// announced. `force` covers the heartbeat and reconnect triggers, where
    /// repeating an unchanged value IS the point.
    public static func shouldAnnounce(
        lastAnnouncedSending: Bool?,
        sending: Bool,
        force: Bool
    ) -> Bool {
        force || lastAnnouncedSending != sending
    }
}

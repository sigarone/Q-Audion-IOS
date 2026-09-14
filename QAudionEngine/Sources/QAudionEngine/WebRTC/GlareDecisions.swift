import Foundation

/// W-GLARE (2026-08-25) — mutual-dial tiebreak, parity plan Fase B item B2.
///
/// Two peers dialing each other at the same instant produce two independent
/// calls (two call ids), each ringing the other side — and the server's busy
/// guard deliberately exempts glare, so without resolution both phones ring
/// each other forever. Before this helper, iOS busy-rejected the incoming leg
/// while Android ran its tiebreak: the surviving leg received the busy and
/// BOTH calls could die.
///
/// ## The rule (bit-identical to Android — `MainActivity`'s call_incoming
/// collector, do not reinterpret)
///
/// Both sides compute the same deterministic comparison over the same two
/// strings: my OUTGOING call id vs the id of the incoming offer from the very
/// peer I am dialing. The side whose OUTGOING id is GREATER wins — it
/// suppresses the incoming offer and keeps dialing. The loser tears down its
/// outgoing (reason `"glare"`, notifying the peer, whose id-gated hangup
/// handler / recently-hung-up window absorbs it) and lets the surviving
/// incoming call ring normally. Since my outgoing id is the peer's incoming
/// id and vice versa, exactly one side wins every time.
///
/// ## Why the comparison is spelled out by hand
///
/// Kotlin's `String.compareTo` orders by UTF-16 code unit, then by length.
/// Swift's `<`/`>` on `String` use Unicode canonical ordering, which agrees
/// for the ASCII ids both platforms mint today but is NOT the same function —
/// and a tiebreak that two platforms compute differently is a tiebreak that
/// can elect two winners. `isOutgoingGreater` reproduces Kotlin's ordering
/// exactly, code unit by code unit.
///
/// Equality is exact (case-sensitive), matching Android's `!=` guard: an
/// incoming envelope carrying the SAME id as the outgoing call is an
/// ICE-restart / replay of our own call, not glare — the caller's existing
/// dedup handling owns that case.
public enum GlareDecisions {

    /// What the call_incoming handler should do with an offer that arrived
    /// from the very peer we are currently dialing.
    public enum Verdict: Equatable {
        /// Not a glare situation (no outgoing id, or the ids are identical —
        /// an ICE-restart/replay of our own call). Keep today's behavior.
        case notGlare
        /// Our outgoing id is greater: suppress the incoming offer entirely
        /// and keep dialing. The peer computes the mirror verdict and yields.
        case winnerSuppressIncoming
        /// Our outgoing id is smaller: tear down our outgoing call with
        /// reason `"glare"` (notifying the peer), then let the incoming
        /// offer ring normally.
        case loserYieldToIncoming
    }

    /// - Parameters:
    ///   - outgoingCallId: the wire id of OUR outgoing call to this peer, or
    ///     nil/empty when we are not dialing them (→ `.notGlare`).
    ///   - incomingCallId: the `call_id` of the incoming offer envelope.
    public static func resolve(outgoingCallId: String?, incomingCallId: String) -> Verdict {
        guard let out = outgoingCallId, !out.isEmpty, !incomingCallId.isEmpty else {
            return .notGlare
        }
        guard out != incomingCallId else { return .notGlare }
        return isOutgoingGreater(out, than: incomingCallId)
            ? .winnerSuppressIncoming
            : .loserYieldToIncoming
    }

    /// Kotlin `String.compareTo` semantics: lexicographic over UTF-16 code
    /// units, longer string wins a shared prefix. Public so the parity test
    /// can pin the ordering directly.
    public static func isOutgoingGreater(_ a: String, than b: String) -> Bool {
        let au = Array(a.utf16)
        let bu = Array(b.utf16)
        var i = 0
        while i < au.count && i < bu.count {
            if au[i] != bu[i] { return au[i] > bu[i] }
            i += 1
        }
        return au.count > bu.count
    }
}

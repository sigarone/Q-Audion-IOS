import Foundation

/// W-GRPAUDIOKEY §7 (2026-08-27) — pure decision helper for
/// `GroupCallController.resolveFallbackRxAudioKey`: given the wire's claimed
/// `epoch_id` for one sender and this controller's locally cached audio_key
/// state for that sender, decide whether to accept the frame and which
/// cached `audio_key` to open it under.
///
/// A group-call member's local `groupEpoch` bumps on any member removal
/// (`GroupSession.handleMemberRemoved`), which reseeds `SK_0`/`CK_0` and
/// therefore `audio_key` for everyone. Peers converge on the new epoch at
/// slightly different times (their own `sender_key_rotate` control envelope
/// has to arrive), so frames already in flight under the OLD epoch must
/// still decode for a short grace window after THIS side's own bump — but
/// nothing OLDER than that must ever be accepted, which is what closes the
/// replay/downgrade risk an external security review flagged for this
/// feature.
///
/// Extracted so the accept/reject boundary is directly unit-testable
/// without constructing a live `GroupCallController`/`GroupSession` — same
/// "pure decision struct" discipline `SfuDisconnectFallbackDecision`
/// already uses in this package.
public enum GroupAudioEpochKeyResolver {

    /// One cached (epoch, audio_key) pair for a sender — either the live
    /// "current epoch" cache slot or the "previous epoch" grace slot.
    public struct CachedKey {
        public let epochId: UInt32
        public let audioKey: Data

        public init(epochId: UInt32, audioKey: Data) {
            self.epochId = epochId
            self.audioKey = audioKey
        }
    }

    /// - Parameters:
    ///   - wireEpochId: `epoch_id` as declared ON THE WIRE (never a
    ///     caller-supplied value — see `GroupFallbackAudioSealer.openAudio`'s
    ///     own kdoc for why that distinction matters).
    ///   - currentEpochId: this side's own `GroupState.groupEpoch` right now.
    ///   - current: this sender's audio_key cached for `currentEpochId`, if
    ///     any has been derived/cached yet.
    ///   - grace: this sender's audio_key snapshotted at the moment of the
    ///     PREVIOUS local epoch bump, if the grace window (`graceExpiresAt`)
    ///     has not yet elapsed.
    ///   - graceExpiresAt: when `grace` (if present) stops being honored.
    ///   - now: the current time, injected for determinism in tests.
    /// - Returns: the `audio_key` to open under, or `nil` to reject the
    ///   frame outright.
    public static func resolve(
        wireEpochId: UInt32,
        currentEpochId: UInt32,
        current: CachedKey?,
        grace: CachedKey?,
        graceExpiresAt: Date?,
        now: Date
    ) -> Data? {
        if wireEpochId == currentEpochId, let current = current, current.epochId == wireEpochId {
            return current.audioKey
        }
        if let grace = grace, let expiresAt = graceExpiresAt,
           grace.epochId == wireEpochId, now < expiresAt {
            return grace.audioKey
        }
        return nil
    }
}

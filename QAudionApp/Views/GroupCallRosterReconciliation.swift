import Foundation

/// W-GRPSFUGHOST follow-up (2026-09-30) — pure decision logic extracted from
/// `GroupCallViewModel.mergeSfuOnlyParticipants` and the LiveKit
/// `participantDisconnected` handler (`onSfuParticipant(_, false)`), so the
/// roster-vs-SFU reconciliation rules can be pinned by unit tests without a
/// live `LiveKitGroupCallRoom`/`Room` (same discipline as
/// `LiveKitGroupCallRoom.videoPublishFailureAction`/`videoEncoding(for:)`
/// in the engine target).
///
/// Two independent event streams feed `GroupCallViewModel.participants`, and
/// neither is reliably ahead of the other:
///   - the WS-signaling roster (`group_call_update`, one full snapshot per
///     broadcast, tracked as `wsRosterIds` on the view model);
///   - LiveKit's own room membership (`participantDidConnect`/
///     `participantDisconnected`, forwarded as `onSfuParticipant`, tracked
///     as `sfuPresentIdentities`).
///
/// Ghost tiles came from two different orderings of those two streams:
///   - LiveKit-then-roster (the original W-GRPSFUGHOST bug, live repro
///     DC7D18B9): a participant is a real LiveKit room member the WS
///     roster never lists at all (the server reaped them from
///     `GroupCall.Participants` after an ungraceful disconnect while their
///     LiveKit session stayed alive) — `identitiesToSynthesize` is what
///     gives them a tile anyway.
///   - roster-then-LiveKit (this follow-up): the server's departure signal
///     (a roster broadcast that stops listing someone) arrives BEFORE
///     LiveKit's own `participantDisconnected` — without quarantine,
///     `identitiesToSynthesize` would immediately resurrect a tile for
///     someone the server just told us left, off the stale
///     `sfuPresentIdentities` entry LiveKit hasn't caught up on yet.
enum GroupCallRosterReconciliation {

    /// Which identities `mergeSfuOnlyParticipants` should synthesize a tile
    /// for: LiveKit says they're in the room, the WS roster doesn't
    /// currently list them, they're not our own local tile, and the roster
    /// hasn't just told us they left (`quarantined`, see
    /// `quarantineAfterRosterUpdate`).
    static func identitiesToSynthesize(
        sfuPresentIdentities: Set<String>,
        knownParticipantIds: Set<String>,
        quarantined: Set<String>,
        selfUserId: String
    ) -> Set<String> {
        sfuPresentIdentities
            .subtracting(knownParticipantIds)
            .subtracting(quarantined)
            .subtracting([selfUserId])
    }

    /// Whether a LiveKit `participantDisconnected` (`onSfuParticipant(_,
    /// false)`) should remove that identity's TILE outright, not just clear
    /// its video/screen-share track. `true` exactly when the WS roster
    /// doesn't currently claim this identity as a member — any tile for
    /// them only exists because `mergeSfuOnlyParticipants` synthesized it,
    /// so no future roster broadcast is coming to clean it up. This closes
    /// the original "KNOWN RESIDUAL": a synthesized tile used to outlive
    /// its own participant's departure, and if they were also the LAST
    /// participant, no further roster broadcast ever arrived to remove it
    /// — the tile stayed forever.
    ///
    /// `false` when the roster still lists them: a single LiveKit
    /// disconnect signal could be a transient SFU reconnect rather than a
    /// real departure, so the tile stays and only the stale tracks are
    /// cleared — the roster's own next broadcast (a plain `list.map`
    /// replace) is what actually removes it, same as it always has for a
    /// roster-known departure.
    static func shouldRemoveTileOnDisconnect(
        identity: String,
        wsRosterIds: Set<String>
    ) -> Bool {
        !wsRosterIds.contains(identity)
    }

    /// Updates the quarantine set on every fresh WS roster broadcast.
    /// "Quarantined" means the server just told us — by omission, a full
    /// roster snapshot that no longer lists them — that this identity
    /// left, while LiveKit itself still says they're present
    /// (`sfuPresentIdentities`): the roster-then-LiveKit ordering. A
    /// quarantined identity is only ever cleared by a FRESH LiveKit
    /// connect for that identity (`onSfuParticipant(_, true)`), never by a
    /// later roster broadcast on its own — see the view model's own
    /// wiring, not this function, for that half.
    static func quarantineAfterRosterUpdate(
        currentQuarantine: Set<String>,
        sfuPresentIdentities: Set<String>,
        newRosterIds: Set<String>,
        selfUserId: String
    ) -> Set<String> {
        let justDroppedByServer = sfuPresentIdentities
            .subtracting(newRosterIds)
            .subtracting([selfUserId])
        return currentQuarantine.union(justDroppedByServer)
    }
}

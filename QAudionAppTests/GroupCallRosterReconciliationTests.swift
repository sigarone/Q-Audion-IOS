import XCTest
@testable import QAudionApp

/// W-GRPSFUGHOST follow-up (2026-09-30) — pins the roster-vs-SFU
/// reconciliation rules in `GroupCallRosterReconciliation` against the four
/// scenarios the ghost-participant investigation identified: the two
/// possible orderings of the WS-roster broadcast vs. LiveKit's own
/// `participantDisconnected`/`participantDidConnect` signals, the original
/// W-GRPSFUGHOST repro, and the "last participant leaves" case where no
/// further roster broadcast is ever coming to clean up a stale tile.
///
/// NOTE (not yet wired into a build target): same gap
/// `ConnectionStatusBannerPolicyTests`/`HeroPresenceLabelTests` already
/// document — this repo has no `QAudionAppTests` XCTest target in
/// `QAudionApp/project.yml` today, only `QAudionEngine` ships a runnable
/// `swift test` / `xcodebuild test` harness. Written against that gap (no
/// macOS/Xcode/swift toolchain available in this session to validate a
/// project.yml change) so wiring it in later is a small, mechanical
/// addition.
final class GroupCallRosterReconciliationTests: XCTestCase {

    private let selfId = "self-user-id"

    // MARK: - Original W-GRPSFUGHOST case

    /// The bug this whole mechanism exists to fix (live repro DC7D18B9):
    /// LiveKit says an identity is a real room member, the WS roster has
    /// NEVER listed them (not a departure — they were simply never
    /// introduced), and nothing is quarantining them — the tile must be
    /// synthesized and stay.
    func test_presentInLiveKitNeverInRoster_tileStays() {
        let toSynthesize = GroupCallRosterReconciliation.identitiesToSynthesize(
            sfuPresentIdentities: ["ghost-peer"],
            knownParticipantIds: [],
            quarantined: [],
            selfUserId: selfId
        )
        XCTAssertEqual(toSynthesize, ["ghost-peer"])
    }

    /// Our own identity must never be synthesized as a "ghost" tile even if
    /// it somehow ended up in `sfuPresentIdentities` — `list.map` (the real
    /// roster path) already owns the self tile.
    func test_selfIdentity_neverSynthesized() {
        let toSynthesize = GroupCallRosterReconciliation.identitiesToSynthesize(
            sfuPresentIdentities: [selfId, "ghost-peer"],
            knownParticipantIds: [],
            quarantined: [],
            selfUserId: selfId
        )
        XCTAssertEqual(toSynthesize, ["ghost-peer"])
    }

    // MARK: - roster-then-LiveKit (quarantine)

    /// The server's departure signal (a roster broadcast that stops
    /// listing a peer) arrives BEFORE LiveKit's own `participantDisconnected`
    /// — the mirror ordering of the original bug. Without quarantine,
    /// `identitiesToSynthesize` would immediately resurrect a ghost tile
    /// for someone the server just told us left, off the stale
    /// `sfuPresentIdentities` entry LiveKit hasn't caught up on yet.
    func test_rosterThenLiveKit_quarantinesAndBlocksResynthesis() {
        let sfuPresent: Set<String> = ["peer-x"]
        let newRoster: Set<String> = [selfId] // server's new snapshot already dropped peer-x

        let quarantine = GroupCallRosterReconciliation.quarantineAfterRosterUpdate(
            currentQuarantine: [],
            sfuPresentIdentities: sfuPresent,
            newRosterIds: newRoster,
            selfUserId: selfId
        )
        XCTAssertTrue(quarantine.contains("peer-x"))

        let toSynthesize = GroupCallRosterReconciliation.identitiesToSynthesize(
            sfuPresentIdentities: sfuPresent,
            knownParticipantIds: newRoster,
            quarantined: quarantine,
            selfUserId: selfId
        )
        XCTAssertTrue(toSynthesize.isEmpty,
                       "a peer the server just dropped must not be resurrected off a stale LiveKit-present entry")
    }

    /// Quarantine is only lifted by a FRESH LiveKit connect for that same
    /// identity — never by the passage of time or an unrelated roster
    /// broadcast. This is the view model's own responsibility
    /// (`onSfuParticipant(_, true)` removing the identity from
    /// `quarantinedIdentities`), but the pure function's OWN contract is
    /// that a caller-cleared quarantine set behaves exactly like one that
    /// was never quarantined.
    func test_quarantineLiftedExternally_allowsResynthesis() {
        let sfuPresent: Set<String> = ["peer-x"]
        var quarantine = GroupCallRosterReconciliation.quarantineAfterRosterUpdate(
            currentQuarantine: [],
            sfuPresentIdentities: sfuPresent,
            newRosterIds: [selfId],
            selfUserId: selfId
        )
        XCTAssertTrue(quarantine.contains("peer-x"))

        // Simulates `onSfuParticipant("peer-x", true)` clearing quarantine
        // on a fresh LiveKit reconnect.
        quarantine.remove("peer-x")

        let toSynthesize = GroupCallRosterReconciliation.identitiesToSynthesize(
            sfuPresentIdentities: sfuPresent,
            knownParticipantIds: [selfId],
            quarantined: quarantine,
            selfUserId: selfId
        )
        XCTAssertEqual(toSynthesize, ["peer-x"])
    }

    // MARK: - LiveKit-then-roster (disconnect-tile removal)

    /// The ordinary ordering for a real, roster-known participant: LiveKit
    /// fires `participantDisconnected` first, and the WS roster hasn't
    /// caught up yet (its last snapshot still lists them). A single LiveKit
    /// disconnect signal could be a transient SFU reconnect rather than a
    /// real departure, so the tile must survive until the roster's own next
    /// broadcast decides.
    func test_liveKitThenRoster_tileSurvivesUntilRosterCatchesUp() {
        let shouldRemove = GroupCallRosterReconciliation.shouldRemoveTileOnDisconnect(
            identity: "peer-y",
            wsRosterIds: ["peer-y", selfId]
        )
        XCTAssertFalse(shouldRemove)
    }

    // MARK: - Last participant leaves

    /// The original "KNOWN RESIDUAL" this follow-up closes: a ghost tile
    /// (synthesized purely from LiveKit presence, never in the WS roster)
    /// whose participant then disconnects. With nothing else in the call,
    /// no further roster broadcast is ever coming to remove the tile —
    /// `shouldRemoveTileOnDisconnect` must say to remove it immediately, so
    /// only the local "Tu" tile remains.
    func test_lastParticipantLeaves_onlySelfTileRemains() {
        var participantIds: Set<String> = [selfId, "ghost-peer"]
        let wsRosterIds: Set<String> = [selfId] // the ghost never appeared in the server roster

        let shouldRemove = GroupCallRosterReconciliation.shouldRemoveTileOnDisconnect(
            identity: "ghost-peer",
            wsRosterIds: wsRosterIds
        )
        XCTAssertTrue(shouldRemove)

        if shouldRemove {
            participantIds.remove("ghost-peer")
        }
        XCTAssertEqual(participantIds, [selfId])
    }

    /// A roster-known participant leaving (present in `wsRosterIds`) must
    /// NOT be torn down straight from the disconnect handler — this is the
    /// pre-existing, correct behavior for the common case (the roster's own
    /// next `group_call_update` removes them via `list.map`), and this
    /// follow-up must not regress it.
    func test_rosterKnownParticipantLeaves_tileNotRemovedByDisconnectAlone() {
        let shouldRemove = GroupCallRosterReconciliation.shouldRemoveTileOnDisconnect(
            identity: "peer-known",
            wsRosterIds: ["peer-known", selfId]
        )
        XCTAssertFalse(shouldRemove)
    }
}

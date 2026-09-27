import XCTest
@testable import QAudionEngine

/// W-CALLERUNMUTELOST (2026-09-27) — regression tests for the native
/// audio-srtp caller/callee mic-stuck-muted bug: an answer racing this
/// device's own `QAudionPeerConnection` construction reached a controller
/// whose `peerConnection` was still `nil`, was silently dropped, and the
/// mic stayed muted for the whole call. See `NativeSenderMuteDecisions`'s
/// own doc for the full trace.
///
/// Pure decision, no WebRTC import: runs on CI without the WebRTC binary.
final class NativeSenderMuteDecisionsTests: XCTestCase {

    private typealias Sut = NativeSenderMuteDecisions
    private typealias Latch = NativeSenderMuteDecisions.NativeSenderMuteLatch

    // MARK: - shouldMute truth table

    /// Every one of the 8 input combinations, spelled out — not a loop —
    /// so a future change to the formula that silently flips one row shows
    /// up as a named failure instead of a generic loop failure.
    func testShouldMuteTruthTable() {
        XCTAssertTrue(Sut.shouldMute(peerAnswered: false, userMuted: false, fallbackActive: false), "not answered yet -> muted")
        XCTAssertTrue(Sut.shouldMute(peerAnswered: false, userMuted: true, fallbackActive: false))
        XCTAssertTrue(Sut.shouldMute(peerAnswered: false, userMuted: false, fallbackActive: true))
        XCTAssertTrue(Sut.shouldMute(peerAnswered: false, userMuted: true, fallbackActive: true))
        XCTAssertTrue(Sut.shouldMute(peerAnswered: true, userMuted: true, fallbackActive: false), "user muted -> muted regardless of answer")
        XCTAssertTrue(Sut.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: true), "fallback active -> muted regardless of answer")
        XCTAssertTrue(Sut.shouldMute(peerAnswered: true, userMuted: true, fallbackActive: true))
        XCTAssertFalse(Sut.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: false), "the only unmuted combination: answered, not user-muted, no fallback")
    }

    // MARK: - trackEnabledAfterRequest

    func testMuteRequestAlwaysAppliesImmediately() {
        XCTAssertEqual(Sut.trackEnabledAfterRequest(muted: true, senderCryptorAttached: false), false)
        XCTAssertEqual(Sut.trackEnabledAfterRequest(muted: true, senderCryptorAttached: true), false)
    }

    /// THE FIX's other half (F2): an unmute before the cryptor is
    /// confirmed attached must NOT touch the track — enabling a
    /// pre-attached, cryptor-less track would send plaintext audio.
    func testUnmuteBeforeCryptorAttachOnlyLatchesNoTrackTouch() {
        XCTAssertNil(Sut.trackEnabledAfterRequest(muted: false, senderCryptorAttached: false))
    }

    func testUnmuteAfterCryptorAttachEnablesTheTrack() {
        XCTAssertEqual(Sut.trackEnabledAfterRequest(muted: false, senderCryptorAttached: true), true)
    }

    // MARK: - NativeSenderMuteLatch sequences

    /// THE REGRESSION's exact ordering: controller/latch created (muted by
    /// default) -> the answer arrives and requests unmute WHILE no
    /// PeerConnection/cryptor exists yet (must only latch) -> the
    /// PeerConnection is finally built and inherits the latched intent ->
    /// its cryptor attaches. The track must end up ENABLED — this is
    /// exactly the case that silently dropped the unmute before this fix.
    func testCallerCalleeRaceRegressionEndsUpUnmuted() {
        var controllerLatch = Latch()   // fresh controller: muted by default
        XCTAssertTrue(controllerLatch.wantMuted)

        // The answer races ahead of this device's own PeerConnection
        // construction — no PeerConnection/cryptor exists yet.
        let duringRaceApply = controllerLatch.request(false)
        XCTAssertNil(duringRaceApply, "no PeerConnection yet — must only latch, never touch a track")
        XCTAssertFalse(controllerLatch.wantMuted, "the intent itself must still be recorded")

        // The PeerConnection finishes construction a moment later and
        // inherits the latched intent (a fresh per-PeerConnection latch,
        // cryptor-attach state reset — mirrors `QAudionWebRtcCallController
        // .peerConnection`'s `didSet`).
        var pcLatch = Latch(wantMuted: controllerLatch.valueForNewPeerConnection, senderCryptorAttached: false)
        XCTAssertFalse(pcLatch.wantMuted, "the new PeerConnection must inherit \"unmuted\", not its own hardcoded default")

        // The sender cryptor attaches shortly after (activateNativeAudioSrtp).
        let afterCryptorAttach = pcLatch.senderCryptorDidAttach()
        XCTAssertTrue(afterCryptorAttach, "THE FIX: the track ends up enabled instead of staying muted for the whole call")
    }

    /// The good-call ordering (every other call in the same dataset):
    /// PeerConnection exists well before the answer. Cryptor attaches
    /// first (track stays muted — not answered yet), then the answer
    /// arrives and unmutes immediately since the cryptor is already there.
    func testNormalOrderingPeerConnectionThenCryptorThenAnswer() {
        var latch = Latch()
        let atActivation = latch.senderCryptorDidAttach()
        XCTAssertFalse(atActivation, "cryptor attached but not answered yet — must stay muted")

        let atAnswer = latch.request(false)
        XCTAssertEqual(atAnswer, true, "cryptor already attached — unmute applies immediately")
    }

    /// A call that is never answered (missed/declined) must never unmute,
    /// however long the cryptor has been attached.
    func testNeverAnsweredStaysMuted() {
        var latch = Latch()
        _ = latch.senderCryptorDidAttach()
        XCTAssertTrue(latch.wantMuted)
        // No `request(false)` ever arrives — nothing left to assert beyond
        // the latch itself never having moved off its muted default.
    }

    /// The user mutes WHILE ringing (before either side's PeerConnection
    /// necessarily has a cryptor), then the call is answered. The
    /// CallService-level formula (`shouldMute`) must keep the sender muted
    /// through the whole sequence — this is exercised at the
    /// `NativeSenderMuteLatch` level via the two `request` calls
    /// `CallService.reapplyNativeSenderMute` would issue.
    func testUserMutedWhileRingingThenAnsweredStaysMuted() {
        var latch = Latch(wantMuted: Sut.shouldMute(peerAnswered: false, userMuted: true, fallbackActive: false))
        XCTAssertTrue(latch.wantMuted)
        _ = latch.senderCryptorDidAttach()   // cryptor attaches while still ringing
        XCTAssertTrue(latch.wantMuted, "cryptor attach alone must not unmute")

        // Answer arrives; CallService recomputes with the SAME userMuted=true.
        let applied = latch.request(Sut.shouldMute(peerAnswered: true, userMuted: true, fallbackActive: false))
        XCTAssertEqual(applied, false, "answered, but the user's own mute must still win")
    }

    /// The SRTP-relay fallback owning the mic must force mute regardless
    /// of `peerAnswered`/`userMuted`.
    func testFallbackActiveForcesMuted() {
        XCTAssertTrue(Sut.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: true))
        var latch = Latch(wantMuted: false, senderCryptorAttached: true)   // was unmuted, mid-call
        let applied = latch.request(Sut.shouldMute(peerAnswered: true, userMuted: false, fallbackActive: true))
        XCTAssertEqual(applied, false, "fallback engaging must release/mute the native sender immediately")
    }

    /// A PeerConnection is replaced mid-call (video-upgrade rebuild, or a
    /// future retry path) while the sender was already legitimately
    /// unmuted. The NEW PeerConnection's latch must inherit that same
    /// intent — not silently revert to muted — and, because its own
    /// cryptor has not attached yet, must not touch a track until it does.
    func testPeerConnectionReplacedMidCallInheritsLastValue() {
        var oldPcLatch = Latch(wantMuted: false, senderCryptorAttached: true)   // unmuted, mid-call
        XCTAssertFalse(oldPcLatch.wantMuted)

        var newPcLatch = Latch(wantMuted: oldPcLatch.valueForNewPeerConnection, senderCryptorAttached: false)
        XCTAssertFalse(newPcLatch.wantMuted, "the replacement must inherit \"unmuted\", not reset to muted")

        // Applying that inherited intent to the brand new (cryptor-less)
        // PeerConnection must not enable the track yet.
        let immediateApply = NativeSenderMuteDecisions.trackEnabledAfterRequest(
            muted: newPcLatch.wantMuted, senderCryptorAttached: newPcLatch.senderCryptorAttached)
        XCTAssertNil(immediateApply, "no cryptor on the new PeerConnection yet — must not enable")

        // Its cryptor attaches a moment later — NOW it applies.
        let afterAttach = newPcLatch.senderCryptorDidAttach()
        XCTAssertTrue(afterAttach)
    }
}

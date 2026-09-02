import XCTest
@testable import QAudionEngine

/// W-CKHOLD (2026-09-02) — pins the pure local-video decision `AppState`
/// acts on for B5 (`CXSetHeldCallAction`), without a live CallKit provider
/// or capture session. Evidence: audit memory
/// `reference_ios_stability_audit_2026_09_01`, P2.
final class CallHoldPolicyTests: XCTestCase {

    private typealias Policy = CallHoldPolicy

    // MARK: - Group calls: always a no-op

    /// A group call's video belongs to the LiveKit SFU room; every other
    /// parameter must be ignored once `isGroupCall` is true (W-GRPVPIO-CRASH
    /// — routing a group call through the legacy 1:1 pipeline crashed two
    /// devices before, so this is not a case to guess at).
    func test_groupCall_isAlwaysANoOp_regardlessOfOtherInputs() {
        for isOnHold in [true, false] {
            for isVideoCall in [true, false] {
                for alreadyPaused in [true, false] {
                    for priorHold in [true, false] {
                        XCTAssertEqual(
                            Policy.videoAction(
                                isOnHold: isOnHold, isGroupCall: true,
                                isVideoCall: isVideoCall,
                                localVideoAlreadyPaused: alreadyPaused,
                                videoPausedByPriorHold: priorHold),
                            .none)
                    }
                }
            }
        }
    }

    // MARK: - Hold engages (isOnHold: true)

    /// Audio-only call: never touches video.
    func test_hold_audioOnlyCall_neverTouchesVideo() {
        let action = Policy.videoAction(
            isOnHold: true, isGroupCall: false,
            isVideoCall: false, localVideoAlreadyPaused: false,
            videoPausedByPriorHold: false)
        XCTAssertFalse(action.pauseLocalVideo)
        XCTAssertFalse(action.resumeLocalVideo)
    }

    /// Video call, camera currently ON: hold pauses it.
    func test_hold_videoCallWithCameraOn_pausesVideo() {
        let action = Policy.videoAction(
            isOnHold: true, isGroupCall: false,
            isVideoCall: true, localVideoAlreadyPaused: false,
            videoPausedByPriorHold: false)
        XCTAssertTrue(action.pauseLocalVideo)
        XCTAssertFalse(action.resumeLocalVideo)
    }

    /// Video call, camera the USER already turned off: hold must not claim
    /// credit for pausing it (so a later resume does not wrongly re-enable
    /// a camera the user deliberately left off).
    func test_hold_videoCallWithCameraAlreadyOff_doesNotClaimTheVideoPause() {
        let action = Policy.videoAction(
            isOnHold: true, isGroupCall: false,
            isVideoCall: true, localVideoAlreadyPaused: true,
            videoPausedByPriorHold: false)
        XCTAssertFalse(action.pauseLocalVideo)
        XCTAssertFalse(action.resumeLocalVideo)
    }

    // MARK: - Hold releases (isOnHold: false)

    /// Resume un-pauses video ONLY when the hold itself is what paused it.
    func test_resume_resumesVideoOnlyWhenTheHoldPausedIt() {
        let resumed = Policy.videoAction(
            isOnHold: false, isGroupCall: false,
            isVideoCall: true, localVideoAlreadyPaused: false,
            videoPausedByPriorHold: true)
        XCTAssertTrue(resumed.resumeLocalVideo)

        let untouched = Policy.videoAction(
            isOnHold: false, isGroupCall: false,
            isVideoCall: true, localVideoAlreadyPaused: false,
            videoPausedByPriorHold: false)
        XCTAssertFalse(untouched.resumeLocalVideo)
    }

    /// Resume never pauses video — `pauseLocalVideo` is exclusive to the
    /// `isOnHold: true` side regardless of the other flags.
    func test_resume_neverPausesVideo() {
        for isVideoCall in [true, false] {
            for alreadyPaused in [true, false] {
                for priorHold in [true, false] {
                    let action = Policy.videoAction(
                        isOnHold: false, isGroupCall: false,
                        isVideoCall: isVideoCall,
                        localVideoAlreadyPaused: alreadyPaused,
                        videoPausedByPriorHold: priorHold)
                    XCTAssertFalse(action.pauseLocalVideo)
                }
            }
        }
    }
}

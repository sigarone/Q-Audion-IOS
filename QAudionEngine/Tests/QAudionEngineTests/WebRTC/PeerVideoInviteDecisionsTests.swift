import XCTest
@testable import QAudionEngine

/// W-VIDPARITY — branch coverage for the peer-video-invite banner, the
/// local-camera-enable routing (BUG (C) fix), and the
/// `call_video_pause_request` receive filter. Pure decisions, no WebRTC
/// import: runs on CI without the WebRTC binary.
final class PeerVideoInviteDecisionsTests: XCTestCase {

    private typealias Sut = PeerVideoInviteDecisions

    // MARK: - shouldShowPeerVideoInviteBanner

    func testBannerShowsWhenPeerSendsAndWeDoNot() {
        XCTAssertTrue(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: true, peerCameraSending: true, localCameraSending: false,
            peerScreenShareActive: false, dismissedThisCall: false, pendingIncomingUpgrade: false))
    }

    func testBannerHiddenWhenNotAVideoCall() {
        XCTAssertFalse(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: false, peerCameraSending: true, localCameraSending: false,
            peerScreenShareActive: false, dismissedThisCall: false, pendingIncomingUpgrade: false))
    }

    func testBannerHiddenWhenPeerNotSending() {
        XCTAssertFalse(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: true, peerCameraSending: false, localCameraSending: false,
            peerScreenShareActive: false, dismissedThisCall: false, pendingIncomingUpgrade: false))
    }

    func testBannerHiddenWhenWeAreAlreadySending() {
        XCTAssertFalse(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: true, peerCameraSending: true, localCameraSending: true,
            peerScreenShareActive: false, dismissedThisCall: false, pendingIncomingUpgrade: false))
    }

    func testBannerHiddenDuringScreenShare() {
        XCTAssertFalse(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: true, peerCameraSending: true, localCameraSending: false,
            peerScreenShareActive: true, dismissedThisCall: false, pendingIncomingUpgrade: false))
    }

    func testBannerHiddenOnceDismissedThisCall() {
        XCTAssertFalse(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: true, peerCameraSending: true, localCameraSending: false,
            peerScreenShareActive: false, dismissedThisCall: true, pendingIncomingUpgrade: false))
    }

    /// Never stack this banner on top of the existing consent dialog.
    func testBannerHiddenWhilePendingIncomingUpgradeConsentIsUp() {
        XCTAssertFalse(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: true, peerCameraSending: true, localCameraSending: false,
            peerScreenShareActive: false, dismissedThisCall: false, pendingIncomingUpgrade: true))
    }

    /// A dismiss must survive a lane flap (peer pauses then resumes) —
    /// this is a property of the CALLER (AppState never resets the flag
    /// on a lane change), but pin here that the pure function itself
    /// takes `dismissedThisCall` at face value with no other override.
    func testDismissedWinsEvenWhenEveryOtherConditionReSaysShow() {
        XCTAssertFalse(Sut.shouldShowPeerVideoInviteBanner(
            isVideoCall: true, peerCameraSending: true, localCameraSending: false,
            peerScreenShareActive: false, dismissedThisCall: true, pendingIncomingUpgrade: false))
    }

    // MARK: - localCameraEnableRoute (BUG (C))

    func testNoVideoYetRoutesToUpgradeFromAudio() {
        XCTAssertEqual(
            Sut.localCameraEnableRoute(isVideoCall: false, pipelineIsExternalSource: false),
            .upgradeFromAudio)
        // pipelineIsExternalSource is irrelevant when there's no video call at all.
        XCTAssertEqual(
            Sut.localCameraEnableRoute(isVideoCall: false, pipelineIsExternalSource: true),
            .upgradeFromAudio)
    }

    /// THE BUG. A video call answered `.receiveOnly` has `isVideoCall == true`
    /// and an `.external` pipeline — this must promote, NOT resume (a plain
    /// resume on an `.external` pipeline is the silent no-op bug report) and
    /// NOT upgradeFromAudio (`upgradeToVideo()`'s own `!isVideoCall` guard
    /// makes that a no-op too).
    func testVideoCallWithExternalPipelineRoutesToPromoteReceiveOnly() {
        XCTAssertEqual(
            Sut.localCameraEnableRoute(isVideoCall: true, pipelineIsExternalSource: true),
            .promoteReceiveOnly)
    }

    func testVideoCallWithRealCameraPipelineRoutesToResumeCapture() {
        XCTAssertEqual(
            Sut.localCameraEnableRoute(isVideoCall: true, pipelineIsExternalSource: false),
            .resumeCapture)
    }

    // MARK: - shouldHonorVideoPauseRequest

    func testHonoredWhenRequestMatchesActiveCall() {
        XCTAssertTrue(Sut.shouldHonorVideoPauseRequest(activeCallId: "abc-123", requestCallId: "abc-123"))
    }

    func testHonoredCaseInsensitively() {
        XCTAssertTrue(Sut.shouldHonorVideoPauseRequest(activeCallId: "ABC-123", requestCallId: "abc-123"))
        XCTAssertTrue(Sut.shouldHonorVideoPauseRequest(activeCallId: "abc-123", requestCallId: "ABC-123"))
    }

    func testNotHonoredWhenNoActiveCall() {
        XCTAssertFalse(Sut.shouldHonorVideoPauseRequest(activeCallId: nil, requestCallId: "abc-123"))
    }

    func testNotHonoredWhenActiveCallIdIsEmpty() {
        XCTAssertFalse(Sut.shouldHonorVideoPauseRequest(activeCallId: "", requestCallId: "abc-123"))
    }

    func testNotHonoredWhenRequestCallIdIsEmpty() {
        XCTAssertFalse(Sut.shouldHonorVideoPauseRequest(activeCallId: "abc-123", requestCallId: ""))
    }

    func testNotHonoredForAForeignCallId() {
        XCTAssertFalse(Sut.shouldHonorVideoPauseRequest(activeCallId: "abc-123", requestCallId: "xyz-999"))
    }
}

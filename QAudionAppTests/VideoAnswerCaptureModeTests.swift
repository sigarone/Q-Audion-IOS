import XCTest
@testable import QAudionApp

/// W-VIDPRIVACY — pins evaluateVideoAnswerCaptureMode, the decision
/// AppState.performAcceptIncoming now uses to gate the callee's video
/// pipeline. Replaces the unconditional start that used to run at
/// offer-receipt time (W-CAMARMEARLY, Task 1).
///
/// NOTE (not yet wired into a build target): this repo has no
/// `QAudionAppTests` XCTest target in `QAudionApp/project.yml` today — same
/// disclosed gap as `NoCallInFlightTests.swift`/`PeerTrustEvaluatorTests.swift`
/// /`LocalCallerIdSettingsTests.swift`. Written and reasoned through without a
/// local Swift/Xcode toolchain to compile it; wiring the target in is a
/// separate, mechanical `project.yml` change.
final class VideoAnswerCaptureModeTests: XCTestCase {
    func test_audioCall_neverCaptures() {
        XCTAssertEqual(evaluateVideoAnswerCaptureMode(hasVideo: false, acceptWithoutVideo: false), .none)
        XCTAssertEqual(evaluateVideoAnswerCaptureMode(hasVideo: false, acceptWithoutVideo: true), .none)
    }
    func test_videoCall_acceptedWithVideo_opensCamera() {
        XCTAssertEqual(evaluateVideoAnswerCaptureMode(hasVideo: true, acceptWithoutVideo: false), .cameraConsented)
    }
    func test_videoCall_acceptedWithoutVideo_isReceiveOnly() {
        XCTAssertEqual(evaluateVideoAnswerCaptureMode(hasVideo: true, acceptWithoutVideo: true), .receiveOnly)
    }
}

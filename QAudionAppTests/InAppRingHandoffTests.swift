import SwiftUI
import XCTest
@testable import QAudionApp

/// When an incoming call that rings in the app alone is reported to CallKit as the phone window changes phase
/// (`WsIncomingPresentation.handsOffToCallKit`).
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-ci.yml`.
final class InAppRingHandoffTests: XCTestCase {

    func test_ringingInAppCall_isHandedOverWhenTheWindowIsInTheBackground() {
        XCTAssertTrue(WsIncomingPresentation.inAppOnly.handsOffToCallKit(
            scene: .background, reportedToCallKit: false, callState: .ringing))
    }

    func test_inactiveAndActiveWindow_keepTheCallInTheApp() {
        // `.inactive` is also what Control Center and the app switcher produce.
        for scene in [ScenePhase.inactive, ScenePhase.active] {
            XCTAssertFalse(WsIncomingPresentation.inAppOnly.handsOffToCallKit(
                scene: scene, reportedToCallKit: false, callState: .ringing))
        }
    }

    func test_callPresentedByCallKit_isNeverHandedOver() {
        XCTAssertFalse(WsIncomingPresentation.callKit.handsOffToCallKit(
            scene: .background, reportedToCallKit: false, callState: .ringing))
    }

    func test_callCallKitAlreadyHas_isNotReportedAgain() {
        XCTAssertFalse(WsIncomingPresentation.inAppOnly.handsOffToCallKit(
            scene: .background, reportedToCallKit: true, callState: .ringing))
    }

    func test_callThatIsNotRinging_isNotHandedOver() {
        let notRinging: [CallState] = [.idle, .connecting, .active, .encrypted, .ended]
        for state in notRinging {
            XCTAssertFalse(WsIncomingPresentation.inAppOnly.handsOffToCallKit(
                scene: .background, reportedToCallKit: false, callState: state))
        }
    }
}

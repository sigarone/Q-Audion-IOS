import XCTest
@testable import QAudionEngine

/// F-02 — the distinction the old code did not make.
final class VideoE2eeGateTests: XCTestCase {

    func testDefersUntilThePeerHasBeenHeardFrom() {
        XCTAssertEqual(.`defer`, VideoE2eeGate.decide(
            hasSessionKey: true, peerHeardFrom: false, useSFrame: false))
        XCTAssertEqual(.`defer`, VideoE2eeGate.decide(
            hasSessionKey: false, peerHeardFrom: false, useSFrame: true))
    }

    func testDefersWhileTheSessionKeyIsStillMissing() {
        XCTAssertEqual(.`defer`, VideoE2eeGate.decide(
            hasSessionKey: false, peerHeardFrom: true, useSFrame: true))
    }

    func testFailsClosedWhenThePeerDidNotAgreeToFrameEncryption() {
        XCTAssertEqual(.failClosed, VideoE2eeGate.decide(
            hasSessionKey: true, peerHeardFrom: true, useSFrame: false))
    }

    /// The ordering case, and the reason `useSFrame` is checked before the key: a
    /// declined peer must be refused even on the path where the key never lands,
    /// or a downgrade quietly becomes an indefinite deferral.
    func testARefusalIsNotDowngradedToADeferralByAMissingKey() {
        XCTAssertEqual(.failClosed, VideoE2eeGate.decide(
            hasSessionKey: false, peerHeardFrom: true, useSFrame: false))
    }

    func testInstallsOnlyWhenEverythingIsSatisfied() {
        XCTAssertEqual(.install, VideoE2eeGate.decide(
            hasSessionKey: true, peerHeardFrom: true, useSFrame: true))
    }

    /// The property, not an implementation detail: "not ready" and "refused" must
    /// never collapse back into one answer.
    func testNotReadyAndRefusedAreNeverTheSameAnswer() {
        XCTAssertNotEqual(
            VideoE2eeGate.decide(hasSessionKey: false, peerHeardFrom: true, useSFrame: true),
            VideoE2eeGate.decide(hasSessionKey: false, peerHeardFrom: true, useSFrame: false))
    }
}

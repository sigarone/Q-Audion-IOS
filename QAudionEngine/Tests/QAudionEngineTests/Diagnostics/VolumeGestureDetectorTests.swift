import XCTest
@testable import QAudionEngine

/// W-BUGREPPHANTOM (2026-10-02): the bug-report volume gesture must fire on two real
/// button presses and never on the output-volume changes of an audio route change or a
/// call transition (the 1:1 -> group hand-over opened the sheet by itself).
final class VolumeGestureDetectorTests: XCTestCase {

    private let step: Float = 1.0 / 16.0

    func testUpThenDownWithin400msIsTheGesture() {
        var detector = VolumeGestureDetector()
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 10.0), .pressed)
        XCTAssertEqual(detector.observe(old: 0.5 + step, new: 0.5, at: 10.2), .gesture(deltaMs: 200))
    }

    func testTwoPressesInTheSameDirectionWithin600msAreTheGesture() {
        var detector = VolumeGestureDetector()
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 - step, at: 10.0), .pressed)
        XCTAssertEqual(detector.observe(old: 0.5 - step, new: 0.5 - 2 * step, at: 10.5), .gesture(deltaMs: 500))
    }

    func testOppositePressesFurtherApartThan400msAreNotTheGesture() {
        var detector = VolumeGestureDetector()
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 10.0), .pressed)
        XCTAssertEqual(detector.observe(old: 0.5 + step, new: 0.5, at: 10.5), .pressed)
    }

    func testAChangeThatDoesNotChangeTheVolumeIsNotAPress() {
        var detector = VolumeGestureDetector()
        XCTAssertEqual(detector.observe(old: 1.0, new: 1.0, at: 10.0), .ignored(.noChange))
        // The old detector read an equal pair as a "down" press: two of them were a gesture.
        XCTAssertEqual(detector.observe(old: 1.0, new: 1.0, at: 10.1), .ignored(.noChange))
    }

    func testARouteSwitchJumpIsNotAPress() {
        var detector = VolumeGestureDetector()
        // Report 93005f73: earpiece 1.0 <-> loudspeaker 0.5 around the hand-over.
        XCTAssertEqual(detector.observe(old: 0.5, new: 1.0, at: 50.29), .ignored(.notAStep))
        XCTAssertEqual(detector.observe(old: 1.0, new: 0.5, at: 50.30), .ignored(.notAStep))
    }

    func testTheHandOverTransitionSilencesEveryChangeForItsQuietPeriod() {
        var detector = VolumeGestureDetector()
        detector.noteSystemVolumeChange(at: 49.2, reason: .transition, period: VolumeGestureDetector.transitionQuietPeriod)
        // Even changes that look like single steps.
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 50.29), .ignored(.transition))
        XCTAssertEqual(detector.observe(old: 0.5 + step, new: 0.5, at: 50.30), .ignored(.transition))
        // After the quiet period the buttons work again.
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 53.0), .pressed)
        XCTAssertEqual(detector.observe(old: 0.5 + step, new: 0.5, at: 53.2), .gesture(deltaMs: 200))
    }

    func testARouteChangeDropsAPressDeliveredJustBeforeIt() {
        var detector = VolumeGestureDetector()
        // The KVO of a route change can arrive before the route-change notification.
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 10.0), .pressed)
        detector.noteSystemVolumeChange(at: 10.05, reason: .routeChange)
        XCTAssertEqual(detector.observe(old: 0.5 + step, new: 0.5, at: 10.2), .ignored(.routeChange))
        // A press after the quiet period does not pair with the dropped one.
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 11.6), .pressed)
    }

    func testTheGestureCoolsDownForFiveSeconds() {
        var detector = VolumeGestureDetector()
        _ = detector.observe(old: 0.5, new: 0.5 + step, at: 10.0)
        XCTAssertEqual(detector.observe(old: 0.5 + step, new: 0.5, at: 10.1), .gesture(deltaMs: 100))
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 12.0), .ignored(.cooldown))
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 15.2), .pressed)
    }

    func testChangesDeliveredOutOfOrderAreNotAGesture() {
        var detector = VolumeGestureDetector()
        XCTAssertEqual(detector.observe(old: 0.5, new: 0.5 + step, at: 10.0), .pressed)
        XCTAssertEqual(detector.observe(old: 0.5 + step, new: 0.5, at: 9.9), .pressed)
    }

    func testIgnoreReasonCodesAreStable() {
        // Logged as `trig src=1 suppressed=1 why=<n>`: the codes are part of the log format.
        XCTAssertEqual(VolumeGestureDetector.IgnoreReason.cooldown.rawValue, 1)
        XCTAssertEqual(VolumeGestureDetector.IgnoreReason.noChange.rawValue, 2)
        XCTAssertEqual(VolumeGestureDetector.IgnoreReason.notAStep.rawValue, 3)
        XCTAssertEqual(VolumeGestureDetector.IgnoreReason.routeChange.rawValue, 4)
        XCTAssertEqual(VolumeGestureDetector.IgnoreReason.transition.rawValue, 5)
    }
}

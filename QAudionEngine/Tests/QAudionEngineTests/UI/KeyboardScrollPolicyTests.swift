import XCTest
@testable import QAudionEngine

/// Pure decision of the chat "keep the end of the conversation in view while writing" rule.
final class KeyboardScrollPolicyTests: XCTestCase {

    private func input(
        _ trigger: KeyboardScrollTrigger,
        kbBefore: Double = 0, kbAfter: Double = 0,
        composerBefore: Double = 0, composerAfter: Double = 0,
        hasLast: Bool = true, reduceMotion: Bool = false,
        duration: Double? = nil, curve: Int? = nil
    ) -> KeyboardScrollInput {
        KeyboardScrollInput(
            trigger: trigger, keyboardHeightBefore: kbBefore, keyboardHeightAfter: kbAfter,
            composerHeightBefore: composerBefore, composerHeightAfter: composerAfter,
            hasLastMessage: hasLast, reduceMotion: reduceMotion,
            notificationDurationSeconds: duration, notificationCurveRawValue: curve
        )
    }

    /// Settle delay = duration + 0.05; compared with accuracy because of floating point.
    private func assertScroll(
        _ action: KeyboardScrollAction, animation: Double, curve: KeyboardScrollCurve, settle: Double?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case let .scrollToBottom(a, c, s) = action else {
            XCTFail("expected a scroll, got \(action)", file: file, line: line)
            return
        }
        XCTAssertEqual(a, animation, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(c, curve, file: file, line: line)
        if let settle = settle {
            XCTAssertNotNil(s, file: file, line: line)
            XCTAssertEqual(s ?? -1, settle, accuracy: 1e-9, file: file, line: line)
        } else {
            XCTAssertNil(s, file: file, line: line)
        }
    }

    func test_keyboardOpeningScrollsToTheBottomWithTheNotificationDurationAndCurve() {
        let a = KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: 336, duration: 0.35, curve: 2))
        assertScroll(a, animation: 0.35, curve: .easeOut, settle: 0.40)
    }

    func test_keyboardOpeningWithoutAUsableDurationUsesTheDefault() {
        assertScroll(KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: 300)),
                     animation: 0.25, curve: .easeInOut, settle: 0.30)
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            assertScroll(KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: 300, duration: bad)),
                         animation: 0.25, curve: .easeInOut, settle: 0.30)
        }
    }

    func test_aVeryLongReportedDurationIsCapped() {
        assertScroll(KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: 300, duration: 5)),
                     animation: 0.6, curve: .easeInOut, settle: 0.65)
    }

    func test_keyboardOpeningScrollsEvenWhenTheKeyboardWasAlreadyReportedVisible() {
        XCTAssertNotEqual(KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbBefore: 336, kbAfter: 336)), .noScroll)
    }

    func test_unknownOrPrivateKeyboardCurveFallsBackToEaseInOut() {
        XCTAssertEqual(KeyboardScrollCurve.fromUIKit(rawValue: 7), .easeInOut)
        XCTAssertEqual(KeyboardScrollCurve.fromUIKit(rawValue: nil), .easeInOut)
        XCTAssertEqual(KeyboardScrollCurve.fromUIKit(rawValue: 0), .easeInOut)
        XCTAssertEqual(KeyboardScrollCurve.fromUIKit(rawValue: 1), .easeIn)
        XCTAssertEqual(KeyboardScrollCurve.fromUIKit(rawValue: 2), .easeOut)
        XCTAssertEqual(KeyboardScrollCurve.fromUIKit(rawValue: 3), .linear)
    }

    func test_reduceMotionScrollsWithoutAnimation() {
        let k = KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: 336, reduceMotion: true, duration: 0.35))
        assertScroll(k, animation: 0, curve: .easeInOut, settle: 0.40)
        let c = KeyboardScrollPolicy.action(
            for: input(.composerHeightChanged, kbAfter: 336, composerBefore: 40, composerAfter: 60, reduceMotion: true))
        assertScroll(c, animation: 0, curve: .easeOut, settle: nil)
    }

    func test_noLastMessageMeansNothingToScrollTo() {
        XCTAssertEqual(KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: 336, hasLast: false)), .noScroll)
        XCTAssertEqual(
            KeyboardScrollPolicy.action(for: input(.keyboardFrameChanged, kbBefore: 300, kbAfter: 336, hasLast: false)), .noScroll)
        XCTAssertEqual(
            KeyboardScrollPolicy.action(
                for: input(.composerHeightChanged, kbAfter: 336, composerBefore: 40, composerAfter: 60, hasLast: false)),
            .noScroll)
    }

    func test_keyboardHeightChangeFollowsButAnUnchangedHeightDoesNot() {
        // predictive bar / emoji keyboard: taller
        XCTAssertNotEqual(KeyboardScrollPolicy.action(for: input(.keyboardFrameChanged, kbBefore: 291, kbAfter: 336)), .noScroll)
        // shorter, still visible
        XCTAssertNotEqual(KeyboardScrollPolicy.action(for: input(.keyboardFrameChanged, kbBefore: 336, kbAfter: 291)), .noScroll)
        // same height (or sub-point noise): the willShow already did the work
        XCTAssertEqual(KeyboardScrollPolicy.action(for: input(.keyboardFrameChanged, kbBefore: 336, kbAfter: 336)), .noScroll)
        XCTAssertEqual(KeyboardScrollPolicy.action(for: input(.keyboardFrameChanged, kbBefore: 336, kbAfter: 336.4)), .noScroll)
    }

    func test_keyboardHidingNeverScrolls() {
        XCTAssertEqual(KeyboardScrollPolicy.action(for: input(.keyboardFrameChanged, kbBefore: 336, kbAfter: 0)), .noScroll)
        XCTAssertEqual(KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: 0)), .noScroll)
    }

    func test_composerGrowingOrShrinkingWhileTheKeyboardIsUpScrolls() {
        // 1 -> 2 lines
        assertScroll(
            KeyboardScrollPolicy.action(for: input(.composerHeightChanged, kbAfter: 336, composerBefore: 56, composerAfter: 76)),
            animation: 0.15, curve: .easeOut, settle: nil)
        // 5 -> 1 lines (after a send or a delete)
        XCTAssertNotEqual(
            KeyboardScrollPolicy.action(for: input(.composerHeightChanged, kbAfter: 336, composerBefore: 136, composerAfter: 56)),
            .noScroll)
    }

    func test_composerChangeWithoutTheKeyboardOrWithoutARealChangeDoesNothing() {
        XCTAssertEqual(
            KeyboardScrollPolicy.action(for: input(.composerHeightChanged, kbAfter: 0, composerBefore: 56, composerAfter: 76)),
            .noScroll)
        XCTAssertEqual(
            KeyboardScrollPolicy.action(for: input(.composerHeightChanged, kbAfter: 336, composerBefore: 56, composerAfter: 56.3)),
            .noScroll)
    }

    func test_nonFiniteNumbersNeverScroll() {
        XCTAssertEqual(KeyboardScrollPolicy.action(for: input(.keyboardWillShow, kbAfter: .nan)), .noScroll)
        XCTAssertEqual(
            KeyboardScrollPolicy.action(
                for: input(.composerHeightChanged, kbAfter: 336, composerBefore: .infinity, composerAfter: 56)),
            .noScroll)
    }
}

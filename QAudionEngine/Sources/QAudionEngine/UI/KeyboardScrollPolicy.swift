import Foundation

// Chat keyboard follow-the-bottom policy (pure, no UIKit / SwiftUI).
//
// When the keyboard opens, or the composer grows or shrinks while the user types, the message list is squeezed from the
// bottom and the last messages fall out of view. The screens (1:1 and group) listen to the keyboard notifications and to
// the measured composer height, hand the numbers to `KeyboardScrollPolicy.action(for:)` and do what it answers: scroll to
// the last message, with the given animation, or leave the list alone. Nothing else about the scrolling changes (a new
// message while the user reads older ones, a tap on a quote, ...).

/// What woke the policy up.
public enum KeyboardScrollTrigger: Sendable, Equatable {
    /// `keyboardWillShowNotification`.
    case keyboardWillShow
    /// `keyboardWillChangeFrameNotification` (height change, predictive bar, floating <-> docked, hide).
    case keyboardFrameChanged
    /// The measured height of the composer area changed (text going from 1 to more lines or back, reply banner, ...).
    case composerHeightChanged
}

/// Timing curve of the keyboard animation, mapped by the screen onto its own animation type.
public enum KeyboardScrollCurve: Sendable, Equatable {
    case easeInOut
    case easeIn
    case easeOut
    case linear

    /// `UIView.AnimationCurve` raw values: 0 easeInOut, 1 easeIn, 2 easeOut, 3 linear. The keyboard itself reports a private
    /// value (7) that has no public equivalent; it, and anything else unknown, is approximated by easeInOut.
    public static func fromUIKit(rawValue: Int?) -> KeyboardScrollCurve {
        switch rawValue {
        case 1: return .easeIn
        case 2: return .easeOut
        case 3: return .linear
        default: return .easeInOut
        }
    }
}

public struct KeyboardScrollInput: Sendable, Equatable {
    public var trigger: KeyboardScrollTrigger
    /// Keyboard height on screen before / after the event, in points (0 = hidden). For `.composerHeightChanged` only
    /// `keyboardHeightAfter` (the current height) is read.
    public var keyboardHeightBefore: Double
    public var keyboardHeightAfter: Double
    /// Composer height before / after, in points. Read only for `.composerHeightChanged`.
    public var composerHeightBefore: Double
    public var composerHeightAfter: Double
    /// Whether the conversation has a last message to scroll to.
    public var hasLastMessage: Bool
    /// `UIAccessibility.isReduceMotionEnabled`.
    public var reduceMotion: Bool
    /// `UIResponder.keyboardAnimationDurationUserInfoKey` / `...CurveUserInfoKey` of the notification, when there is one.
    public var notificationDurationSeconds: Double?
    public var notificationCurveRawValue: Int?

    public init(
        trigger: KeyboardScrollTrigger,
        keyboardHeightBefore: Double = 0,
        keyboardHeightAfter: Double = 0,
        composerHeightBefore: Double = 0,
        composerHeightAfter: Double = 0,
        hasLastMessage: Bool,
        reduceMotion: Bool,
        notificationDurationSeconds: Double? = nil,
        notificationCurveRawValue: Int? = nil
    ) {
        self.trigger = trigger
        self.keyboardHeightBefore = keyboardHeightBefore
        self.keyboardHeightAfter = keyboardHeightAfter
        self.composerHeightBefore = composerHeightBefore
        self.composerHeightAfter = composerHeightAfter
        self.hasLastMessage = hasLastMessage
        self.reduceMotion = reduceMotion
        self.notificationDurationSeconds = notificationDurationSeconds
        self.notificationCurveRawValue = notificationCurveRawValue
    }
}

public enum KeyboardScrollAction: Sendable, Equatable {
    /// Leave the list where it is.
    case noScroll
    /// Scroll to the last message with its bottom edge at the bottom of the list. `animationSeconds` 0 means no animation
    /// (Reduce Motion). `settleAfterSeconds`, when present, asks for one more scroll without animation after that delay: the
    /// list reaches its final size only while the keyboard animates, so the first scroll may have used the old size.
    case scrollToBottom(animationSeconds: Double, curve: KeyboardScrollCurve, settleAfterSeconds: Double?)
}

public enum KeyboardScrollPolicy {
    /// Height changes smaller than this are noise (rounding of the layout), not a new keyboard / composer size.
    public static let minHeightChange: Double = 1.0
    /// A keyboard shorter than this counts as hidden.
    public static let minVisibleKeyboardHeight: Double = 1.0
    /// Used when the notification carries no usable duration.
    public static let defaultDurationSeconds: Double = 0.25
    /// Animation of the scroll that follows a composer resize.
    public static let composerDurationSeconds: Double = 0.15
    public static let maxDurationSeconds: Double = 0.6
    /// Extra time after the keyboard animation before the settle scroll.
    public static let settleMarginSeconds: Double = 0.05

    public static func action(for input: KeyboardScrollInput) -> KeyboardScrollAction {
        if !input.hasLastMessage { return .noScroll }
        let numbers: [Double] = [
            input.keyboardHeightBefore, input.keyboardHeightAfter,
            input.composerHeightBefore, input.composerHeightAfter,
        ]
        for value in numbers where !value.isFinite { return .noScroll }
        let keyboardVisible = input.keyboardHeightAfter >= minVisibleKeyboardHeight

        switch input.trigger {
        case .keyboardWillShow:
            // Always, even if the list was scrolled up before: the user is about to write and must see the end of the chat.
            if !keyboardVisible { return .noScroll }
            return keyboardAction(for: input)
        case .keyboardFrameChanged:
            if !keyboardVisible { return .noScroll }
            if abs(input.keyboardHeightAfter - input.keyboardHeightBefore) < minHeightChange { return .noScroll }
            return keyboardAction(for: input)
        case .composerHeightChanged:
            // While typing: the composer going from 1 to more lines (or back) squeezes / frees the list from the bottom.
            if !keyboardVisible { return .noScroll }
            if abs(input.composerHeightAfter - input.composerHeightBefore) < minHeightChange { return .noScroll }
            let seconds: Double = input.reduceMotion ? 0 : composerDurationSeconds
            return .scrollToBottom(animationSeconds: seconds, curve: .easeOut, settleAfterSeconds: nil)
        }
    }

    private static func keyboardAction(for input: KeyboardScrollInput) -> KeyboardScrollAction {
        var duration: Double = defaultDurationSeconds
        if let reported = input.notificationDurationSeconds, reported.isFinite, reported > 0 {
            duration = min(maxDurationSeconds, reported)
        }
        let curve = KeyboardScrollCurve.fromUIKit(rawValue: input.notificationCurveRawValue)
        let animation: Double = input.reduceMotion ? 0 : duration
        return .scrollToBottom(
            animationSeconds: animation,
            curve: curve,
            settleAfterSeconds: duration + settleMarginSeconds
        )
    }
}

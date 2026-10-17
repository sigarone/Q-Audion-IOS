import SwiftUI

/// What the user sees while a call is up: the call screen itself, or the rest of the app with the "call in progress" bar
/// on top.
enum CallSurface: Equatable {
    case callScreen
    case appWithBar
}

/// The events that change the "call reduced" state.
enum CallMinimizeEvent: Equatable {
    /// The reduce button of the call screen was tapped.
    case reduceTapped
    /// The "call in progress" bar was tapped: back to the call screen.
    case barTapped
    /// A call starts or ends: no call starts reduced and none stays reduced.
    case callBoundary
    /// A call button was tapped while a call is already up: the new call is refused, and with the call reduced the call
    /// screen comes back instead of the tap doing nothing.
    case newCallRefused
}

/// The rules for reducing a live call to a bar, as pure functions (no views, no `AppState`) so each one can be tested.
///
/// The call itself is not touched: reducing it only changes what is on screen. Audio, CallKit and the audio session stay
/// as they are, and hanging up stays on the red button of the call screen; the bar has no hang-up control.
enum CallMinimizePolicy {

    /// The states in which the call is connected and media flows. Only then can the call be reduced and only then does the
    /// bar show: while dialling, ringing or closing, the user stays on the call screen.
    static func isConnected(_ state: CallState) -> Bool {
        state == .active || state == .encrypted
    }

    /// The reduce button is on the audio call screen, once the call is connected. A video call (or a call where the other
    /// side is sharing their screen) has its own screen and is not reduced for now.
    static func canMinimize(callState: CallState, isVideoCall: Bool, remoteScreenSharing: Bool) -> Bool {
        isConnected(callState) && !isVideoCall && !remoteScreenSharing
    }

    /// Which of the two surfaces to show. The bar needs the call to be reduced AND connected: if the state leaves
    /// "connected" (the call ends, or connects again) the call screen takes its place back, so the user is never left in
    /// the app with no way back to the call and its hang-up button.
    static func surface(isInCall: Bool, minimized: Bool, callState: CallState) -> CallSurface {
        guard isInCall, minimized, isConnected(callState) else { return .callScreen }
        return .appWithBar
    }

    /// The new "call reduced" value after an event. Tapping reduce only counts if the call can be reduced at that moment
    /// (the state may have changed between drawing the button and the tap); going back to the call, and the boundaries of
    /// a call, always clear it.
    static func next(minimized: Bool, event: CallMinimizeEvent, canMinimize: Bool) -> Bool {
        switch event {
        case .reduceTapped:
            return canMinimize ? true : minimized
        case .barTapped, .callBoundary, .newCallRefused:
            return false
        }
    }
}

/// How long a call has lasted, as the bar writes it.
enum CallElapsedText {

    /// `m:ss`, or `h:mm:ss` from one hour. A negative or non-finite value reads as zero.
    static func format(seconds: TimeInterval) -> String {
        let usable: Double = seconds.isFinite && seconds > 0 ? seconds : 0
        let total: Int = Int(min(usable, 1_000_000_000))
        let hours: Int = total / 3600
        let minutes: Int = (total % 3600) / 60
        let secs: Int = total % 60
        let secsText: String = twoDigits(secs)
        if hours > 0 {
            let minutesText: String = twoDigits(minutes)
            return "\(hours):\(minutesText):\(secsText)"
        }
        return "\(minutes):\(secsText)"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}

/// The animation of the swap between the call screen and the bar: none with Reduce Motion on.
enum CallMinimizeAnimation {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.25)
    }
}

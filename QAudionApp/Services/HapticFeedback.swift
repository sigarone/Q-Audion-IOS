import UIKit

/// W114 — centralized haptic feedback for chat-side interactions.
///
/// Wraps `UIImpactFeedbackGenerator` + `UINotificationFeedbackGenerator`
/// behind small-named methods so call sites read intent (`HapticFeedback
/// .messageSent()`) rather than impact-style ceremony. Generators are
/// stateless on iOS so we recreate per-call — the cost is negligible
/// (a few microseconds) and avoids dangling generators surviving the
/// view that triggered them.
///
/// All methods no-op gracefully if the device doesn't support haptics
/// (older iPads, simulator on some macOS versions).
enum HapticFeedback {

    /// W160: master kill-switch read from UserDefaults
    /// `qaudion.haptics.enabled`. Default-on. Settings can flip this
    /// off for accessibility / battery preference; every helper
    /// short-circuits when off.
    private static var isEnabled: Bool {
        let key = "qaudion.haptics.enabled"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Soft tap when a chat message ships successfully.
    static func messageSent() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// Light bump when starting a voice-note recording.
    static func recordingStart() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Medium bump when releasing a voice-note (= sending it).
    static func recordingStop() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Soft tick when toggling a reaction emoji on a bubble.
    static func reactionToggle() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Heavy thud when destructive action fires (delete-for-everyone,
    /// clear history). Different from .warning notification because
    /// the user already confirmed via the menu — this is just the
    /// physical feel of the action landing.
    static func destructiveAction() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    /// Standard error notification on send / receive failure.
    static func sendFailure() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

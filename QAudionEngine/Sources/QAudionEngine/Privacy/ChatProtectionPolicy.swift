import Foundation

/// Decides whether a conversation is "protected" and what the conversation
/// list may show for it. Pure decision logic plus one stored marker; the
/// localized label lives in the app catalog.
///
/// A conversation is protected when the screenshot lock is on and the peer
/// has not granted screenshots, or when it carries self-destructing content
/// (a timer on the conversation, a view-once or expiring message). The list,
/// and the stored preview of a protected conversation, never carry message
/// text.
public enum ChatProtectionPolicy {

    /// UserDefaults key of the screenshot-lock preference (default on).
    public static let lockPreferenceKey = "qaudion.chat.screenshot_lock_enabled"

    /// Stored in place of the message text. Rendered as the localized label.
    public static let protectedPreviewMarker = "\u{2063}qa.protected\u{2063}"

    /// The app turns this on at launch. It stays off in unit tests of other
    /// areas that assert on stored previews.
    public static var maskStoredPreviews = false

    public static func lockPreferenceEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: lockPreferenceKey) as? Bool) ?? true
    }

    /// Screenshot lock in force for a chat: preference on and no grant by the peer.
    public static func screenshotLockActive(lockEnabled: Bool, peerGranted: Bool?) -> Bool {
        lockEnabled && peerGranted != true
    }

    public static func isProtected(lockEnabled: Bool, peerGranted: Bool?,
                                   ephemeralTimerSeconds: Int?, selfDestructingMessage: Bool = false) -> Bool {
        if screenshotLockActive(lockEnabled: lockEnabled, peerGranted: peerGranted) { return true }
        if (ephemeralTimerSeconds ?? 0) != 0 { return true }
        return selfDestructingMessage
    }

    public static func isProtected(_ conversation: Conversation, lockEnabled: Bool,
                                   selfDestructingMessage: Bool = false) -> Bool {
        isProtected(lockEnabled: lockEnabled, peerGranted: conversation.screenshotGrantedByPeer,
                    ephemeralTimerSeconds: conversation.ephemeralTimerSeconds,
                    selfDestructingMessage: selfDestructingMessage)
    }

    /// True for a message that is hidden or expires: view-once or with an expiry.
    public static func isSelfDestructing(_ message: Message) -> Bool {
        message.isViewOnce == true || message.expiresAt != nil
    }

    /// What goes into the stored preview column.
    public static func storedPreview(_ preview: String, protected: Bool) -> String {
        guard maskStoredPreviews, protected, !preview.isEmpty else { return preview }
        return protectedPreviewMarker
    }

    /// What the list renders. A stored marker, or any text of a protected
    /// conversation (previews stored before this existed), becomes `placeholder`.
    public static func displayPreview(_ stored: String?, protected: Bool, placeholder: String) -> String? {
        guard let stored, !stored.isEmpty else { return stored }
        if stored == protectedPreviewMarker || protected { return placeholder }
        return stored
    }
}

import Foundation
import QAudionEngine

/// The localized label that replaces message text in the conversation list.
enum ProtectedPreview {

    static var label: String {
        String(localized: "chat_list.protected_preview", defaultValue: "Messaggio protetto", comment: "Conversation list row: shown instead of the last message text when the conversation is protected (screenshot lock on, or self-destructing content).")
    }

    /// Text for a row: a stored marker becomes the label, anything else is unchanged.
    static func text(_ preview: String) -> String {
        preview == ChatProtectionPolicy.protectedPreviewMarker ? label : preview
    }

    /// Text for a conversation read straight from the store (not through the list model).
    static func text(for conversation: Conversation) -> String? {
        ChatProtectionPolicy.displayPreview(
            conversation.lastMessagePreview,
            protected: ChatProtectionPolicy.isProtected(
                conversation, lockEnabled: ChatProtectionPolicy.lockPreferenceEnabled()),
            placeholder: label)
    }

    /// A group row preview: masked whenever the screenshot lock is on, as in the group chat itself.
    static func groupText(_ preview: String) -> String {
        ChatProtectionPolicy.lockPreferenceEnabled() ? label : text(preview)
    }
}

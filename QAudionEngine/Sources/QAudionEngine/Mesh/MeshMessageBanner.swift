import Foundation

/// The local banner for a chat message that arrived over the Bluetooth mesh. It must look exactly like the banner of
/// a server-delivered message and show no more than that one does, so the two rules the normal receive path applies
/// are the ones here (plain values in, plain answer out, so they are tested without a device).
public enum MeshMessageBanner {

    /// Body shown when the user hid notification content.
    public static var hiddenBody: String {
        String(localized: "Nuovo messaggio", comment: "Body of the notification banner of a message that arrived over the Bluetooth mesh when the content is hidden.")
    }
    /// A longer preview is cut to this many characters and gets an ellipsis.
    public static let previewLimit = 120

    /// A banner is shown unless banners are switched off in Settings, the conversation is muted, or the user is
    /// looking at this very conversation right now (the message is on screen already).
    public static func shouldNotify(
        bannersEnabled: Bool, muted: Bool, activePeerUserId: String?, senderUserId: String
    ) -> Bool {
        bannersEnabled && !muted && activePeerUserId != senderUserId
    }

    /// The soft tap the normal receive path gives when a message lands in the conversation that is open (no banner is
    /// shown then, so the tap is the only cue). Independent of the banner switch, like the normal path.
    public static func shouldTapInOpenChat(
        muted: Bool, activePeerUserId: String?, senderUserId: String
    ) -> Bool {
        !muted && activePeerUserId == senderUserId
    }

    /// The generic text when either privacy switch hides the content, otherwise the text cut to ``previewLimit``.
    /// `displayText` is the one-line preview of a file or reply, never a descriptor or an object.
    public static func body(displayText: String, hideContent: Bool, previewAllowed: Bool) -> String {
        if hideContent || !previewAllowed { return hiddenBody }
        if displayText.count > previewLimit { return String(displayText.prefix(previewLimit)) + "\u{2026}" }
        return displayText
    }
}

import Foundation

/// W447 — pure precedence rule for per-attachment ephemeral-timer
/// overrides. Mirrors Desktop's `resolveAttachmentTimerSec(envelope,
/// conversationDefault)` (commit `488215b`) and Android's
/// `InboundFileAttachmentDispatcher` behavior: a per-message override
/// wins over the conversation default whenever it is present and
/// non-zero; otherwise the conversation default applies unchanged.
///
/// Semantics of the override value (`ex` on the wire — see
/// `FileTransfer.FileMarker.QFile.ex` / `AttachAnnounceMeta.ex`):
///   - `nil` or `0` → no override, fall back to `conversationDefault`.
///   - `-1`         → view-once.
///   - positive N   → TTL in seconds.
///
/// Kept as a free function (not a method on either wire type) so both
/// the `qfile` marker and the `attach_announce` envelope — today's two
/// live iOS attachment send paths — can share one implementation and
/// one set of unit tests.
public enum AttachmentTimerResolver {

    /// - Parameters:
    ///   - overrideSeconds: the envelope's `ex` field, if any.
    ///   - conversationDefault: `Conversation.ephemeralTimerSeconds`.
    /// - Returns: the effective timer value to apply to this one
    ///   message — same encoding as `Conversation.ephemeralTimerSeconds`
    ///   (nil/0 = off, -1 = view-once, N>0 = TTL seconds).
    public static func resolve(
        overrideSeconds: Int?,
        conversationDefault: Int?
    ) -> Int? {
        if let override = overrideSeconds, override != 0 {
            return override
        }
        return conversationDefault
    }
}

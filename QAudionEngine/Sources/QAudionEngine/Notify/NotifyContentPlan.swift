import Foundation
import CryptoKit

/// What the notification extension shows for an opened envelope, before the system types are involved.
/// Foundation and CryptoKit only (the extension compiles this file directly).
public struct NotifyContentPlan: Equatable, Sendable {

    /// New title, or nil to keep the generic one.
    public let title: String?
    public let senderName: String?
    public let groupName: String?
    /// Avatar file name inside the rubrica folder, nil when unknown.
    public let avatarFile: String?
    public let muted: Bool
    /// Local identifier that groups the notifications of one conversation.
    public let threadIdentifier: String
    public let senderID: String
    public let groupID: String?
    /// The conversation key the app maps back to a chat on tap: `u:<id>` or `g:<id>`.
    public let conversationKey: String

    public static let separator = " \u{00B7} "

    public static func make(from plaintext: NotifyEnvelope.Plaintext, rubrica: NotifyRubrica?) -> NotifyContentPlan {
        let person = rubrica?.person(plaintext.senderID)
        let senderName = person.flatMap { $0.name.isEmpty ? nil : $0.name }
        var groupName: String?
        var muted = person?.muted ?? false
        var key = "u:" + NotifyRubrica.personKey(plaintext.senderID)
        if plaintext.kind == .grp, let gid = plaintext.groupID {
            let group = rubrica?.group(gid)
            groupName = group.flatMap { $0.name.isEmpty ? nil : $0.name }
            // A muted group is silent; a muted person does not silence a group.
            muted = group?.muted ?? false
            key = "g:" + NotifyRubrica.groupKey(gid)
        }
        let title: String?
        switch (senderName, groupName) {
        case let (s?, g?): title = s + separator + g
        case let (s?, nil): title = s
        case let (nil, g?): title = g
        case (nil, nil): title = nil
        }
        return NotifyContentPlan(
            title: title, senderName: senderName, groupName: groupName,
            avatarFile: senderName == nil ? nil : person?.avatar,
            muted: muted, threadIdentifier: threadIdentifier(forKey: key),
            senderID: plaintext.senderID, groupID: plaintext.groupID, conversationKey: key)
    }

    /// Local hash of the conversation key: the same conversation always gets the same thread, and the identifier says
    /// nothing about who it is.
    public static func threadIdentifier(forKey key: String) -> String {
        let digest = SHA256.hash(data: Data(("thread|" + key).utf8))
        return "qa-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

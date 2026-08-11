import Foundation
import GRDB

extension Conversation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"

    /// W-MSGATREST (2026-08-02) — `lastMessagePreview` is a verbatim copy of
    /// the last message's text, so leaving it in the clear would defeat the
    /// point of encrypting the message bodies themselves. Sealed through the
    /// same `LocalStoreCipher` as `Message.plaintext`; every other column is
    /// non-content metadata and stays queryable/sortable in the clear (the
    /// list has to be ordered by `lastActivity` and filtered by `pinned`
    /// without decrypting anything).
    ///
    /// This custom mapping replaces the Codable-derived default. The column
    /// list mirrors the schema in `QAudionDatabase.migrator` exactly —
    /// v1-initial-schema plus `ephemeralTimerSeconds` (v2) and
    /// `screenshotGrantedByPeer` (v4).
    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["peerUserId"] = peerUserId
        container["peerDisplayName"] = peerDisplayName
        // NOT NULL column: an unsealable preview must not become NULL, and
        // must not be written in the clear either — `seal` throws, the write
        // fails loudly, and the caller logs it.
        container["lastMessagePreview"] = try LocalStoreCipher.seal(lastMessagePreview) ?? ""
        container["lastActivity"] = lastActivity
        container["unreadCount"] = unreadCount
        container["pinned"] = pinned
        container["kind"] = kind.rawValue
        container["muted"] = muted
        container["ephemeralTimerSeconds"] = ephemeralTimerSeconds
        container["screenshotGrantedByPeer"] = screenshotGrantedByPeer
    }

    public init(row: Row) throws {
        // Explicitly typed locals rather than inline subscripts: `Row`'s
        // subscript is generic, and chaining it into `??` / an enum init
        // inside one big expression is exactly the shape SWIFT6_PATTERNS.md
        // warns times the type-checker out.
        let storedPreview: String? = row["lastMessagePreview"]
        let kindRaw: String? = row["kind"]
        let mutedFlag: Bool? = row["muted"]
        self.init(
            id: row["id"],
            peerUserId: row["peerUserId"],
            peerDisplayName: row["peerDisplayName"],
            lastMessagePreview: LocalStoreCipher.open(storedPreview),
            lastActivity: row["lastActivity"],
            unreadCount: row["unreadCount"],
            pinned: row["pinned"],
            kind: Conversation.Kind(rawValue: kindRaw ?? "") ?? .oneToOne,
            muted: mutedFlag ?? false,
            ephemeralTimerSeconds: row["ephemeralTimerSeconds"],
            screenshotGrantedByPeer: row["screenshotGrantedByPeer"]
        )
    }
}

extension Message: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messages"

    // Custom mapping for reactionsJson
    public enum Columns {
        static let reactionsJson = Column("reactionsJson")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["conversationId"] = conversationId
        container["direction"] = direction.rawValue
        // W-MSGATREST (2026-08-02) — the single write choke point for every
        // message body in the app. Sealed with the device-held AES-256-GCM
        // key (`LocalStoreCipher`), same class of protection the contact list
        // already had. `seal` throws rather than degrading to plaintext, so a
        // Keychain failure surfaces as a failed write instead of a silently
        // unencrypted row.
        container["plaintext"] = try LocalStoreCipher.seal(plaintext) ?? ""
        container["sentAt"] = sentAt
        container["deliveredAt"] = deliveredAt
        container["readAt"] = readAt
        container["status"] = status.rawValue
        container["senderUserId"] = senderUserId
        container["serverMessageId"] = serverMessageId
        container["mediaLocalPath"] = mediaLocalPath
        container["mediaDurationMs"] = mediaDurationMs
        container["mediaMimeType"] = mediaMimeType
        container["clientMsgId"] = clientMsgId
        container["edited"] = edited
        container["deletedAt"] = deletedAt
        container["expiresAt"] = expiresAt
        container["isViewOnce"] = isViewOnce
        container["viewOnceOpened"] = viewOnceOpened
        container["exportBlocked"] = exportBlocked
        container["viaMesh"] = viaMesh

        if let reactions = reactions,
           let data = try? JSONEncoder().encode(reactions),
           let json = String(data: data, encoding: .utf8) {
            container[Columns.reactionsJson] = json
        } else {
            container[Columns.reactionsJson] = nil
        }
    }

    /// Unseals the body column. A legacy (unsealed) row comes back verbatim;
    /// a sealed row that cannot be opened — key gone after a restore onto a
    /// new device, or a tampered row — becomes a visible marker rather than
    /// an empty bubble, which would be indistinguishable from a message that
    /// was never there.
    private static func openPlaintext(_ row: Row) -> String {
        let stored: String? = row["plaintext"]
        return LocalStoreCipher.open(stored) ?? LocalStoreCipher.unreadableMarker
    }

    public init(row: Row) throws {
        let reactionsJson: String? = row[Columns.reactionsJson]
        let reactions: [String: [String]]? = reactionsJson.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([String: [String]].self, from: data)
        }

        self.init(
            id: row["id"],
            conversationId: row["conversationId"],
            direction: Message.Direction(rawValue: row["direction"]) ?? .outgoing,
            // Reads back through the same cipher. A row written before this
            // format existed has no marker and is returned verbatim, so an
            // existing chat history keeps displaying across the upgrade.
            plaintext: Self.openPlaintext(row),
            sentAt: row["sentAt"],
            deliveredAt: row["deliveredAt"],
            readAt: row["readAt"],
            status: Message.Status(rawValue: row["status"]) ?? .sent,
            senderUserId: row["senderUserId"],
            serverMessageId: row["serverMessageId"],
            mediaLocalPath: row["mediaLocalPath"],
            mediaDurationMs: row["mediaDurationMs"],
            mediaMimeType: row["mediaMimeType"],
            clientMsgId: row["clientMsgId"],
            edited: row["edited"],
            deletedAt: row["deletedAt"],
            reactions: reactions,
            expiresAt: row["expiresAt"],
            isViewOnce: row["isViewOnce"],
            viewOnceOpened: row["viewOnceOpened"],
            exportBlocked: row["exportBlocked"],
            viaMesh: row["viaMesh"]
        )
    }
}

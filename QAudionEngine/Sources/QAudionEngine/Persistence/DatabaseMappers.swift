import Foundation
import GRDB

extension Conversation: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"
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
        container["plaintext"] = plaintext
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
        
        if let reactions = reactions,
           let data = try? JSONEncoder().encode(reactions),
           let json = String(data: data, encoding: .utf8) {
            container[Columns.reactionsJson] = json
        } else {
            container[Columns.reactionsJson] = nil
        }
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
            plaintext: row["plaintext"],
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
            reactions: reactions
        )
    }
}

import Foundation
import GRDB

/// Local SQLite database for Q-Audion iOS.
///
/// Uses iOS Data Protection (FileProtectionType.completeUntilFirstUserAuthentication)
/// for at-rest encryption — the file is inaccessible until the user first unlocks
/// the device after a reboot. Forensic hardening via PRAGMA secure_delete + auto_vacuum.
///
/// Note: GRDB-SQLCipher is not available as an SPM product. SQLCipher integration
/// requires CocoaPods or a separate xcframework — deferred to a future sprint.
public final class QAudionDatabase {

    public static let shared = QAudionDatabase()

    private let dbQueue: DatabaseQueue

    private init() {
        do {
            let dbURL = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("qaudion.sqlite")

            // Apply iOS Data Protection so the file is encrypted when device is locked.
            if !FileManager.default.fileExists(atPath: dbURL.path) {
                FileManager.default.createFile(atPath: dbURL.path, contents: nil, attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ])
            }

            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA secure_delete = ON")
                try db.execute(sql: "PRAGMA auto_vacuum = FULL")
            }

            self.dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

            try migrator.migrate(dbQueue)

        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }
    
    // MARK: - Migrations
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1-initial-schema") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("peerUserId", .text)
                t.column("peerDisplayName", .text).notNull()
                t.column("lastMessagePreview", .text).notNull()
                t.column("lastActivity", .datetime).notNull()
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("kind", .text).notNull()
                t.column("muted", .boolean).notNull().defaults(to: false)
            }
            
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("direction", .text).notNull()
                t.column("plaintext", .text).notNull()
                t.column("sentAt", .datetime).notNull()
                t.column("deliveredAt", .datetime)
                t.column("readAt", .datetime)
                t.column("status", .text).notNull()
                t.column("senderUserId", .text)
                t.column("serverMessageId", .text)
                t.column("mediaLocalPath", .text)
                t.column("mediaDurationMs", .integer)
                t.column("mediaMimeType", .text)
                t.column("clientMsgId", .text)
                t.column("edited", .boolean)
                t.column("deletedAt", .datetime)
                t.column("reactionsJson", .text) // Map encoded as JSON
                
                t.indexed(on: "conversationId")
                t.indexed(on: "sentAt")
            }
            
            try db.create(table: "security_events") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull() // RE_KEY, THREAT, DEEPFAKE, SESSION_START
                t.column("severity", .text).notNull() // INFO, WARNING, CRITICAL
                t.column("timestamp", .datetime).notNull()
                t.column("details", .text)
                t.column("confidenceScore", .double)
                t.column("peerUserId", .text)
                
                t.indexed(on: "timestamp")
            }
        }
        
        return migrator
    }
    
    // MARK: - Access
    
    public var reader: DatabaseReader { dbQueue }
    public var writer: DatabaseWriter { dbQueue }
}

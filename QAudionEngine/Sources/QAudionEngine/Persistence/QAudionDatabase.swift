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
            // E2EE data loss warning: failing gracefully here means the app will continue to
            // try accessing an uninitialized database (which may crash later) or we must throw.
            // Since we can't throw in a singleton init, and in-memory fallback loses keys,
            // we log critically and still halt. A proper fix requires lifting DB init to a throwable or
            // async application lifecycle phase. For now, keep the crash but log clearly.
            print("[QAudionDatabase] CRITICAL: Failed to initialize SQLite file: \(error). Check device storage or data protection lock state.")
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
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade).indexed()
                t.column("direction", .text).notNull()
                t.column("plaintext", .text).notNull()
                t.column("sentAt", .datetime).notNull().indexed()
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
            }
            
            try db.create(table: "security_events") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull() // RE_KEY, THREAT, DEEPFAKE, SESSION_START
                t.column("severity", .text).notNull() // INFO, WARNING, CRITICAL
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("details", .text)
                t.column("confidenceScore", .double)
                t.column("peerUserId", .text)
            }
        }
        
        migrator.registerMigration("v2-ephemeral-timers") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "expiresAt", .datetime)
            }
            try db.alter(table: "conversations") { t in
                t.add(column: "ephemeralTimerSeconds", .integer)
            }
        }

        migrator.registerMigration("v3-muted-not-null") { db in
            try db.execute(sql: "UPDATE conversations SET muted = 0 WHERE muted IS NULL")
        }

        migrator.registerMigration("v4-view-once-screenshot-perm") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "isViewOnce", .boolean)
                t.add(column: "viewOnceOpened", .boolean)
            }
            try db.alter(table: "conversations") { t in
                t.add(column: "screenshotGrantedByPeer", .boolean)
            }
        }

        return migrator
    }
    
    // MARK: - Access
    
    public var reader: DatabaseReader { dbQueue }
    public var writer: DatabaseWriter { dbQueue }
}

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
            var dbURL = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("qaudion.sqlite")

            // Apply iOS Data Protection so the file is encrypted when device is locked.
            if !FileManager.default.fileExists(atPath: dbURL.path) {
                FileManager.default.createFile(atPath: dbURL.path, contents: nil, attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ])
            }

            // MASVS-STORAGE remediation (2026-08-21, I6) — the message/
            // conversation database was the one local data class in this
            // app WITHOUT backup exclusion (avatar cache and every Keychain
            // item already have it). An unencrypted local iTunes/Finder
            // backup (no password set — a common, real scenario) would
            // otherwise expose the whole local message history in
            // plaintext once restored to any device, independent of the
            // wire-level E2EE that protects it in transit. Best-effort: a
            // failure here must not block database initialization.
            var excludeFromBackup = URLResourceValues()
            excludeFromBackup.isExcludedFromBackup = true
            try? dbURL.setResourceValues(excludeFromBackup)

            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA secure_delete = ON")
                try db.execute(sql: "PRAGMA auto_vacuum = FULL")
            }

            self.dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)

            // GRDB's default journal mode is WAL — the `-wal`/`-shm`
            // sidecar files hold recent, not-yet-checkpointed writes (real
            // message data) and don't inherit the main file's resource
            // values automatically. Exclude them too, best-effort; a
            // missing sidecar (fresh DB, nothing written yet) is expected
            // and not an error.
            for suffix in ["-wal", "-shm"] {
                var sidecarURL = URL(fileURLWithPath: dbURL.path + suffix)
                var sidecarExclude = URLResourceValues()
                sidecarExclude.isExcludedFromBackup = true
                try? sidecarURL.setResourceValues(sidecarExclude)
            }

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

        // Export-permission flag (`Message.exportBlocked`, wire `xp` on
        // AttachAnnounceMeta/GroupAttachmentMeta). Mirrors the v4 migration
        // above exactly: a single nullable/defaulted column added via
        // `ALTER TABLE ADD COLUMN`, no data rewrite, no destructive
        // migration — every pre-existing row decodes with `exportBlocked
        // == nil` (= export allowed, today's behavior unchanged).
        migrator.registerMigration("v5-export-permission") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "exportBlocked", .boolean)
            }
        }

        // BLE-mesh "via mesh" transport tag (`Message.viaMesh`, branch
        // claude/ble-mesh-cleanroom-spike). Mirrors the v4/v5 migrations
        // above exactly: a single nullable column, no data rewrite — every
        // pre-existing row decodes with `viaMesh == nil` (= normal
        // transport, today's behavior unchanged).
        migrator.registerMigration("v6-mesh-transport-tag") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "viaMesh", .boolean)
            }
        }

        // File-attachment/voice-note delivery+read receipts
        // (`Message.wireAttachmentId`). Bug found live 2026-08-18: a sent
        // file/voice note never left its single grey tick, because that
        // transport rides `opaque_message` directly and has no
        // `serverMessageId` for a receipt to match against. Mirrors the
        // v4/v5/v6 migrations above: a single nullable column, no data
        // rewrite — every pre-existing row decodes with
        // `wireAttachmentId == nil`.
        migrator.registerMigration("v7-attachment-receipts") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "wireAttachmentId", .text)
            }
        }

        return migrator
    }

    // MARK: - Access

    public var reader: DatabaseReader { dbQueue }
    public var writer: DatabaseWriter { dbQueue }
}

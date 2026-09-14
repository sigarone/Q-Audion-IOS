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
///
/// W-DBOPENRECOVER (2026-09-01) — an open/migration failure no longer
/// traps. The ladder (quarantine a corrupt file → recreate → otherwise
/// serve from an in-memory stand-in and retry the real file) is decided by
/// `DatabaseOpenRecoveryPolicy`; this class only executes it. See that
/// file's header for the reasoning and the audit reference.
public final class QAudionDatabase {

    public static let shared = QAudionDatabase()

    /// W-DBOPENRECOVER — app-layer sink for every non-healthy
    /// `DatabaseOpenRecoveryPolicy.Outcome` (first open AND later retries).
    /// The engine has no RTLog / TelemetryService (they live in the app
    /// target — same rationale as `QAudionWebRtcCallController.videoTelemetry`),
    /// so the app installs this once at launch, BEFORE the first `.shared`
    /// access (`QAudionApp.init`). Invoked synchronously, possibly off-main,
    /// and possibly while this instance's lock is NOT held but the caller's
    /// database access is in flight: the closure must never touch the
    /// database itself. The engine additionally `print`s the same line, so
    /// the on-device console and the stdout tee see it even with no hook.
    public static var onOpenOutcome: ((DatabaseOpenRecoveryPolicy.Outcome) -> Void)?

    private static let fileName = "qaudion.sqlite"

    /// Where `qaudion.sqlite` lives; `nil` only when Application Support
    /// itself could not be resolved (then the stand-in is permanent for
    /// this process — there is no file to retry).
    private let directoryURL: URL?

    private let lock = NSLock()
    private var dbQueue: DatabaseQueue
    /// Non-nil while `dbQueue` is the in-memory stand-in.
    private var degradedSince: Date?
    private var lastReopenAttemptAt: Date?
    private var outcomeStorage: DatabaseOpenRecoveryPolicy.Outcome

    private convenience init() {
        self.init(directoryURL: Self.defaultDirectoryURL())
    }

    /// Designated initializer. `internal` (not `private`) so the recovery
    /// ladder can be exercised against a scratch directory by
    /// `QAudionDatabaseRecoveryTests` without touching `.shared`; production
    /// code reaches this only through `shared`.
    init(directoryURL: URL?) {
        self.directoryURL = directoryURL
        let opened = Self.openWithRecovery(directoryURL: directoryURL)
        self.dbQueue = opened.queue
        self.outcomeStorage = opened.outcome
        self.degradedSince = opened.outcome.isDegraded ? Date() : nil
        // Seed the retry clock so the first retry lands one full interval
        // after the failure, not on the very next store access.
        self.lastReopenAttemptAt = opened.outcome.isDegraded ? Date() : nil
        Self.report(opened.outcome)
    }

    // MARK: - W-DBOPENRECOVER open ladder

    private static func defaultDirectoryURL() -> URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// Tags which step of `openFileBacked` threw, for the policy/log.
    private struct OpenFailure: Error {
        let stage: DatabaseOpenRecoveryPolicy.Stage
        let underlying: Error
    }

    private static func describe(_ error: Error) -> DatabaseOpenRecoveryPolicy.Failure {
        let stage: DatabaseOpenRecoveryPolicy.Stage
        let underlying: Error
        if let openFailure = error as? OpenFailure {
            stage = openFailure.stage
            underlying = openFailure.underlying
        } else {
            stage = .open
            underlying = error
        }
        let code: Int32? = (underlying as? DatabaseError)?.resultCode.rawValue
        return DatabaseOpenRecoveryPolicy.Failure(
            stage: stage, sqliteCode: code, description: String(describing: underlying))
    }

    /// Walks the ladder described in `DatabaseOpenRecoveryPolicy`'s header
    /// and always returns a usable queue. Sequential by construction: the
    /// policy allows exactly one quarantine per launch, so there are at most
    /// two file-backed attempts before the stand-in.
    private static func openWithRecovery(
        directoryURL: URL?
    ) -> (queue: DatabaseQueue, outcome: DatabaseOpenRecoveryPolicy.Outcome) {
        guard DatabaseOpenRecoveryPolicy.enabled else {
            // Kill switch OFF: the pre-2026-09-01 behavior, verbatim.
            do {
                guard let directoryURL = directoryURL else { throw CocoaError(.fileNoSuchFile) }
                return (try openFileBacked(directoryURL: directoryURL), .healthy)
            } catch {
                fatalError("Failed to initialize database: \(error)")
            }
        }

        guard let directoryURL = directoryURL else {
            let failure = DatabaseOpenRecoveryPolicy.Failure(
                stage: .resolveDirectory, sqliteCode: nil,
                description: "Application Support directory could not be resolved")
            return (openInMemory(), .degradedInMemory(failure: failure, quarantinePath: nil))
        }

        // Attempt 1 — the unchanged happy path.
        let firstFailure: DatabaseOpenRecoveryPolicy.Failure
        do {
            return (try openFileBacked(directoryURL: directoryURL), .healthy)
        } catch {
            firstFailure = describe(error)
        }

        let action = DatabaseOpenRecoveryPolicy.action(for: firstFailure, quarantinesThisLaunch: 0)
        guard action == .quarantineAndRecreate else {
            return (openInMemory(), .degradedInMemory(failure: firstFailure, quarantinePath: nil))
        }

        // Corruption proven: move the file set aside. If even the rename
        // fails (storage itself unwritable) the file stays where it is.
        let quarantinePath: String
        do {
            quarantinePath = try quarantine(fileURL: directoryURL.appendingPathComponent(fileName))
        } catch {
            print("[QAudionDatabase] W-DBOPENRECOVER quarantine failed, file left in place: \(error)")
            return (openInMemory(), .degradedInMemory(failure: firstFailure, quarantinePath: nil))
        }

        // Attempt 2 — fresh file, full migration set. The policy never
        // grants a second quarantine (`quarantinesThisLaunch: 1` always
        // degrades), so a failure here is terminal for this process.
        do {
            let queue = try openFileBacked(directoryURL: directoryURL)
            return (queue, .recoveredAfterQuarantine(failure: firstFailure, quarantinePath: quarantinePath))
        } catch {
            return (openInMemory(), .degradedInMemory(failure: describe(error), quarantinePath: quarantinePath))
        }
    }

    private static func baseConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA auto_vacuum = FULL")
        }
        return config
    }

    /// The pre-2026-09-01 open sequence, statement for statement, with the
    /// directory as a parameter and each throwing step tagged with its
    /// `Stage`. The failed `DatabaseQueue` (if migration threw) is a local
    /// released on the way out — GRDB closes the connection on
    /// deallocation, so by the time the caller quarantines the file no
    /// connection to it is open.
    private static func openFileBacked(directoryURL: URL) throws -> DatabaseQueue {
        var dbURL = directoryURL.appendingPathComponent(fileName)

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

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: dbURL.path, configuration: baseConfiguration())
        } catch {
            throw OpenFailure(stage: .open, underlying: error)
        }

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

        do {
            try migrator.migrate(queue)
        } catch {
            throw OpenFailure(stage: .migrate, underlying: error)
        }
        return queue
    }

    /// Same schema, no file: what the process runs on when the real file
    /// cannot be used. An in-memory SQLite open touches no disk, no key
    /// and no Data Protection class, so short of process-level memory
    /// exhaustion it cannot fail — the trap below is documented as
    /// unreachable, not as a policy: the on-disk file has already been
    /// preserved (untouched or quarantined) by the time this runs.
    private static func openInMemory() -> DatabaseQueue {
        do {
            let queue = try DatabaseQueue(configuration: baseConfiguration())
            try migrator.migrate(queue)
            return queue
        } catch {
            fatalError("Failed to initialize in-memory database stand-in: \(error)")
        }
    }

    /// Moves `qaudion.sqlite` and its sidecars to
    /// `qaudion.sqlite.quarantine-<epoch ms>[-wal|-shm|-journal]` in the
    /// same directory (same volume → a rename, no copy, no extra space).
    /// Never deletes anything: the quarantined set is the diagnostic
    /// evidence, still decryptable with the Keychain key this never
    /// touches. Backup-excluded with the same API the live file uses.
    ///
    /// Sidecars FIRST, main file LAST, abort on the first failure: SQLite
    /// replays a `-wal`/`-journal` it finds next to a database into that
    /// database, so a fresh file created beside the OLD sidecars would be
    /// corrupted by them on its first open. Leaving the main file with its
    /// own sidecars (failure before it moved) is always a consistent state.
    private static func quarantine(fileURL: URL, now: Date = Date()) throws -> String {
        let fm = FileManager.default
        let stampMs = Int64(now.timeIntervalSince1970 * 1000)
        let quarantineStem = fileURL.path + ".quarantine-\(stampMs)"
        for suffix in ["-wal", "-shm", "-journal", ""] {
            let sourcePath = fileURL.path + suffix
            guard fm.fileExists(atPath: sourcePath) else { continue }
            var destination = URL(fileURLWithPath: quarantineStem + suffix)
            try fm.moveItem(at: URL(fileURLWithPath: sourcePath), to: destination)
            var excludeFromBackup = URLResourceValues()
            excludeFromBackup.isExcludedFromBackup = true
            try? destination.setResourceValues(excludeFromBackup)
        }
        return quarantineStem
    }

    /// Log + hook for every non-healthy outcome. `print` is the same path
    /// every other Persistence line takes (stdout tee → ring buffer); the
    /// hook is how the app adds RTLog + telemetry — see `onOpenOutcome`.
    private static func report(_ outcome: DatabaseOpenRecoveryPolicy.Outcome) {
        if case .healthy = outcome { return }
        print(DatabaseOpenRecoveryPolicy.logLine(for: outcome))
        onOpenOutcome?(outcome)
    }

    /// The queue every access goes through. While degraded, retries the
    /// real file at most once per `reopenRetryIntervalSec`; on success the
    /// stand-in is swapped out for the process (a caller mid-transaction
    /// on the old queue keeps its own strong reference and finishes there).
    /// The hook is invoked AFTER the lock is released so a hook that logs
    /// through a store cannot deadlock against this lock.
    private func activeQueue() -> DatabaseQueue {
        var toReport: DatabaseOpenRecoveryPolicy.Outcome?
        lock.lock()
        if let since = degradedSince, let directoryURL = directoryURL {
            let now = Date()
            if DatabaseOpenRecoveryPolicy.shouldRetryReopen(lastAttemptAt: lastReopenAttemptAt, now: now) {
                lastReopenAttemptAt = now
                if let reopened = try? Self.openFileBacked(directoryURL: directoryURL) {
                    dbQueue = reopened
                    degradedSince = nil
                    outcomeStorage = .recoveredOnRetry(afterSec: Int(now.timeIntervalSince(since)))
                    toReport = outcomeStorage
                }
            }
        }
        let queue = dbQueue
        lock.unlock()
        if let outcome = toReport { Self.report(outcome) }
        return queue
    }

    /// Test seam for the retry path (`internal`, `@testable` only): same
    /// code as the interval-gated retry in `activeQueue`, minus the clock.
    /// Returns true when the real file is (now) in use.
    @discardableResult
    func retryReopenNow() -> Bool {
        lock.lock()
        lastReopenAttemptAt = nil
        lock.unlock()
        _ = activeQueue()
        lock.lock(); defer { lock.unlock() }
        return degradedSince == nil
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
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

        // W-MSGOUTBOX (2026-09-01) — durable 1:1 outbox (`ChatOutboxStore`):
        // sealed wire blobs waiting for a socket, and delivery receipts the
        // socket could not carry. A NEW table, no change to `messages` —
        // every existing row and every existing migration is untouched, so
        // an app rolled back to a pre-v8 build simply ignores the table.
        // See `OutboxRetryPolicy`'s header for the audit reference.
        migrator.registerMigration("v8-chat-outbox") { db in
            try db.create(table: "chat_outbox") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull().indexed()
                t.column("conversationId", .text)
                t.column("messageId", .text)
                t.column("peerUserId", .text)
                t.column("payloadB64", .text).notNull().defaults(to: "")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("createdAtMs", .integer).notNull()
                t.column("nextAttemptAtMs", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }

    // MARK: - Access

    public var reader: DatabaseReader { activeQueue() }
    public var writer: DatabaseWriter { activeQueue() }

    /// W-DBOPENRECOVER — what the open ladder decided for this instance,
    /// updated in place when a degraded instance's retry succeeds. The app
    /// reads this to render a "local storage unavailable" state; `.healthy`
    /// is the only value on the happy path.
    public var openOutcome: DatabaseOpenRecoveryPolicy.Outcome {
        lock.lock(); defer { lock.unlock() }
        return outcomeStorage
    }
}

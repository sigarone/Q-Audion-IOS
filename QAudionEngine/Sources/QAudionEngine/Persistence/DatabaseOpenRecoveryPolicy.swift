import Foundation

/// W-DBOPENRECOVER (2026-09-01) — pure decision logic for what
/// `QAudionDatabase` does when the local SQLite file cannot be opened or
/// migrated (audit memory reference_ios_stability_audit_2026_09_01, P0:
/// `QAudionDatabase.swift:67-68` trapped with `fatalError` on ANY error, so
/// a corrupt file or a full disk was a crash loop at every launch with no
/// way out — the store is a process-wide singleton reached by ~30 call
/// sites, none of which could intercept it).
///
/// Contains NO GRDB / SQLite / FileManager state so every branch below can
/// be pinned by unit tests without a database — same discipline as
/// `RestartIceDecisions` / `SrtpFallbackDecisions` / `KeychainProtectionPolicy`.
///
/// The ladder `QAudionDatabase` walks with these decisions:
///   1. open + migrate the real file (the unchanged happy path);
///   2. on failure, classify the SQLite result code; ONLY a proven
///      corruption code moves the file (and its `-wal`/`-shm`/`-journal`
///      sidecars) into a timestamped quarantine next to it — never deleted,
///      excluded from backup, still decryptable with the untouched Keychain
///      key — and re-runs step 1 on a fresh file;
///   3. anything that is not corruption (disk full, file not openable,
///      unknown) keeps the file exactly as it is and serves the process from
///      an in-memory stand-in with the same schema, retrying the real file
///      on later accesses. Not quarantining here is deliberate: a file the
///      OS refuses to open before the first unlock after a reboot
///      (`SQLITE_CANTOPEN` under Data Protection), or a migration that
///      cannot write because the disk is full, is a HEALTHY file — moving
///      it aside would turn a transient condition into a lost history.
public enum DatabaseOpenRecoveryPolicy {

    // MARK: - Kill switch

    /// Compile-time kill switch (same style as
    /// `CallCapabilities.longAudioSendEnabled`). `false` restores the
    /// pre-2026-09-01 behavior verbatim: any open/migration error traps
    /// with `fatalError`. Rollback is this line.
    public static let enabled: Bool = true

    /// While serving from the in-memory stand-in, how often an access may
    /// retry the real file. Bounds the cost of a persistent failure (one
    /// `sqlite3_open` per interval) while still self-healing in-process
    /// when the condition clears (space freed, first unlock happened) —
    /// without it a process that degraded once would stay degraded until
    /// the next launch, and every message received meanwhile would be
    /// lost at that relaunch.
    public static let reopenRetryIntervalSec: TimeInterval = 30

    // MARK: - SQLite result codes (primary codes, sqlite3.h)

    /// `SQLITE_CORRUPT` (11) and `SQLITE_NOTADB` (26): the bytes on disk are
    /// no longer a database. The only codes that justify moving the file.
    public static let corruptionCodes: Set<Int32> = [11, 26]

    /// `SQLITE_FULL` (13) — insertion failed because the disk/quota is full.
    public static let diskFullCode: Int32 = 13

    /// `SQLITE_CANTOPEN` (14) — the OS refused to open the file (Data
    /// Protection before first unlock, missing directory, permissions).
    public static let cannotOpenCode: Int32 = 14

    // MARK: - Types

    /// Where in the open sequence the failure happened.
    public enum Stage: Int, Equatable {
        /// The Application Support directory itself could not be resolved.
        case resolveDirectory = 0
        /// `DatabaseQueue(path:)` — connection + WAL setup + header check.
        case open = 1
        /// `DatabaseMigrator.migrate` — schema migrations.
        case migrate = 2
    }

    public enum FailureClass: Int, Equatable {
        case corrupt = 1
        case diskFull = 2
        case cannotOpen = 3
        case other = 4
    }

    /// One failed attempt, as much as a log line / telemetry event needs.
    public struct Failure: Equatable {
        public let stage: Stage
        /// SQLite primary result code, `nil` when the error was not a
        /// `DatabaseError` (e.g. the directory lookup itself failed).
        public let sqliteCode: Int32?
        /// Human-readable description of the underlying error (GRDB's own
        /// `description`: code + message + SQL). Contains no user data —
        /// migrations carry schema SQL only.
        public let description: String

        public init(stage: Stage, sqliteCode: Int32?, description: String) {
            self.stage = stage
            self.sqliteCode = sqliteCode
            self.description = description
        }

        public var failureClass: FailureClass {
            DatabaseOpenRecoveryPolicy.classify(sqliteCode: sqliteCode)
        }
    }

    public enum Action: Equatable {
        /// Move db + sidecars into quarantine, then open a fresh file.
        case quarantineAndRecreate
        /// Leave the file untouched; serve from an in-memory stand-in and
        /// retry the real file later.
        case degradeToInMemory
    }

    /// What the open ladder ended with. Exposed by
    /// `QAudionDatabase.openOutcome` and delivered to
    /// `QAudionDatabase.onOpenOutcome` so the app layer can log, emit
    /// telemetry and show a "local storage unavailable" state instead of
    /// the process dying.
    public enum Outcome: Equatable {
        /// Real file opened and migrated first time. The happy path.
        case healthy
        /// First attempt failed with a corruption code; the file set was
        /// moved to `quarantinePath` (+ sidecar suffixes) and a fresh file
        /// opened and migrated successfully. History before this launch is
        /// in the quarantine, not in the live database.
        case recoveredAfterQuarantine(failure: Failure, quarantinePath: String)
        /// Serving from the in-memory stand-in. `quarantinePath` is non-nil
        /// when a quarantine DID happen but the fresh file failed too
        /// (storage itself is unwritable). Rows written now vanish at exit
        /// unless a later retry reopens the real file.
        case degradedInMemory(failure: Failure, quarantinePath: String?)
        /// A retry from the degraded state reopened the real file. Rows
        /// written to the stand-in in between are gone; everything from
        /// now on persists.
        case recoveredOnRetry(afterSec: Int)

        public var isDegraded: Bool {
            if case .degradedInMemory = self { return true }
            return false
        }

        /// Numeric identity for the log/telemetry tail (see `logLine`).
        public var code: Int {
            switch self {
            case .healthy: return 0
            case .recoveredAfterQuarantine: return 1
            case .degradedInMemory: return 2
            case .recoveredOnRetry: return 3
            }
        }

        public var failure: Failure? {
            switch self {
            case .healthy, .recoveredOnRetry: return nil
            case .recoveredAfterQuarantine(let f, _): return f
            case .degradedInMemory(let f, _): return f
            }
        }

        public var quarantinePath: String? {
            switch self {
            case .healthy, .recoveredOnRetry: return nil
            case .recoveredAfterQuarantine(_, let p): return p
            case .degradedInMemory(_, let p): return p
            }
        }
    }

    // MARK: - Decisions

    public static func classify(sqliteCode: Int32?) -> FailureClass {
        guard let code = sqliteCode else { return .other }
        if corruptionCodes.contains(code) { return .corrupt }
        if code == diskFullCode { return .diskFull }
        if code == cannotOpenCode { return .cannotOpen }
        return .other
    }

    /// `quarantinesThisLaunch` — how many quarantines this process already
    /// performed. A second one can never help: the file that just failed
    /// is the fresh one we created a moment ago, so the fault is in the
    /// storage, not in the bytes.
    public static func action(for failure: Failure, quarantinesThisLaunch: Int) -> Action {
        switch failure.failureClass {
        case .corrupt:
            return quarantinesThisLaunch == 0 ? .quarantineAndRecreate : .degradeToInMemory
        case .diskFull, .cannotOpen, .other:
            return .degradeToInMemory
        }
    }

    /// Whether a degraded instance may try the real file again now.
    public static func shouldRetryReopen(lastAttemptAt: Date?, now: Date) -> Bool {
        guard let last = lastAttemptAt else { return true }
        return now.timeIntervalSince(last) >= reopenRetryIntervalSec
    }

    // MARK: - Reporting

    /// One line for `print` (stdout tee → ring buffer) and `RTLog`. Prose
    /// first for a human at the console, then a purely numeric tail that
    /// survives the iOS log shipper's fail-closed redactor (verified with
    /// `scripts/ship-ios-logs.py` `redact_body` on 2026-09-01: every
    /// `key=<int>` token below arrives intact, prose is blobbed).
    public static func logLine(for outcome: Outcome) -> String {
        let prose: String
        switch outcome {
        case .healthy:
            prose = "opened"
        case .recoveredAfterQuarantine(let failure, let path):
            prose = "quarantined corrupt file to \(path) and recreated (\(failure.description))"
        case .degradedInMemory(let failure, let path):
            if let path = path {
                prose = "serving IN-MEMORY, fresh file after quarantine to \(path) failed too (\(failure.description))"
            } else {
                prose = "serving IN-MEMORY, file left untouched (\(failure.description))"
            }
        case .recoveredOnRetry(let afterSec):
            prose = "real file reopened after \(afterSec)s in-memory"
        }
        return "[QAudionDatabase] W-DBOPENRECOVER local database open: \(prose) \(numericTail(for: outcome))"
    }

    /// The numeric fields shared by `numericTail` and `telemetryAttributes`
    /// (one definition, so the log line and the telemetry event can never
    /// disagree). `-1` / `0` mean "no failure to describe" (healthy, retry).
    public struct NumericFields: Equatable {
        public let outcome: Int
        public let stage: Int
        public let code: Int
        public let cls: Int
        public let quar: Int
        public let deg: Int
    }

    public static func numericFields(for outcome: Outcome) -> NumericFields {
        var stage = -1
        var code = -1
        var cls = 0
        if let failure = outcome.failure {
            stage = failure.stage.rawValue
            cls = failure.failureClass.rawValue
            if let sqliteCode = failure.sqliteCode {
                code = Int(sqliteCode)
            }
        }
        return NumericFields(
            outcome: outcome.code,
            stage: stage,
            code: code,
            cls: cls,
            quar: outcome.quarantinePath == nil ? 0 : 1,
            deg: outcome.isDegraded ? 1 : 0)
    }

    public static func numericTail(for outcome: Outcome) -> String {
        let n = numericFields(for: outcome)
        return "outcome=\(n.outcome) stage=\(n.stage) code=\(n.code) cls=\(n.cls) quar=\(n.quar) deg=\(n.deg)"
    }

    /// Attributes for the sealed telemetry event (`db.open_recovery`).
    /// Same numeric fields as `numericTail`, plus the description.
    public static func telemetryAttributes(for outcome: Outcome) -> [String: Any] {
        let n = numericFields(for: outcome)
        var attrs: [String: Any] = [:]
        attrs["outcome"] = n.outcome
        attrs["stage"] = n.stage
        attrs["code"] = n.code
        attrs["cls"] = n.cls
        attrs["quar"] = n.quar
        attrs["deg"] = n.deg
        if let failure = outcome.failure {
            attrs["desc"] = failure.description
        }
        return attrs
    }
}

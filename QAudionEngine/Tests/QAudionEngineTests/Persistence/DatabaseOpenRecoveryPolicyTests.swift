import XCTest
@testable import QAudionEngine

/// W-DBOPENRECOVER (2026-09-01) — pins the pure open-recovery contract
/// (`DatabaseOpenRecoveryPolicy`) the way `RestartIceDecisionsTests` pins
/// the ICE-restart one: every branch and every number, with no database.
/// The end-to-end ladder on real files is `QAudionDatabaseRecoveryTests`.
final class DatabaseOpenRecoveryPolicyTests: XCTestCase {

    private typealias P = DatabaseOpenRecoveryPolicy

    private func failure(_ code: Int32?, stage: P.Stage = .open) -> P.Failure {
        P.Failure(stage: stage, sqliteCode: code, description: "test")
    }

    // MARK: - Constants

    func test_killSwitch_defaultsToRecoveryOn() {
        XCTAssertTrue(P.enabled)
        XCTAssertEqual(P.reopenRetryIntervalSec, 30)
        XCTAssertEqual(P.corruptionCodes, [11, 26])
        XCTAssertEqual(P.diskFullCode, 13)
        XCTAssertEqual(P.cannotOpenCode, 14)
    }

    // MARK: - Classification

    func test_classify_onlyProvenCorruptionCodesAreCorrupt() {
        XCTAssertEqual(P.classify(sqliteCode: 11), .corrupt)     // SQLITE_CORRUPT
        XCTAssertEqual(P.classify(sqliteCode: 26), .corrupt)     // SQLITE_NOTADB
        XCTAssertEqual(P.classify(sqliteCode: 13), .diskFull)    // SQLITE_FULL
        XCTAssertEqual(P.classify(sqliteCode: 14), .cannotOpen)  // SQLITE_CANTOPEN
        XCTAssertEqual(P.classify(sqliteCode: 1), .other)        // SQLITE_ERROR
        XCTAssertEqual(P.classify(sqliteCode: 10), .other)       // SQLITE_IOERR
        XCTAssertEqual(P.classify(sqliteCode: nil), .other)
        XCTAssertEqual(failure(26).failureClass, .corrupt)
    }

    // MARK: - Action ladder

    func test_action_corruptFirstTime_quarantinesAndRecreates() {
        XCTAssertEqual(P.action(for: failure(26), quarantinesThisLaunch: 0), .quarantineAndRecreate)
        XCTAssertEqual(P.action(for: failure(11, stage: .migrate), quarantinesThisLaunch: 0), .quarantineAndRecreate)
    }

    /// The freshly created file failing with a corruption code means the
    /// storage is broken, not the bytes — a second quarantine cannot help.
    func test_action_corruptAgainAfterQuarantine_degrades() {
        XCTAssertEqual(P.action(for: failure(26), quarantinesThisLaunch: 1), .degradeToInMemory)
        XCTAssertEqual(P.action(for: failure(11), quarantinesThisLaunch: 2), .degradeToInMemory)
    }

    /// The data-preserving branch: a file the OS will not open (Data
    /// Protection before first unlock), a full disk, or an unknown error
    /// must never move the file — quarantining it would turn a transient
    /// condition into a lost history.
    func test_action_nonCorruptFailures_neverQuarantine() {
        let codes: [Int32?] = [13, 14, 1, 10, nil]
        for code in codes {
            XCTAssertEqual(P.action(for: failure(code), quarantinesThisLaunch: 0), .degradeToInMemory,
                           "code=\(String(describing: code))")
            XCTAssertEqual(P.action(for: failure(code, stage: .migrate), quarantinesThisLaunch: 0), .degradeToInMemory,
                           "code=\(String(describing: code)) stage=migrate")
        }
        XCTAssertEqual(P.action(for: failure(nil, stage: .resolveDirectory), quarantinesThisLaunch: 0),
                       .degradeToInMemory)
    }

    // MARK: - Retry clock

    func test_shouldRetryReopen_respectsInterval() {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        XCTAssertTrue(P.shouldRetryReopen(lastAttemptAt: nil, now: t0))
        XCTAssertFalse(P.shouldRetryReopen(lastAttemptAt: t0, now: t0))
        XCTAssertFalse(P.shouldRetryReopen(lastAttemptAt: t0,
                                           now: t0.addingTimeInterval(P.reopenRetryIntervalSec - 1)))
        XCTAssertTrue(P.shouldRetryReopen(lastAttemptAt: t0,
                                          now: t0.addingTimeInterval(P.reopenRetryIntervalSec)))
    }

    // MARK: - Outcome accessors

    func test_outcome_accessors() {
        let f = failure(26, stage: .open)
        let recovered = P.Outcome.recoveredAfterQuarantine(failure: f, quarantinePath: "/x/qaudion.sqlite.quarantine-1")
        XCTAssertFalse(recovered.isDegraded)
        XCTAssertEqual(recovered.code, 1)
        XCTAssertEqual(recovered.failure, f)
        XCTAssertEqual(recovered.quarantinePath, "/x/qaudion.sqlite.quarantine-1")

        let degraded = P.Outcome.degradedInMemory(failure: failure(13, stage: .migrate), quarantinePath: nil)
        XCTAssertTrue(degraded.isDegraded)
        XCTAssertEqual(degraded.code, 2)
        XCTAssertNil(degraded.quarantinePath)

        XCTAssertEqual(P.Outcome.healthy.code, 0)
        XCTAssertNil(P.Outcome.healthy.failure)
        XCTAssertFalse(P.Outcome.healthy.isDegraded)
        XCTAssertEqual(P.Outcome.recoveredOnRetry(afterSec: 42).code, 3)
        XCTAssertFalse(P.Outcome.recoveredOnRetry(afterSec: 42).isDegraded)
    }

    // MARK: - Reporting

    /// The numeric tail is the part that survives the iOS log shipper's
    /// fail-closed redactor (verified against scripts/ship-ios-logs.py on
    /// 2026-09-01); its exact shape is the contract a Loki query greps for.
    func test_logLine_carriesNumericTail() {
        let recovered = P.Outcome.recoveredAfterQuarantine(failure: failure(26, stage: .open), quarantinePath: "/x/q")
        XCTAssertTrue(P.logLine(for: recovered).hasPrefix("[QAudionDatabase] W-DBOPENRECOVER "))
        XCTAssertTrue(P.logLine(for: recovered).hasSuffix("outcome=1 stage=1 code=26 cls=1 quar=1 deg=0"))

        let degraded = P.Outcome.degradedInMemory(failure: failure(14, stage: .open), quarantinePath: nil)
        XCTAssertTrue(P.logLine(for: degraded).hasSuffix("outcome=2 stage=1 code=14 cls=3 quar=0 deg=1"))

        let degradedAfterQuarantine = P.Outcome.degradedInMemory(failure: failure(13, stage: .migrate), quarantinePath: "/x/q")
        XCTAssertTrue(P.logLine(for: degradedAfterQuarantine).hasSuffix("outcome=2 stage=2 code=13 cls=2 quar=1 deg=1"))

        XCTAssertTrue(P.logLine(for: .recoveredOnRetry(afterSec: 7)).hasSuffix("outcome=3 stage=-1 code=-1 cls=0 quar=0 deg=0"))
        XCTAssertTrue(P.logLine(for: .healthy).hasSuffix("outcome=0 stage=-1 code=-1 cls=0 quar=0 deg=0"))
    }

    func test_telemetryAttributes_mirrorNumericTail() {
        let outcome = P.Outcome.degradedInMemory(failure: failure(13, stage: .migrate), quarantinePath: "/x/q")
        let attrs = P.telemetryAttributes(for: outcome)
        XCTAssertEqual(attrs["outcome"] as? Int, 2)
        XCTAssertEqual(attrs["stage"] as? Int, 2)
        XCTAssertEqual(attrs["code"] as? Int, 13)
        XCTAssertEqual(attrs["cls"] as? Int, 2)
        XCTAssertEqual(attrs["quar"] as? Int, 1)
        XCTAssertEqual(attrs["deg"] as? Int, 1)
        XCTAssertEqual(attrs["desc"] as? String, "test")

        let healthy = P.telemetryAttributes(for: .healthy)
        XCTAssertEqual(healthy["outcome"] as? Int, 0)
        XCTAssertEqual(healthy["code"] as? Int, -1)
        XCTAssertNil(healthy["desc"])
    }
}

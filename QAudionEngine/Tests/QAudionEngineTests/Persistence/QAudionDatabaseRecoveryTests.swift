import XCTest
@testable import QAudionEngine

/// W-DBOPENRECOVER (2026-09-01) — end-to-end proof of the open-recovery
/// ladder on real files in a scratch directory (the pure decisions are
/// pinned in `DatabaseOpenRecoveryPolicyTests`). Uses `QAudionDatabase`'s
/// internal directory initializer, never `.shared`, so it cannot interfere
/// with the singleton the other Persistence tests share.
final class QAudionDatabaseRecoveryTests: XCTestCase {

    private var scratch: URL!
    private var defaults: UserDefaults!
    private var savedHook: ((DatabaseOpenRecoveryPolicy.Outcome) -> Void)?
    private var reported: [DatabaseOpenRecoveryPolicy.Outcome] = []

    override func setUp() {
        super.setUp()
        // Same seam as ConversationStoreTests: no usable keychain in a
        // simulator test bundle, so the at-rest key is injected. The store
        // is exercised through its production API on top of the recovered
        // database, so the sealing path is the real one.
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x3a, count: 32)
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("qaudiondb-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suite = "test.dbrecovery.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // Suite name is a freshly generated, well-formed non-empty string; UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        defaults = UserDefaults(suiteName: suite)!
        savedHook = QAudionDatabase.onOpenOutcome
        reported = []
        QAudionDatabase.onOpenOutcome = { [weak self] outcome in
            self?.reported.append(outcome)
        }
    }

    override func tearDown() {
        QAudionDatabase.onOpenOutcome = savedHook
        LocalStoreCipher.testKeyOverride = nil
        if let scratch = scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        defaults = nil
        super.tearDown()
    }

    private var dbFile: URL { scratch.appendingPathComponent("qaudion.sqlite") }

    private func makeConv(id: UUID = UUID()) -> Conversation {
        Conversation(id: id, peerUserId: "u-\(id.uuidString.prefix(8))",
                     peerDisplayName: "Peer", lastMessagePreview: nil,
                     lastActivity: Date(timeIntervalSince1970: 1_745_000_000),
                     unreadCount: 0, pinned: false)
    }

    /// Quarantined MAIN files (sidecar moves, if any, are excluded).
    private func quarantinedMainFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                return name.contains(".quarantine-")
                    && !name.hasSuffix("-wal") && !name.hasSuffix("-shm") && !name.hasSuffix("-journal")
            }
    }

    // MARK: - Happy path is untouched

    func test_freshDirectory_opensHealthy_andSchemaServesTheStore() {
        let db = QAudionDatabase(directoryURL: scratch)

        XCTAssertEqual(db.openOutcome, .healthy)
        XCTAssertTrue(reported.isEmpty, "a healthy open must be silent")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbFile.path))

        let store = ConversationStore(db: db, defaults: defaults)
        XCTAssertTrue(store.loadConversations().isEmpty)
        store.upsertConversation(makeConv())
        XCTAssertEqual(store.loadConversations().count, 1)
    }

    // MARK: - Corruption → quarantine + recreate

    /// The P0 from the audit: bytes that are not a database used to be a
    /// crash loop at every launch (`fatalError` at the old :67-68). Now the
    /// file set is quarantined — never deleted, bytes intact for diagnosis
    /// — a fresh file is created and migrated, and the store is fully
    /// usable and durable.
    func test_corruptFile_isQuarantinedAndRecreated() throws {
        // No SQLite header and larger than one page, so SQLite reports
        // "file is not a database" instead of treating it as empty.
        let garbage = Data(repeating: 0x41, count: 8192)
        try garbage.write(to: dbFile)

        let db = QAudionDatabase(directoryURL: scratch)

        guard case .recoveredAfterQuarantine(let failure, let quarantinePath) = db.openOutcome else {
            return XCTFail("expected recoveredAfterQuarantine, got \(db.openOutcome)")
        }
        XCTAssertEqual(failure.failureClass, .corrupt)
        // GRDB probes `sqlite_master` while opening (its validateFormat step),
        // so garbage bytes fail at `.open`, before any migration runs.
        XCTAssertEqual(failure.stage, .open)
        XCTAssertTrue(quarantinePath.hasPrefix(dbFile.path + ".quarantine-"), quarantinePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: quarantinePath)), garbage,
                       "quarantine must preserve the original bytes")
        XCTAssertEqual(try quarantinedMainFiles().count, 1, "one quarantined set, nothing deleted")
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first, db.openOutcome)

        let store = ConversationStore(db: db, defaults: defaults)
        XCTAssertTrue(store.loadConversations().isEmpty)
        store.upsertConversation(makeConv())
        XCTAssertEqual(store.loadConversations().count, 1)

        // The recreated file is a real on-disk database: a second instance
        // on the same directory opens healthy and sees the row.
        let again = QAudionDatabase(directoryURL: scratch)
        XCTAssertEqual(again.openOutcome, .healthy)
        XCTAssertEqual(ConversationStore(db: again, defaults: defaults).loadConversations().count, 1)
        XCTAssertEqual(reported.count, 1, "the healthy re-open must not report")
    }

    // MARK: - Non-corruption → in-memory stand-in, file untouched, retry

    /// A location the OS will not open is NOT corruption: nothing is moved,
    /// the process runs on the in-memory stand-in (schema present, store
    /// usable) and, once the condition clears, a retry reopens the real
    /// file in-process — no trap, no relaunch needed.
    func test_unopenableLocation_degradesInMemory_thenRecoversOnRetry() throws {
        // A regular FILE where the directory should be, so every open of
        // "<file>/sub/qaudion.sqlite" fails at the OS level.
        let blocker = scratch.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let blockedDir = blocker.appendingPathComponent("sub", isDirectory: true)

        let db = QAudionDatabase(directoryURL: blockedDir)

        guard case .degradedInMemory(let failure, let quarantinePath) = db.openOutcome else {
            return XCTFail("expected degradedInMemory, got \(db.openOutcome)")
        }
        XCTAssertNil(quarantinePath, "a non-corrupt failure must never move anything")
        XCTAssertNotEqual(failure.failureClass, .corrupt)
        XCTAssertEqual(failure.stage, .open)
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported.first?.isDegraded ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path), "blocker file left untouched")

        // The stand-in serves the real store API.
        let store = ConversationStore(db: db, defaults: defaults)
        XCTAssertTrue(store.loadConversations().isEmpty)
        store.upsertConversation(makeConv())
        XCTAssertEqual(store.loadConversations().count, 1)

        // Still blocked: a retry fails quietly and the instance stays degraded.
        XCTAssertFalse(db.retryReopenNow())
        XCTAssertTrue(db.openOutcome.isDegraded)
        XCTAssertEqual(reported.count, 1, "a failed retry is not reported")

        // Condition clears: the location becomes a real directory.
        try FileManager.default.removeItem(at: blocker)
        try FileManager.default.createDirectory(at: blockedDir, withIntermediateDirectories: true)

        XCTAssertTrue(db.retryReopenNow())
        guard case .recoveredOnRetry = db.openOutcome else {
            return XCTFail("expected recoveredOnRetry, got \(db.openOutcome)")
        }
        XCTAssertEqual(reported.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: blockedDir.appendingPathComponent("qaudion.sqlite").path))

        // Rows written to the stand-in are gone by design; rows written
        // from now on land on disk and survive a fresh instance.
        XCTAssertTrue(store.loadConversations().isEmpty)
        store.upsertConversation(makeConv())
        let fresh = QAudionDatabase(directoryURL: blockedDir)
        XCTAssertEqual(fresh.openOutcome, .healthy)
        XCTAssertEqual(ConversationStore(db: fresh, defaults: defaults).loadConversations().count, 1)
    }

    /// No directory at all (Application Support unresolvable) is the one
    /// case with nothing to retry: permanent stand-in, still no trap.
    func test_nilDirectory_degradesInMemory_withoutRetry() {
        let db = QAudionDatabase(directoryURL: nil)

        guard case .degradedInMemory(let failure, let quarantinePath) = db.openOutcome else {
            return XCTFail("expected degradedInMemory, got \(db.openOutcome)")
        }
        XCTAssertNil(quarantinePath)
        XCTAssertEqual(failure.stage, .resolveDirectory)
        XCTAssertNil(failure.sqliteCode)
        XCTAssertEqual(reported.count, 1)

        let store = ConversationStore(db: db, defaults: defaults)
        store.upsertConversation(makeConv())
        XCTAssertEqual(store.loadConversations().count, 1)

        XCTAssertFalse(db.retryReopenNow())
        XCTAssertTrue(db.openOutcome.isDegraded)
        XCTAssertEqual(reported.count, 1)
    }
}

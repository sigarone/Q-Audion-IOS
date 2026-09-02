import XCTest
@testable import QAudionEngine

/// W-MSGOUTBOX (2026-09-01) — the durable outbox table on a real file in a
/// scratch directory (same seam as `QAudionDatabaseRecoveryTests`, never
/// `.shared`, so nothing here can interfere with the singleton the other
/// Persistence tests use).
final class ChatOutboxStoreTests: XCTestCase {

    private var scratch: URL!
    private var db: QAudionDatabase!
    private var store: ChatOutboxStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("qaudion-outbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        db = QAudionDatabase(directoryURL: scratch)
        store = ChatOutboxStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
        if let scratch = scratch {
            try? FileManager.default.removeItem(at: scratch)
        }
        scratch = nil
        super.tearDown()
    }

    private func enqueue(clientMsgId: String = UUID().uuidString,
                         createdAtMs: Int64 = 1_000,
                         attempts: Int = 0,
                         nextAttemptAtMs: Int64 = 0,
                         blob: Data = Data([0xE3, 0x01, 0x02])) -> String {
        store.enqueueMessage(
            clientMsgId: clientMsgId, messageId: UUID(), conversationId: UUID(),
            peerUserId: "peer-1", wireBlob: blob, attempts: attempts,
            createdAtMs: createdAtMs, nextAttemptAtMs: nextAttemptAtMs)
        return clientMsgId
    }

    func test_freshDatabase_hasEmptyOutbox() {
        XCTAssertEqual(db.openOutcome, .healthy)
        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(store.pendingMessages().isEmpty)
        XCTAssertTrue(store.pendingDeliveryReceipts().isEmpty)
    }

    func test_enqueueMessage_persistsExactBytesAndFields() {
        let blob = Data((0..<64).map { UInt8($0) })
        let id = enqueue(createdAtMs: 42, attempts: 1, nextAttemptAtMs: 542, blob: blob)

        let entry = store.entry(id: id)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.kind, ChatOutboxEntry.kindMessage)
        XCTAssertEqual(entry?.attempts, 1)
        XCTAssertEqual(entry?.createdAtMs, 42)
        XCTAssertEqual(entry?.nextAttemptAtMs, 542)
        XCTAssertEqual(entry?.peerUserId, "peer-1")
        XCTAssertEqual(entry.flatMap { Data(base64Encoded: $0.payloadB64) }, blob)
    }

    func test_enqueueMessage_isIdempotentPerClientMsgId() {
        let id = enqueue(attempts: 0)
        store.enqueueMessage(
            clientMsgId: id, messageId: UUID(), conversationId: UUID(),
            peerUserId: "peer-1", wireBlob: Data([0x01]), attempts: 3,
            createdAtMs: 7, nextAttemptAtMs: 9)
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(store.entry(id: id)?.attempts, 3)
    }

    func test_pendingMessages_oldestFirst() {
        let later = enqueue(createdAtMs: 3_000)
        let earliest = enqueue(createdAtMs: 1_000)
        let middle = enqueue(createdAtMs: 2_000)
        XCTAssertEqual(store.pendingMessages().map { $0.id }, [earliest, middle, later])
    }

    func test_recordAttempt_updatesOnlyCounters() {
        let blob = Data([0xAA, 0xBB])
        let id = enqueue(createdAtMs: 10, blob: blob)
        store.recordAttempt(id: id, attempts: 4, nextAttemptAtMs: 9_999)
        let entry = store.entry(id: id)
        XCTAssertEqual(entry?.attempts, 4)
        XCTAssertEqual(entry?.nextAttemptAtMs, 9_999)
        XCTAssertEqual(entry?.createdAtMs, 10)
        XCTAssertEqual(entry.flatMap { Data(base64Encoded: $0.payloadB64) }, blob)
    }

    func test_remove_dropsOnlyThatEntry() {
        let keep = enqueue()
        let drop = enqueue()
        store.remove(id: drop)
        XCTAssertNil(store.entry(id: drop))
        XCTAssertNotNil(store.entry(id: keep))
        XCTAssertEqual(store.count(), 1)
    }

    func test_deliveryReceipts_areSeparateFromMessages() {
        _ = enqueue()
        store.enqueueDeliveryReceipt(serverMessageId: "srv-1", nowMs: 5)
        store.enqueueDeliveryReceipt(serverMessageId: "srv-0", nowMs: 1)
        // Re-enqueue of the same id is an upsert, not a duplicate.
        store.enqueueDeliveryReceipt(serverMessageId: "srv-1", nowMs: 6)

        let receipts = store.pendingDeliveryReceipts()
        XCTAssertEqual(receipts.map { $0.id }, ["srv-0", "srv-1"])
        XCTAssertEqual(receipts.map { $0.kind }, [ChatOutboxEntry.kindDeliveryReceipt, ChatOutboxEntry.kindDeliveryReceipt])
        XCTAssertEqual(receipts.first?.payloadB64, "")
        XCTAssertEqual(store.pendingMessages().count, 1)
        XCTAssertEqual(store.count(), 3)
    }

    func test_removeAll_emptiesBothKinds() {
        _ = enqueue()
        store.enqueueDeliveryReceipt(serverMessageId: "srv-1", nowMs: 5)
        store.removeAll()
        XCTAssertEqual(store.count(), 0)
    }

    func test_conversationStoreWipeAll_alsoClearsOutbox() {
        _ = enqueue()
        store.enqueueDeliveryReceipt(serverMessageId: "srv-1", nowMs: 5)
        let suite = "test.outbox.wipe.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // Suite name is a freshly generated, well-formed non-empty string; UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        ConversationStore(db: db, defaults: defaults).wipeAll()
        XCTAssertEqual(store.count(), 0)
    }
}

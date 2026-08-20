import XCTest
@testable import QAudionEngine

final class ConversationStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ConversationStore!
    private let convId = UUID()

    override func setUp() {
        super.setUp()
        // Message bodies and the conversation preview are sealed at rest
        // (2026-08-02). A simulator test bundle has no usable keychain, so
        // without an injected key `seal` throws, every write is refused —
        // correctly, it must never fall back to storing plaintext — and the
        // assertions below fail on rows that were never persisted. Same
        // seam as ContactsStoreTests; the cipher path under test is the
        // production one, only the key source differs.
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        let suite = "test.convstore.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // Suite name is a freshly generated, well-formed non-empty string; UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        defaults = UserDefaults(suiteName: suite)!
        store = ConversationStore(defaults: defaults)
        store.wipeAll()  // ConversationStore.db is a shared singleton; reset between tests
    }

    override func tearDown() {
        LocalStoreCipher.testKeyOverride = nil
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func makeConv(id: UUID = UUID()) -> Conversation {
        Conversation(id: id, peerUserId: "u-\(id.uuidString.prefix(8))",
                     peerDisplayName: "Peer", lastMessagePreview: nil,
                     lastActivity: Date(timeIntervalSince1970: 1_745_000_000),
                     unreadCount: 0, pinned: false)
    }

    private func makeMsg(id: UUID = UUID(), in cid: UUID,
                         direction: Message.Direction = .outgoing,
                         status: Message.Status = .sent) -> Message {
        Message(id: id, conversationId: cid, direction: direction,
                plaintext: "hello", sentAt: Date(timeIntervalSince1970: 1_745_000_000),
                deliveredAt: nil, readAt: nil, status: status)
    }

    func test_loadConversations_emptyByDefault() {
        XCTAssertTrue(store.loadConversations().isEmpty)
    }

    func test_upsertConversation_persists() {
        let conv = makeConv(id: convId)
        store.upsertConversation(conv)
        XCTAssertEqual(store.loadConversations().count, 1)
        XCTAssertEqual(store.loadConversations().first, conv)
    }

    func test_upsertConversation_replacesExisting() {
        var conv = makeConv(id: convId)
        store.upsertConversation(conv)
        conv = Conversation(id: conv.id, peerUserId: conv.peerUserId,
                            peerDisplayName: "Updated",
                            lastMessagePreview: "new preview",
                            lastActivity: conv.lastActivity,
                            unreadCount: 5, pinned: true)
        store.upsertConversation(conv)
        XCTAssertEqual(store.loadConversations().count, 1)
        XCTAssertEqual(store.loadConversations().first?.peerDisplayName, "Updated")
        XCTAssertEqual(store.loadConversations().first?.unreadCount, 5)
        XCTAssertTrue(store.loadConversations().first?.pinned ?? false)
    }

    func test_deleteConversation_removesItAndMessages() {
        store.upsertConversation(makeConv(id: convId))
        store.appendMessage(makeMsg(in: convId))
        store.deleteConversation(id: convId)
        XCTAssertTrue(store.loadConversations().isEmpty)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
    }

    func test_appendMessage_persists() {
        store.upsertConversation(makeConv(id: convId))
        let msg = makeMsg(in: convId)
        store.appendMessage(msg)
        XCTAssertEqual(store.loadMessages(conversationId: convId), [msg])
    }

    func test_appendMessage_appendsToExistingList() {
        store.upsertConversation(makeConv(id: convId))
        store.appendMessage(makeMsg(in: convId))
        store.appendMessage(makeMsg(in: convId))
        XCTAssertEqual(store.loadMessages(conversationId: convId).count, 2)
    }

    func test_updateMessageStatus_changesStatusOnly() {
        store.upsertConversation(makeConv(id: convId))
        let mid = UUID()
        let msg = makeMsg(id: mid, in: convId, status: .sending)
        store.appendMessage(msg)
        store.updateMessageStatus(id: mid, conversationId: convId,
                                  newStatus: .delivered, deliveredAt: Date(timeIntervalSince1970: 1_745_001_000))
        // Exactly one message was just appended above for this conversationId; list is guaranteed non-empty.
        // swiftlint:disable:next force_unwrapping
        let updated = store.loadMessages(conversationId: convId).first!
        XCTAssertEqual(updated.status, .delivered)
        XCTAssertNotNil(updated.deliveredAt)
        XCTAssertEqual(updated.plaintext, "hello")
    }

    /// Regression guard for the fetch-all/loop-save → `updateAll` rewrite:
    /// the batched UPDATE must still touch only the row matching
    /// `serverMessageId`, still leave `readAt` alone when the caller only
    /// passes `deliveredAt` (mirrors the old per-row `readAt ?? msg.readAt`
    /// fallback), still leave unrelated columns (`plaintext`) untouched, and
    /// still report false when nothing matched.
    func test_updateStatusByServerId_updatesOnlyMatchingRowAndRequestedFields() {
        store.upsertConversation(makeConv(id: convId))
        let mid = UUID()
        let sid = "srv-\(UUID().uuidString)"
        let msg = Message(id: mid, conversationId: convId, direction: .outgoing,
                          plaintext: "hello", sentAt: Date(timeIntervalSince1970: 1_745_000_000),
                          deliveredAt: nil, readAt: nil, status: .sent,
                          serverMessageId: sid)
        store.appendMessage(msg)

        let matched = store.updateStatusByServerId(
            serverMessageId: sid, newStatus: .delivered,
            deliveredAt: Date(timeIntervalSince1970: 1_745_001_000))
        XCTAssertTrue(matched)
        // Exactly one message was appended above for this conversationId; list is guaranteed non-empty.
        // swiftlint:disable:next force_unwrapping
        let updated = store.loadMessages(conversationId: convId).first!
        XCTAssertEqual(updated.status, .delivered)
        XCTAssertNotNil(updated.deliveredAt)
        XCTAssertNil(updated.readAt)
        XCTAssertEqual(updated.plaintext, "hello")

        let unmatched = store.updateStatusByServerId(serverMessageId: "no-such-server-id", newStatus: .read)
        XCTAssertFalse(unmatched)
    }

    func test_wipeAll_clearsEverything() {
        store.upsertConversation(makeConv(id: convId))
        store.appendMessage(makeMsg(in: convId))
        store.wipeAll()
        XCTAssertTrue(store.loadConversations().isEmpty)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
    }

    // MARK: - View-once

    /// Recipient (incoming) view-once rows must still be armed for
    /// deletion when opened: viewOnceOpened=true + expiresAt set so
    /// EphemeralMessageJanitor sweeps them shortly after. Regression
    /// guard for the existing, correct recipient-side behavior.
    func test_markViewOnceOpened_incomingRow_armsExpiryAndOpensIt() {
        store.upsertConversation(makeConv(id: convId))
        let mid = UUID()
        let msg = Message(id: mid, conversationId: convId, direction: .incoming,
                          plaintext: "peek-a-boo", sentAt: Date(timeIntervalSince1970: 1_745_000_000),
                          deliveredAt: nil, readAt: nil, status: .delivered,
                          isViewOnce: true, viewOnceOpened: nil)
        store.appendMessage(msg)

        store.markViewOnceOpened(messageId: mid, conversationId: convId)

        // Exactly one message was appended above for this conversationId; list is guaranteed non-empty.
        // swiftlint:disable:next force_unwrapping
        let updated = store.loadMessages(conversationId: convId).first!
        XCTAssertEqual(updated.viewOnceOpened, true)
        XCTAssertNotNil(updated.expiresAt)
    }

    /// SENDER's own outgoing view-once row must NEVER be armed for
    /// deletion by markViewOnceOpened, even if called directly (the UI
    /// gate in ChatDetailScreen already prevents this in practice — this
    /// is the defense-in-depth guard at the store layer). The sender
    /// should keep their own copy like any other message.
    func test_markViewOnceOpened_outgoingRow_isNoOp() {
        store.upsertConversation(makeConv(id: convId))
        let mid = UUID()
        let msg = Message(id: mid, conversationId: convId, direction: .outgoing,
                          plaintext: "peek-a-boo", sentAt: Date(timeIntervalSince1970: 1_745_000_000),
                          deliveredAt: nil, readAt: nil, status: .sent,
                          isViewOnce: true, viewOnceOpened: nil)
        store.appendMessage(msg)

        store.markViewOnceOpened(messageId: mid, conversationId: convId)

        // Exactly one message was appended above for this conversationId; list is guaranteed non-empty.
        // swiftlint:disable:next force_unwrapping
        let updated = store.loadMessages(conversationId: convId).first!
        XCTAssertNil(updated.viewOnceOpened)
        XCTAssertNil(updated.expiresAt)
    }

    // MARK: - applyDeleteByClientMsgId blob cleanup

    /// Deleting a message with a cached attachment (voice note / image)
    /// must remove the on-disk blob, not just tombstone the DB row.
    func test_applyDeleteByClientMsgId_removesCachedAttachmentFile() throws {
        store.upsertConversation(makeConv(id: convId))
        let mid = UUID()
        let cmid = mid.uuidString

        // Simulate a cached voice-note blob the way ChatContainer /
        // ChatVoiceNoteReceiver actually write one (Library/Caches/...).
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("convstore-test-\(cmid).m4a")
        try Data("fake-m4a-bytes".utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpFile.path))

        let msg = Message(id: mid, conversationId: convId, direction: .outgoing,
                          plaintext: "voice note", sentAt: Date(timeIntervalSince1970: 1_745_000_000),
                          deliveredAt: nil, readAt: nil, status: .delivered,
                          mediaLocalPath: tmpFile.path,
                          mediaDurationMs: 4200,
                          mediaMimeType: "audio/mp4",
                          clientMsgId: cmid)
        store.appendMessage(msg)

        let applied = store.applyDeleteByClientMsgId(cmid)

        XCTAssertTrue(applied, "tombstone write must succeed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpFile.path),
                       "cached blob must be removed on delete")

        // Exactly one message was appended above for this conversationId; tombstoning keeps the row, not just non-empty.
        // swiftlint:disable:next force_unwrapping
        let tombstoned = store.loadMessages(conversationId: convId).first!
        XCTAssertEqual(tombstoned.plaintext, "Messaggio eliminato")
        XCTAssertNil(tombstoned.mediaLocalPath)
        XCTAssertNotNil(tombstoned.deletedAt)
    }

    /// signal-not-kill: if the cached file is already gone (double-delete,
    /// OS cache eviction, etc.) the tombstone write must still succeed —
    /// cleanup failure is non-fatal and must never block the actual delete.
    func test_applyDeleteByClientMsgId_succeedsEvenWhenCachedFileAlreadyMissing() {
        store.upsertConversation(makeConv(id: convId))
        let mid = UUID()
        let cmid = mid.uuidString

        // Path that was never created / already reclaimed.
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("convstore-test-missing-\(cmid).jpg").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))

        let msg = Message(id: mid, conversationId: convId, direction: .outgoing,
                          plaintext: "photo", sentAt: Date(timeIntervalSince1970: 1_745_000_000),
                          deliveredAt: nil, readAt: nil, status: .delivered,
                          mediaLocalPath: missingPath,
                          mediaMimeType: "image/jpeg",
                          clientMsgId: cmid)
        store.appendMessage(msg)

        let applied = store.applyDeleteByClientMsgId(cmid)

        XCTAssertTrue(applied, "tombstone write must succeed even if cleanup has nothing to remove")
        // Exactly one message was appended above for this conversationId; tombstoning keeps the row, not just non-empty.
        // swiftlint:disable:next force_unwrapping
        let tombstoned = store.loadMessages(conversationId: convId).first!
        XCTAssertEqual(tombstoned.plaintext, "Messaggio eliminato")
        XCTAssertNil(tombstoned.mediaLocalPath)
    }

    /// Text-only messages have no mediaLocalPath — delete must be a no-op
    /// on the filesystem and still succeed.
    func test_applyDeleteByClientMsgId_textMessageNoCleanupNeeded() {
        store.upsertConversation(makeConv(id: convId))
        let mid = UUID()
        let cmid = mid.uuidString
        let msg = Message(id: mid, conversationId: convId, direction: .outgoing,
                          plaintext: "hello", sentAt: Date(timeIntervalSince1970: 1_745_000_000),
                          deliveredAt: nil, readAt: nil, status: .delivered,
                          clientMsgId: cmid)
        store.appendMessage(msg)

        XCTAssertTrue(store.applyDeleteByClientMsgId(cmid))
        XCTAssertEqual(store.loadMessages(conversationId: convId).first?.plaintext, "Messaggio eliminato")
    }

    func test_applyDeleteByClientMsgId_unknownClientMsgId_returnsFalse() {
        store.upsertConversation(makeConv(id: convId))
        XCTAssertFalse(store.applyDeleteByClientMsgId("no-such-cmid"))
    }
}

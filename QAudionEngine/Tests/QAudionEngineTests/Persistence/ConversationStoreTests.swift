import XCTest
@testable import QAudionEngine

final class ConversationStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ConversationStore!
    private let convId = UUID()

    override func setUp() {
        super.setUp()
        let suite = "test.convstore.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)!
        store = ConversationStore(defaults: defaults)
        store.wipeAll()  // ConversationStore.db is a shared singleton; reset between tests
    }

    override func tearDown() {
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
        let updated = store.loadMessages(conversationId: convId).first!
        XCTAssertEqual(updated.status, .delivered)
        XCTAssertNotNil(updated.deliveredAt)
        XCTAssertEqual(updated.plaintext, "hello")
    }

    func test_wipeAll_clearsEverything() {
        store.upsertConversation(makeConv(id: convId))
        store.appendMessage(makeMsg(in: convId))
        store.wipeAll()
        XCTAssertTrue(store.loadConversations().isEmpty)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
    }
}

import XCTest
@testable import QAudionEngine

/// The same client message id can arrive twice, once over Bluetooth and once from the server. Both receive paths look the
/// id up before they show anything: the mesh path with `findByClientMsgId`, the server path with
/// `hasInboundMessage(clientMsgId:senderUserId:)`. These tests pin that both orders find the first copy.
final class ConversationStoreMeshDedupeTests: XCTestCase {

    private var store: ConversationStore!
    private let convId = UUID()

    override func setUp() {
        super.setUp()
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        let suite = "test.meshdedupe.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // swiftlint:disable:next force_unwrapping
        store = ConversationStore(defaults: UserDefaults(suiteName: suite)!)
        store.wipeAll()
        store.upsertConversation(Conversation(
            id: convId, peerUserId: "peer-a", peerDisplayName: "Peer", lastMessagePreview: nil,
            lastActivity: Date(timeIntervalSince1970: 1_745_000_000), unreadCount: 0, pinned: false))
    }

    override func tearDown() {
        LocalStoreCipher.testKeyOverride = nil
        store = nil
        super.tearDown()
    }

    private func incoming(clientMsgId: String, serverId: String?, viaMesh: Bool) -> Message {
        Message(id: UUID(), conversationId: convId, direction: .incoming, plaintext: "hi",
                sentAt: Date(timeIntervalSince1970: 1_745_000_000), deliveredAt: nil, readAt: nil,
                status: .delivered, senderUserId: "peer-a", serverMessageId: serverId,
                clientMsgId: clientMsgId, viaMesh: viaMesh)
    }

    func testMeshCopyThenServerCopyIsRecognisedByTheServerPath() {
        let cmid = UUID().uuidString
        store.appendMessage(incoming(clientMsgId: cmid, serverId: nil, viaMesh: true))
        XCTAssertTrue(store.hasInboundMessage(clientMsgId: cmid, senderUserId: "peer-a"))
    }

    func testServerCopyThenMeshCopyIsRecognisedByTheMeshPath() {
        let cmid = UUID().uuidString
        store.appendMessage(incoming(clientMsgId: cmid, serverId: "srv-1", viaMesh: false))
        XCTAssertNotNil(store.findByClientMsgId(cmid))
    }

    func testADifferentSenderWithTheSameIdIsNotADuplicateOnTheServerPath() {
        let cmid = UUID().uuidString
        store.appendMessage(incoming(clientMsgId: cmid, serverId: nil, viaMesh: true))
        XCTAssertFalse(store.hasInboundMessage(clientMsgId: cmid, senderUserId: "peer-b"))
    }
}

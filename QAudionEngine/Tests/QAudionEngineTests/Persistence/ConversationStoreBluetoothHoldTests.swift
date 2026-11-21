import XCTest
@testable import QAudionEngine

/// A row held for Bluetooth only is never in the network outbox's work list, and the hold lives on the row itself.
final class ConversationStoreBluetoothHoldTests: XCTestCase {

    private var store: ConversationStore!
    private let convId = UUID()

    override func setUp() {
        super.setUp()
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        let suite = "test.btholdstore.\(UUID().uuidString)"
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

    private func outgoing(_ id: UUID, hold: Bool?) -> Message {
        Message(id: id, conversationId: convId, direction: .outgoing, plaintext: "hi",
                sentAt: Date(timeIntervalSince1970: 1_745_000_000), deliveredAt: nil, readAt: nil, status: .sending,
                clientMsgId: id.uuidString, bluetoothHold: hold)
    }

    func testAHeldRowIsNeverInTheNetworkOutboxWorkList() {
        let held = UUID()
        let free = UUID()
        store.appendMessage(outgoing(held, hold: true))
        store.appendMessage(outgoing(free, hold: nil))
        XCTAssertEqual(store.loadPendingOutboundTextMessages().map { $0.id }, [free])
    }

    func testTheHoldIsWrittenWithTheRowAndSurvivesStatusChanges() {
        let id = UUID()
        store.appendMessage(outgoing(id, hold: true))
        store.updateMessageStatus(id: id, conversationId: convId, newStatus: .sent, viaMesh: true)
        store.updateMessageStatus(id: id, conversationId: convId, newStatus: .sending, viaMesh: false)
        XCTAssertEqual(store.findByClientMsgId(id.uuidString)?.message.bluetoothHold, true)
        XCTAssertTrue(store.loadPendingOutboundTextMessages().isEmpty)
    }

    func testOnlyClearingTheHoldReleasesTheRow() {
        let id = UUID()
        store.appendMessage(outgoing(id, hold: true))
        XCTAssertTrue(store.loadPendingOutboundTextMessages().isEmpty)
        store.setBluetoothHold(id: id, hold: false)
        XCTAssertEqual(store.loadPendingOutboundTextMessages().map { $0.id }, [id])
    }

    private func pendingMedia(_ id: UUID, kind: String) -> Message {
        Message(id: id, conversationId: convId, direction: .outgoing, plaintext: "x",
                sentAt: Date(timeIntervalSince1970: 1_745_000_000), deliveredAt: nil, readAt: nil, status: .sending,
                mediaMimeType: FileV2ChatBody.pendingMime(kind: kind), clientMsgId: id.uuidString, bluetoothHold: true)
    }

    func testAHeldAttachmentAndAHeldVoiceNoteKeepTheirHoldOnTheRow() {
        let file = UUID()
        let voice = UUID()
        store.appendMessage(pendingMedia(file, kind: "file"))
        store.appendMessage(pendingMedia(voice, kind: "voice"))
        store.updateMessageStatus(id: file, conversationId: convId, newStatus: .sending)
        XCTAssertEqual(store.findByClientMsgId(file.uuidString)?.message.bluetoothHold, true)
        XCTAssertEqual(store.findByClientMsgId(voice.uuidString)?.message.bluetoothHold, true)
        XCTAssertTrue(store.loadPendingOutboundTextMessages().isEmpty)
        store.setBluetoothHold(id: voice, hold: false)
        XCTAssertNil(store.findByClientMsgId(voice.uuidString)?.message.bluetoothHold)
        XCTAssertEqual(store.findByClientMsgId(file.uuidString)?.message.bluetoothHold, true)
    }

    func testHeldRowIdsFeedTheSweepOfKeptFiles() {
        let held = UUID()
        let free = UUID()
        let deleted = UUID()
        store.appendMessage(outgoing(held, hold: true))
        store.appendMessage(outgoing(free, hold: nil))
        store.appendMessage(outgoing(deleted, hold: true))
        store.applyDeleteByClientMsgId(deleted.uuidString)
        XCTAssertEqual(store.heldBluetoothRowIds(), [held])
    }

    func testAFailedRetryableRowKeepsItsFileInTheSweepSet() {
        let failedFile = UUID()
        let failedText = UUID()
        let sentFile = UUID()
        func pending(_ id: UUID, status: Message.Status) -> Message {
            Message(id: id, conversationId: convId, direction: .outgoing, plaintext: "x",
                    sentAt: Date(timeIntervalSince1970: 1_745_000_000), deliveredAt: nil, readAt: nil, status: status,
                    mediaMimeType: FileV2ChatBody.pendingMime(kind: "file"), clientMsgId: id.uuidString)
        }
        store.appendMessage(pending(failedFile, status: .failed))
        store.appendMessage(outgoing(failedText, hold: nil))
        store.updateMessageStatus(id: failedText, conversationId: convId, newStatus: .failed)
        store.appendMessage(pending(sentFile, status: .delivered))
        XCTAssertEqual(store.retainedHeldFileRowIds(), [failedFile])
        store.applyDeleteByClientMsgId(failedFile.uuidString)
        XCTAssertTrue(store.retainedHeldFileRowIds().isEmpty)
    }

    func testAForwardedRowIntoABluetoothOnlyChatIsWrittenHeld() {
        // The forward writes its row with the hold, like a typed message.
        let id = UUID()
        store.appendMessage(outgoing(id, hold: true))
        XCTAssertEqual(store.findByClientMsgId(id.uuidString)?.message.bluetoothHold, true)
        XCTAssertTrue(store.loadPendingOutboundTextMessages().isEmpty)
    }
}

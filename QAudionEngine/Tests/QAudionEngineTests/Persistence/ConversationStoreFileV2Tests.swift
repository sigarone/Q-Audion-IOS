import XCTest
@testable import QAudionEngine

/// File transfer v2 at the store: the inbound write boundary shows a file message as a file and never as the text it is
/// (WIRE_SPEC 12.7.1), and the row of a file being sent becomes the message that carries its descriptor.
final class ConversationStoreFileV2Tests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ConversationStore!
    private let convId = UUID()
    private let peer = "peer-1"

    override func setUp() {
        super.setUp()
        // Same seam as ConversationStoreInboundGateTests: no usable keychain in a simulator test bundle.
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        let suite = "test.filev2store.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // swiftlint:disable:next force_unwrapping
        defaults = UserDefaults(suiteName: suite)!
        store = ConversationStore(defaults: defaults)
        store.wipeAll()  // ConversationStore.db is a shared singleton; reset between tests
        store.upsertConversation(Conversation(
            id: convId, peerUserId: peer, peerDisplayName: "Peer", lastMessagePreview: nil,
            lastActivity: Date(timeIntervalSince1970: 1_745_000_000), unreadCount: 0, pinned: false))
    }

    override func tearDown() {
        LocalStoreCipher.testKeyOverride = nil
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func descriptorBody(name: String = "relazione.pdf") throws -> String {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: 2048)
        let source = FileV2Descriptor.Source(
            via: .srv, obj: "0a1b2c3d-0000-4000-8000-123456789abc",
            token: FileV2Descriptor.Token(v: String(repeating: "ab", count: 32), exp: 1_800_000_000_000, max: 30))
        return try FileV2DescriptorBuilder.build(FileV2DescriptorInput(
            file: FileV2FileInput(encryptor: encryptor, kind: .file, source: source, name: name)))
    }

    private func inbound(_ text: String, cmid: String = "cmid-1", server: String = "srv-1") -> Message {
        Message(id: UUID(), conversationId: convId, direction: .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil,
                status: .delivered, senderUserId: peer, serverMessageId: server, clientMsgId: cmid)
    }

    private func conversation() -> Conversation? {
        store.loadConversations().first(where: { $0.id == convId })
    }

    // MARK: Inbound

    func test_aValidDescriptor_isStoredWithItsBody_andShownAsAFile() throws {
        let body = try descriptorBody()
        let result = store.recordInboundUserMessage(inbound(body), preview: body, incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(store.loadMessages(conversationId: convId).map { $0.plaintext }, [body])   // the download needs it
        XCTAssertEqual(conversation()?.lastMessagePreview, "📎 relazione.pdf")
        XCTAssertEqual(conversation()?.unreadCount, 1)
    }

    func test_aControlMessage_hasNoRowNoPreviewAndNoUnread() {
        let cancel = #"{"qa_file_cancel":2,"id":"AAAAAAAAAAAAAAAAAAAAAA=="}"#
        let result = store.recordInboundUserMessage(inbound(cancel), preview: cancel, incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .refusedServiceShaped)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
        XCTAssertEqual(conversation()?.unreadCount, 0)
        XCTAssertNil(conversation()?.lastMessagePreview)
    }

    func test_aRejectedDescriptor_becomesItsPlaceholder_andItsContentIsNeverStored() {
        let hostile = #"{"qa_file":2,"id":"nope","note":"SECRET-CONTENT"}"#
        let result = store.recordInboundUserMessage(inbound(hostile), preview: hostile, incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .inserted)
        let rows = store.loadMessages(conversationId: convId)
        XCTAssertEqual(rows.map { $0.plaintext }, [FileV2ChatBody.invalidText])
        XCTAssertEqual(conversation()?.lastMessagePreview, FileV2ChatBody.invalidText)
        XCTAssertFalse(rows.contains { $0.plaintext.contains("SECRET-CONTENT") })
    }

    func test_aMessageOfAFutureVersion_becomesTheUpdateTheAppPlaceholder() {
        let future = #"{"qa_file":9,"anything":1}"#
        _ = store.recordInboundUserMessage(inbound(future), preview: future, incrementUnread: true, kind: .text)
        XCTAssertEqual(store.loadMessages(conversationId: convId).map { $0.plaintext }, [FileV2ChatBody.unsupportedText])
    }

    // MARK: Outbound

    func test_theRowOfAFileBeingSent_becomesTheMessageThatCarriesItsDescriptor() throws {
        let id = UUID()
        store.appendMessage(Message(
            id: id, conversationId: convId, direction: .outgoing, plaintext: FileV2ChatBody.glyph + "relazione.pdf",
            sentAt: Date(), deliveredAt: nil, readAt: nil, status: .sending,
            mediaMimeType: FileV2ChatBody.pendingMime, clientMsgId: id.uuidString))
        // while the file uploads, the row is out of the text outbox, so nothing can send its name as text
        XCTAssertFalse(store.loadPendingOutboundTextMessages().contains { $0.id == id })

        let body = try descriptorBody()
        store.replaceContent(id: id, plaintext: body, mediaMimeType: nil)
        let row = try XCTUnwrap(store.loadMessages(conversationId: convId).first { $0.id == id })
        XCTAssertEqual(row.plaintext, body)
        XCTAssertNil(row.mediaMimeType)
        XCTAssertEqual(row.status, .sending)
        XCTAssertEqual(row.clientMsgId, id.uuidString)
        // now the outbox may send (and re-send) it: it carries the descriptor
        XCTAssertTrue(store.loadPendingOutboundTextMessages().contains { $0.id == id })

        // a refused send puts the row back as a file that is being sent
        store.replaceContent(id: id, plaintext: FileV2ChatBody.glyph + "relazione.pdf", mediaMimeType: FileV2ChatBody.pendingMime)
        XCTAssertFalse(store.loadPendingOutboundTextMessages().contains { $0.id == id })
    }

    // MARK: Receipts (`qa_att_receipt:1`, keyed by the name of the file)

    private func inboundFile(_ body: String, wireId: String?, cmid: String = "cmid-f", server: String = "srv-f") -> Message {
        Message(id: UUID(), conversationId: convId, direction: .incoming, plaintext: body,
                sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil,
                status: .delivered, senderUserId: peer, serverMessageId: server, clientMsgId: cmid, wireAttachmentId: wireId)
    }

    func test_theNameOfTheReceipts_isStored_andReadBack() throws {
        // The column existed since the first attachment receipts, but the record mapping never wrote nor read it: a receipt could not
        // find the row it named.
        let body = try descriptorBody()
        let wireId = try XCTUnwrap(FileV2ChatBody.receiptId(ofBody: body))
        let row = inboundFile(body, wireId: wireId)
        XCTAssertEqual(store.recordInboundUserMessage(row, preview: body, incrementUnread: true, kind: .text), .inserted)
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.id, row.id)
        XCTAssertEqual(store.loadMessages(conversationId: convId).first?.wireAttachmentId, wireId)
        XCTAssertNil(store.messageByWireAttachmentId("00000000-0000-0000-0000-000000000000"))
    }

    func test_aFileKeepsTheNameOfItsReceipts_throughTheLaterUpdatesOfItsRow() throws {
        let body = try descriptorBody()
        let wireId = try XCTUnwrap(FileV2ChatBody.receiptId(ofBody: body))
        let row = inboundFile(body, wireId: wireId)
        XCTAssertEqual(store.recordInboundUserMessage(row, preview: body, incrementUnread: false, kind: .text), .inserted)

        store.setMediaInfo(localId: row.id, conversationId: convId, plaintext: nil, mediaLocalPath: "/caches/f.bin",
                           mediaDurationMs: nil, mediaMimeType: nil)
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.mediaLocalPath, "/caches/f.bin")

        store.updateMessageStatus(id: row.id, conversationId: convId, newStatus: .read, readAt: Date())
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.status, .read)

        XCTAssertEqual(store.applyReactionToggleByClientMsgId("cmid-f", userId: "u1", emoji: "👍"), true)
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.reactions?["👍"], ["u1"])

        store.markViewOnceOpened(messageId: row.id, conversationId: convId)
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.viewOnceOpened, true)
    }

    func test_theRowOfAFileSent_isFoundByItsReceiptName_andKeepsItWhenTheServerIdIsBound() throws {
        let id = UUID()
        store.appendMessage(Message(
            id: id, conversationId: convId, direction: .outgoing, plaintext: FileV2ChatBody.glyph + "relazione.pdf",
            sentAt: Date(), deliveredAt: nil, readAt: nil, status: .sending,
            mediaMimeType: FileV2ChatBody.pendingMime, clientMsgId: id.uuidString))
        let body = try descriptorBody()
        let wireId = try XCTUnwrap(FileV2ChatBody.receiptId(ofBody: body))
        // the order of the send: the row becomes the descriptor message, then the server id is set, then the self echo binds the real one
        store.replaceContent(id: id, plaintext: body, mediaMimeType: nil)
        store.setWireAttachmentId(id: id, wireAttachmentId: wireId)
        store.setServerMessageId(localId: id, conversationId: convId, serverMessageId: id.uuidString)
        XCTAssertTrue(store.bindServerMessageId(clientMsgId: id.uuidString, serverMessageId: "srv-real"))

        let found = try XCTUnwrap(store.messageByWireAttachmentId(wireId))
        XCTAssertEqual(found.id, id)
        XCTAssertEqual(found.serverMessageId, "srv-real")
        XCTAssertEqual(found.plaintext, body)
        // and the receipts of the transport (`msg_delivered`, keyed by the server id) still reach the same row
        XCTAssertTrue(store.updateStatusByServerId(serverMessageId: "srv-real", newStatus: .read, readAt: Date()))
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.status, .read)
    }

    func test_aResentFile_thatRepairsAPlaceholder_keepsTheNameOfItsReceipts() throws {
        let placeholder = Message(
            id: UUID(), conversationId: convId, direction: .incoming, plaintext: InboundMessagePolicy.undecryptablePlaceholderText,
            sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil, status: .delivered,
            senderUserId: peer, serverMessageId: "srv-p", clientMsgId: "cmid-r", isPlaceholder: true)
        XCTAssertEqual(store.recordInboundUserMessage(placeholder, preview: placeholder.plaintext, incrementUnread: true,
                                                     kind: .placeholder), .inserted)
        let body = try descriptorBody()
        let wireId = try XCTUnwrap(FileV2ChatBody.receiptId(ofBody: body))
        let resent = inboundFile(body, wireId: wireId, cmid: "cmid-r", server: "srv-r")
        XCTAssertEqual(store.recordInboundUserMessage(resent, preview: body, incrementUnread: true, kind: .text), .replacedPlaceholder)
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.id, placeholder.id)
        XCTAssertEqual(store.messageByWireAttachmentId(wireId)?.plaintext, body)
    }

    func test_theRowOfAnImageOrAVoiceNote_withItsLocalCopy_isStillInTheTextOutbox() throws {
        // the sender's own bubble shows the local copy of the file (`mediaLocalPath`); the row is the descriptor message all the same
        let id = UUID()
        let body = try descriptorBody()
        store.appendMessage(Message(
            id: id, conversationId: convId, direction: .outgoing, plaintext: body, sentAt: Date(), deliveredAt: nil,
            readAt: nil, status: .sending, mediaLocalPath: "/caches/images/x.jpg", clientMsgId: id.uuidString))
        XCTAssertTrue(store.loadPendingOutboundTextMessages().contains { $0.id == id })

        // a row with a local copy and ordinary text is an attachment of the old kind and stays out
        let other = UUID()
        store.appendMessage(Message(
            id: other, conversationId: convId, direction: .outgoing, plaintext: "📷 Foto", sentAt: Date(), deliveredAt: nil,
            readAt: nil, status: .sending, mediaLocalPath: "/caches/images/y.jpg", clientMsgId: other.uuidString))
        XCTAssertFalse(store.loadPendingOutboundTextMessages().contains { $0.id == other })

        // and while it is a pending file of any kind it never is
        let pending = UUID()
        store.appendMessage(Message(
            id: pending, conversationId: convId, direction: .outgoing, plaintext: "📷 Foto", sentAt: Date(), deliveredAt: nil,
            readAt: nil, status: .sending, mediaLocalPath: "/caches/images/z.jpg",
            mediaMimeType: FileV2ChatBody.pendingMime(kind: "image"), clientMsgId: pending.uuidString))
        XCTAssertFalse(store.loadPendingOutboundTextMessages().contains { $0.id == pending })
    }
}

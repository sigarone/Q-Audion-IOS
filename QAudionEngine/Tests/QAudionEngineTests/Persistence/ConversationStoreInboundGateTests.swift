import XCTest
@testable import QAudionEngine

/// 2026-09-19 service-message root fix — the store-level tripwire for inbound
/// USER messages (`recordInboundUserMessage`): it refuses service-shaped
/// text, writes the row + preview + unread in one transaction, records the one
/// undecryptable-frame placeholder, and lets a resend of the same
/// `client_msg_id` replace that placeholder in place.
final class ConversationStoreInboundGateTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ConversationStore!
    private let convId = UUID()
    private let peer = "peer-1"
    private let placeholderText = InboundMessagePolicy.undecryptablePlaceholderText

    override func setUp() {
        super.setUp()
        // Same seam as ConversationStoreTests: a simulator test bundle has no
        // usable keychain, so the at-rest cipher gets an injected key.
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        let suite = "test.inboundgate.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // Suite name is a freshly generated, well-formed non-empty string; UserDefaults(suiteName:) never returns nil for it.
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

    private func inbound(_ text: String, cmid: String? = "cmid-1", server: String = "srv-1",
                         sender: String? = nil, placeholder: Bool = false,
                         sentAt: TimeInterval = 1_745_000_100) -> Message {
        Message(id: UUID(), conversationId: convId, direction: .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: sentAt), deliveredAt: Date(), readAt: nil,
                status: .delivered, senderUserId: sender ?? peer, serverMessageId: server,
                clientMsgId: cmid, isPlaceholder: placeholder ? true : nil)
    }

    private func conversation() -> Conversation? {
        store.loadConversations().first(where: { $0.id == convId })
    }

    private let serviceJson = "{\"qa_ctl\":1,\"t\":\"decrypt_nack\",\"target\":\"x\",\"ts\":1}"

    // MARK: - Tripwire

    func test_serviceShapedBody_isRefused_andNothingIsWritten() {
        let msg = inbound(serviceJson)
        let result = store.recordInboundUserMessage(msg, preview: msg.plaintext, incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .refusedServiceShaped)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
        XCTAssertEqual(conversation()?.unreadCount, 0)
        XCTAssertNotEqual(conversation()?.lastMessagePreview, serviceJson)
    }

    func test_serviceShapedPreview_isRefused_evenWithAFriendlyBody() {
        let msg = inbound("🎤 Nota vocale")
        let result = store.recordInboundUserMessage(msg, preview: serviceJson, incrementUnread: true, kind: .attachment)
        XCTAssertEqual(result, .refusedServiceShaped)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
    }

    func test_everyServiceKey_isRefused() {
        for key in ServicePayloadDetector.serviceKeys {
            let msg = inbound("{\"\(key)\":1}", cmid: UUID().uuidString, server: UUID().uuidString)
            let result = store.recordInboundUserMessage(msg, preview: "x", incrementUnread: true, kind: .text)
            XCTAssertEqual(result, .refusedServiceShaped, "key=\(key)")
        }
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
    }

    func test_assertOnRefusal_isOffByDefault_soTheTripwireDoesNotCrashTests() {
        XCTAssertFalse(ConversationStore.assertOnServiceRefusal)
    }

    // MARK: - Normal writes

    func test_text_isInserted_withPreviewAndUnread() {
        let result = store.recordInboundUserMessage(inbound("ciao"), preview: "ciao", incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(store.loadMessages(conversationId: convId).map { $0.plaintext }, ["ciao"])
        XCTAssertEqual(conversation()?.unreadCount, 1)
        XCTAssertEqual(conversation()?.lastMessagePreview, "ciao")
    }

    func test_muted_incrementUnreadFalse_leavesUnreadUntouched() {
        _ = store.recordInboundUserMessage(inbound("ciao"), preview: "ciao", incrementUnread: false, kind: .text)
        XCTAssertEqual(conversation()?.unreadCount, 0)
        XCTAssertEqual(conversation()?.lastMessagePreview, "ciao")
    }

    func test_longPreview_isTruncatedTo120Characters() {
        let long = String(repeating: "x", count: 300)
        _ = store.recordInboundUserMessage(inbound(long), preview: long, incrementUnread: true, kind: .text)
        XCTAssertEqual(conversation()?.lastMessagePreview?.count, 121)
    }

    func test_screenshotGrant_isCarriedForward() {
        store.setScreenshotGranted(conversationId: convId, granted: true)
        _ = store.recordInboundUserMessage(inbound("ciao"), preview: "ciao", incrementUnread: true, kind: .text)
        XCTAssertEqual(conversation()?.screenshotGrantedByPeer, true)
    }

    // MARK: - Placeholder

    func test_placeholder_isRecordedFlagged_andCountsUnread() {
        let result = store.recordInboundUserMessage(
            inbound(placeholderText, placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        XCTAssertEqual(result, .inserted)
        let rows = store.loadMessages(conversationId: convId)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.isPlaceholder, true)
        XCTAssertEqual(rows.first?.plaintext, placeholderText)
        XCTAssertEqual(conversation()?.unreadCount, 1)
    }

    func test_secondPlaceholderForTheSameClientId_isADuplicate() {
        _ = store.recordInboundUserMessage(
            inbound(placeholderText, placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        let again = store.recordInboundUserMessage(
            inbound(placeholderText, server: "srv-2", placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        XCTAssertEqual(again, .duplicatePlaceholder)
        XCTAssertEqual(store.loadMessages(conversationId: convId).count, 1)
        XCTAssertEqual(conversation()?.unreadCount, 1, "no double count")
    }

    func test_resendReplacesThePlaceholderInPlace() {
        let placeholder = inbound(placeholderText, server: "srv-1", placeholder: true, sentAt: 1_745_000_100)
        _ = store.recordInboundUserMessage(
            placeholder, preview: placeholderText, incrementUnread: true, kind: .placeholder)

        let resend = inbound("il vero messaggio", server: "srv-2", sentAt: 1_745_000_900)
        let result = store.recordInboundUserMessage(
            resend, preview: "il vero messaggio", incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .replacedPlaceholder)

        let rows = store.loadMessages(conversationId: convId)
        XCTAssertEqual(rows.count, 1, "no second row")
        XCTAssertEqual(rows.first?.id, placeholder.id, "the SAME row")
        XCTAssertEqual(rows.first?.plaintext, "il vero messaggio")
        XCTAssertNil(rows.first?.isPlaceholder)
        XCTAssertEqual(rows.first?.sentAt, placeholder.sentAt, "keeps its place in the history")
        XCTAssertEqual(rows.first?.serverMessageId, "srv-2")
        XCTAssertEqual(rows.first?.clientMsgId, "cmid-1")
        XCTAssertEqual(conversation()?.unreadCount, 1, "unread is not counted twice")
        XCTAssertEqual(conversation()?.lastMessagePreview, "il vero messaggio")
    }

    func test_resendFromAnotherSender_doesNotReplace() {
        _ = store.recordInboundUserMessage(
            inbound(placeholderText, placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        let result = store.recordInboundUserMessage(
            inbound("hi", server: "srv-2", sender: "someone-else"), preview: "hi",
            incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(store.loadMessages(conversationId: convId).count, 2)
    }

    func test_attachmentReplacesThePlaceholder_withoutCountingUnreadTwice() {
        let placeholder = inbound(placeholderText, placeholder: true)
        _ = store.recordInboundUserMessage(
            placeholder, preview: placeholderText, incrementUnread: true, kind: .placeholder)
        let attachment = inbound("\u{1F4CE} Allegato", server: "srv-2")
        let result = store.recordInboundUserMessage(
            attachment, preview: "\u{1F4CE} Allegato", incrementUnread: true, kind: .attachment)
        XCTAssertEqual(result, .replacedPlaceholder)
        let rows = store.loadMessages(conversationId: convId)
        XCTAssertEqual(rows.count, 1, "the placeholder is gone, one row remains")
        XCTAssertEqual(rows.first?.id, attachment.id, "the new row keeps ITS id: media binds to it")
        XCTAssertEqual(conversation()?.unreadCount, 1)
        XCTAssertEqual(conversation()?.lastMessagePreview, "\u{1F4CE} Allegato")
    }

    func test_deletedPlaceholder_isNotResurrectedByAResend() {
        _ = store.recordInboundUserMessage(
            inbound(placeholderText, placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        XCTAssertTrue(store.applyDeleteByClientMsgId("cmid-1"))

        let result = store.recordInboundUserMessage(
            inbound("il testo cancellato", server: "srv-2"), preview: "il testo cancellato",
            incrementUnread: true, kind: .text)

        XCTAssertNotEqual(result, .replacedPlaceholder, "a tombstone is never overwritten by a resend")
        let tombstone = store.loadMessages(conversationId: convId).first(where: { $0.deletedAt != nil })
        XCTAssertNotNil(tombstone)
        XCTAssertNil(tombstone?.isPlaceholder, "a deleted row is an ordinary tombstone")
        XCTAssertEqual(tombstone?.plaintext, "Messaggio eliminato")
    }

    func test_editedPlaceholder_becomesAnOrdinaryRow_andIsNotOverwrittenByAResend() {
        _ = store.recordInboundUserMessage(
            inbound(placeholderText, placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        XCTAssertTrue(store.applyEditByClientMsgId("cmid-1", newPlaintext: "testo corretto"))

        _ = store.recordInboundUserMessage(
            inbound("testo originale", server: "srv-2"), preview: "testo originale",
            incrementUnread: true, kind: .text)

        let edited = store.loadMessages(conversationId: convId).first(where: { $0.edited })
        XCTAssertEqual(edited?.plaintext, "testo corretto")
        XCTAssertNil(edited?.isPlaceholder)
    }

    func test_placeholderNextToAnExistingRealRow_isADuplicate() {
        _ = store.recordInboundUserMessage(
            inbound("ciao", server: "srv-1"), preview: "ciao", incrementUnread: true, kind: .text)
        let result = store.recordInboundUserMessage(
            inbound(placeholderText, server: "srv-2", placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        XCTAssertEqual(result, .duplicatePlaceholder)
        XCTAssertEqual(store.loadMessages(conversationId: convId).count, 1)
        XCTAssertEqual(conversation()?.unreadCount, 1)
    }

    func test_rawAttachmentAnnounceJson_isRefusedAsBodyAndAsPreview() {
        let announce = "{\"qa_ctl\":1,\"t\":\"attach_announce\",\"att\":{\"id\":\"f\"}}"
        let asBody = store.recordInboundUserMessage(
            inbound(announce), preview: "\u{1F4CE} Allegato", incrementUnread: true, kind: .attachment)
        XCTAssertEqual(asBody, .refusedServiceShaped)
        let asPreview = store.recordInboundUserMessage(
            inbound("\u{1F4CE} Allegato", server: "srv-2"), preview: announce,
            incrementUnread: true, kind: .attachment)
        XCTAssertEqual(asPreview, .refusedServiceShaped)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
    }

    func test_placeholderFlag_survivesAStatusUpdate() {
        let placeholder = inbound(placeholderText, placeholder: true)
        _ = store.recordInboundUserMessage(
            placeholder, preview: placeholderText, incrementUnread: true, kind: .placeholder)
        store.updateMessageStatus(id: placeholder.id, conversationId: convId, newStatus: .read, readAt: Date())
        XCTAssertEqual(store.loadMessages(conversationId: convId).first?.isPlaceholder, true)
    }

    // MARK: - Pre-decrypt dedup

    func test_dedup_clientIdIgnoresPlaceholders_serverIdDoesNot() {
        _ = store.recordInboundUserMessage(
            inbound(placeholderText, cmid: "cmid-p", server: "srv-p", placeholder: true),
            preview: placeholderText, incrementUnread: true, kind: .placeholder)
        XCTAssertFalse(store.hasInboundMessage(clientMsgId: "cmid-p", senderUserId: peer),
                       "a placeholder must never swallow the resend that repairs it")
        XCTAssertTrue(store.hasInboundMessage(serverMessageId: "srv-p"),
                      "but a replay of the very same failed frame is still a duplicate")

        _ = store.recordInboundUserMessage(
            inbound("hi", cmid: "cmid-n", server: "srv-n"), preview: "hi", incrementUnread: true, kind: .text)
        XCTAssertTrue(store.hasInboundMessage(clientMsgId: "cmid-n", senderUserId: peer))
    }

    func test_dedup_countsTheRowOnceItWasReplaced() {
        _ = store.recordInboundUserMessage(
            inbound(placeholderText, placeholder: true), preview: placeholderText,
            incrementUnread: true, kind: .placeholder)
        _ = store.recordInboundUserMessage(
            inbound("vero", server: "srv-2"), preview: "vero", incrementUnread: true, kind: .text)
        XCTAssertTrue(store.hasInboundMessage(clientMsgId: "cmid-1", senderUserId: peer))
    }

    // MARK: - Model

    func test_message_decodesFromJsonWithoutThePlaceholderKey() throws {
        let data = try JSONEncoder().encode(inbound("x"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("isPlaceholder"))
        let back = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertNil(back.isPlaceholder)
    }
}

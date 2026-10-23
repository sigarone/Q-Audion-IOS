import XCTest
@testable import QAudionEngine

/// The write boundary of an inbound 1:1 message for a location body (WIRE_SPEC 14.3.2, 14.3.3, 14.6.2 step 6): a pin keeps its body, a
/// live start keeps its local form and NEVER its key, a rejected body is one placeholder. Also the edit guard of the store (14.3.6).
final class LocationInboundBoundaryTests: XCTestCase {

    private let sid = Data((0..<16).map { UInt8($0 + 1) })
    private let key = Data((32..<64).map { UInt8($0) })

    override func setUp() {
        super.setUp()
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
    }

    override func tearDown() {
        LocalStoreCipher.testKeyOverride = nil
        super.tearDown()
    }

    private func fix() -> LocationFix {
        LocationFix(latitude: 45.4642110, longitude: 9.1899820, horizontalAccuracy: 12, elapsedMs: 3_000, approximate: false)
    }

    private func pin() throws -> String {
        guard case .success(let text) = LocationCodec.buildPin(fix: fix()) else { throw XCTSkip("builder refused") }
        return text
    }

    private func live() throws -> String {
        guard case .success(let text) = LocationCodec.buildLiveStart(fix: fix(), sid: sid, key: key, startedAt: 1_000, duration: 3_600) else {
            throw XCTSkip("builder refused")
        }
        return text
    }

    private func inbound(_ text: String, expiresAt: Date? = nil, viewOnce: Bool? = nil, viaMesh: Bool? = nil) -> Message {
        Message(id: UUID(), conversationId: UUID(), direction: .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil, status: .delivered,
                senderUserId: "peer-1", serverMessageId: "srv-1", clientMsgId: "cmid-1", expiresAt: expiresAt,
                isViewOnce: viewOnce, viaMesh: viaMesh)
    }

    func testAPinKeepsItsBodyAndShowsTheLabel() throws {
        let body = try pin()
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound(body), preview: body))
        XCTAssertEqual(applied.message.plaintext, body)
        XCTAssertEqual(applied.preview, LocationLabels.text(.pin))
        XCTAssertFalse(applied.preview.contains("454642110"))
    }

    func testAPinIsNeverViewOnceButFollowsTheTimer() throws {
        let expiry = Date(timeIntervalSince1970: 1_745_003_600)
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound(try pin(), expiresAt: expiry, viewOnce: true), preview: ""))
        XCTAssertNil(applied.message.isViewOnce)
        XCTAssertEqual(applied.message.expiresAt, expiry)
    }

    func testALiveStartKeepsItsLocalFormAndNeverItsKey() throws {
        let body = try live()
        XCTAssertTrue(body.contains(key.base64EncodedString()), "the wire body carries the key")
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound(body), preview: body))
        XCTAssertFalse(applied.message.plaintext.contains(key.base64EncodedString()), "no row ever holds the key")
        XCTAssertFalse(applied.message.plaintext.contains("454642110"), "and no position")
        XCTAssertEqual(applied.message.plaintext, LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600))
        XCTAssertEqual(applied.preview, LocationLabels.text(.live))
        XCTAssertFalse(applied.preview.contains("454642110"))
    }

    /// A live share is exempt from the timer of the conversation while it runs.
    func testALiveRowIsExemptFromTheTimerAndNeverViewOnce() throws {
        let expiry = Date(timeIntervalSince1970: 1_745_003_600)
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound(try live(), expiresAt: expiry, viewOnce: true), preview: ""))
        XCTAssertNil(applied.message.expiresAt)
        XCTAssertNil(applied.message.isViewOnce)
    }

    func testALiveStartOverTheMeshIsOnePlaceholder() throws {
        let body = try live()
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound(body, viaMesh: true), preview: body))
        XCTAssertEqual(applied.message.plaintext, LocationBodyPlaceholder.text(.unavailable))
        XCTAssertEqual(applied.preview, applied.message.plaintext)
        XCTAssertFalse(applied.message.plaintext.contains(key.base64EncodedString()))
    }

    func testARejectedBodyIsOnePlaceholderAndNeverItsContent() throws {
        let bad = #"{"qa_loc":1,"m":"pin","lat":454642110,"lon":91899820,"acc":0,"age":3,"ap":0}"#
        let rejected = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound(bad), preview: bad))
        XCTAssertEqual(rejected.message.plaintext, LocationBodyPlaceholder.text(.unavailable))
        XCTAssertFalse(rejected.message.plaintext.contains("454642110"))
        XCTAssertEqual(rejected.preview, rejected.message.plaintext)

        let newer = #"{"qa_loc":2,"m":"pin","lat":454642110,"lon":91899820}"#
        let update = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound(newer), preview: newer))
        XCTAssertEqual(update.message.plaintext, LocationBodyPlaceholder.text(.unsupportedVersion))
    }

    func testOrdinaryTextIsUntouched() throws {
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(inbound("ciao"), preview: "ciao"))
        XCTAssertEqual(applied.message.plaintext, "ciao")
        XCTAssertEqual(applied.preview, "ciao")
    }

    // MARK: The store

    private func freshStore() -> (ConversationStore, UUID) {
        let suite = "test.locationboundary.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        // swiftlint:disable:next force_unwrapping
        let store = ConversationStore(defaults: UserDefaults(suiteName: suite)!)
        store.wipeAll()
        let conversation = UUID()
        store.upsertConversation(Conversation(
            id: conversation, peerUserId: "peer-1", peerDisplayName: "Peer", lastMessagePreview: nil,
            lastActivity: Date(timeIntervalSince1970: 1_745_000_000), unreadCount: 0, pinned: false))
        return (store, conversation)
    }

    func testTheStoreWritesTheLocalFormAndTheLabelPreview() throws {
        let (store, conversation) = freshStore()
        let message = Message(id: UUID(), conversationId: conversation, direction: .incoming, plaintext: try live(),
                              sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil,
                              status: .delivered, senderUserId: "peer-1", serverMessageId: "srv-1", clientMsgId: "cmid-1")
        XCTAssertEqual(store.recordInboundUserMessage(message, preview: message.plaintext, incrementUnread: true, kind: .text), .inserted)
        let rows = store.loadMessages(conversationId: conversation)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].plaintext.contains(key.base64EncodedString()))
        let preview = store.loadConversations().first(where: { $0.id == conversation })?.lastMessagePreview
        XCTAssertEqual(preview, LocationLabels.text(.live))
    }

    func testAnEditNeverTouchesALocationRowNorTurnsARowIntoOne() throws {
        let (store, conversation) = freshStore()
        let pinBody = try pin()
        let pinRow = Message(id: UUID(), conversationId: conversation, direction: .incoming, plaintext: pinBody,
                             sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil,
                             status: .delivered, senderUserId: "peer-1", serverMessageId: "srv-1", clientMsgId: "cmid-pin")
        store.appendMessage(pinRow)
        XCTAssertFalse(store.applyEditByClientMsgId("cmid-pin", newPlaintext: "ciao"), "a pin never changes")
        XCTAssertEqual(store.loadMessages(conversationId: conversation).first?.plaintext, pinBody)

        let textRow = Message(id: UUID(), conversationId: conversation, direction: .incoming, plaintext: "prima",
                              sentAt: Date(timeIntervalSince1970: 1_745_000_200), deliveredAt: Date(), readAt: nil,
                              status: .delivered, senderUserId: "peer-1", serverMessageId: "srv-2", clientMsgId: "cmid-text")
        store.appendMessage(textRow)
        XCTAssertFalse(store.applyEditByClientMsgId("cmid-text", newPlaintext: pinBody), "text never becomes a pin")
        XCTAssertTrue(store.applyEditByClientMsgId("cmid-text", newPlaintext: "dopo"))
    }

    /// The row of an own live start still holds the FULL start body (the key included) until the echo: a backup never takes it.
    func testABackupHoldsTheLocalFormOfAnOwnStartAndNothingElseChanges() throws {
        let outgoing = Message(id: UUID(), conversationId: UUID(), direction: .outgoing, plaintext: try live(),
                               sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: nil, readAt: nil,
                               status: .sending, clientMsgId: "cmid-own", expiresAt: nil)
        let saved = LocationBackupBody.normalised(outgoing)
        XCTAssertEqual(saved.plaintext, LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600))
        XCTAssertFalse(saved.plaintext.contains(key.base64EncodedString()))
        XCTAssertEqual(saved.id, outgoing.id)
        XCTAssertEqual(saved.clientMsgId, "cmid-own")
        XCTAssertEqual(saved.status, .sending)
        XCTAssertEqual(saved.direction, .outgoing)
        // A text message is returned as it is, and so is a pin.
        let text = Message(id: UUID(), conversationId: UUID(), direction: .outgoing, plaintext: "ciao",
                           sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: nil, readAt: nil, status: .delivered)
        XCTAssertEqual(LocationBackupBody.normalised(text), text)
        let pinRow = Message(id: UUID(), conversationId: UUID(), direction: .outgoing, plaintext: try pin(),
                             sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: nil, readAt: nil, status: .delivered)
        XCTAssertEqual(LocationBackupBody.normalised(pinRow), pinRow)
        // A body that cannot be read back becomes the placeholder, never its content.
        let junk = Message(id: UUID(), conversationId: UUID(), direction: .incoming, plaintext: "{\"qa_loc\":1,\"m\":\"live\",\"k\":\"AAAA\"}",
                           sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil, status: .delivered,
                           senderUserId: "peer-1", serverMessageId: "srv-9", clientMsgId: "cmid-9")
        XCTAssertEqual(LocationBackupBody.normalised(junk).plaintext, LocationBodyPlaceholder.text(.unavailable))
    }

    func testTheExpiryOfARowCanBeSetWhenAShareEnds() throws {
        let (store, conversation) = freshStore()
        let row = Message(id: UUID(), conversationId: conversation, direction: .incoming,
                          plaintext: LocationRowForm.localForm(sid: sid, startedAt: 1_000, duration: 3_600),
                          sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil,
                          status: .delivered, senderUserId: "peer-1", serverMessageId: "srv-1", clientMsgId: "cmid-1")
        store.appendMessage(row)
        XCTAssertNil(store.loadMessages(conversationId: conversation).first?.expiresAt)
        let expiry = Date(timeIntervalSince1970: 1_745_090_000)
        store.setExpiresAt(messageId: row.id, expiresAt: expiry)
        let reloaded = try XCTUnwrap(store.loadMessages(conversationId: conversation).first)
        XCTAssertEqual(reloaded.expiresAt, expiry)
        XCTAssertEqual(reloaded.plaintext, row.plaintext)
        XCTAssertEqual(reloaded.clientMsgId, "cmid-1")
    }
}

import XCTest
@testable import QAudionEngine

/// The behaviour of message replies (WIRE_SPEC section 13) that the shared vector file cannot pin because it depends on the state of a
/// platform: which rows can be answered, what the builder takes from them, ephemeral messages, the entry-point rule, the write boundary
/// and the quote block of a received reply. The vectors themselves run in `MessageReplyKatTests`.
///
/// This code was written on a machine that cannot compile Swift: the macOS CI job is the only thing that has run it.
final class MessageReplyLocalTests: XCTestCase {

    private let conversation = UUID()
    private let serverId = "73740a4d-0d1e-4f08-9f38-5ba1b8fe4472"
    private let otherServerId = "0a1b2c3d-0000-4000-8000-123456789abc"

    private func row(_ text: String, outgoing: Bool = false, server: String? = nil, deletedAt: Date? = nil,
                     expiresAt: Date? = nil, viewOnce: Bool? = nil, viaMesh: Bool? = nil, placeholder: Bool? = nil,
                     mime: String? = nil, durationMs: Int64? = nil) -> Message {
        Message(id: UUID(), conversationId: conversation, direction: outgoing ? .outgoing : .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: 1_745_000_000), deliveredAt: nil, readAt: nil,
                status: outgoing ? .sent : .delivered, serverMessageId: server ?? serverId, mediaDurationMs: durationMs,
                mediaMimeType: mime,
                deletedAt: deletedAt, expiresAt: expiresAt, isViewOnce: viewOnce, viaMesh: viaMesh,
                isPlaceholder: placeholder)
    }

    private func withoutServerId(_ message: Message) -> Message {
        Message(id: message.id, conversationId: message.conversationId, direction: message.direction,
                plaintext: message.plaintext, sentAt: message.sentAt, deliveredAt: nil, readAt: nil, status: message.status)
    }

    private func fileBody(kind: FileV2Descriptor.Kind, name: String?, ex: Int64? = nil) throws -> String {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: 2048)
        let source = FileV2Descriptor.Source(
            via: .srv, obj: "0a1b2c3d-0000-4000-8000-123456789abc",
            token: FileV2Descriptor.Token(v: String(repeating: "ab", count: 32), exp: 1_800_000_000_000, max: 30))
        return try FileV2DescriptorBuilder.build(FileV2DescriptorInput(
            file: FileV2FileInput(encryptor: encryptor, kind: kind, source: source, name: name, ex: ex)))
    }

    private func replyBody(to: String? = nil, kind: String = "text", quoteSource: String = "ciao", body: String = "risposta") throws -> String {
        let result = MessageReplyCodec.build(to: to ?? serverId, kind: kind, quoteSource: quoteSource,
                                             quotedIsEphemeral: false, body: body)
        guard case .success(let text) = result else {
            XCTFail("the builder refused: \(result)")
            return ""
        }
        return text
    }

    // MARK: The entry-point rule (13.5)

    func test_textTheUserTypes_mayNotBeAReply_norAFile() throws {
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(try replyBody()))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_reply":1}"#))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_reply":9,"x":1}"#))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_file":2,"id":"x"}"#))
        XCTAssertTrue(FileV2ChatBody.isUserTextAllowed(#"ciao {"qa_reply":1}"#))
        XCTAssertTrue(FileV2ChatBody.isUserTextAllowed(#" {"qa_reply":1}"#))
        XCTAssertTrue(FileV2ChatBody.isUserTextAllowed(#"{ "qa_reply":1}"#))
    }

    func test_theBuilder_refusesABodyThatBeginsWithAReservedPrefix_andAnEmptyOne() {
        func refusal(_ body: String) -> MessageReplyRefusal? {
            if case .failure(let reason) = MessageReplyCodec.build(to: serverId, kind: "text", quoteSource: "x",
                                                                    quotedIsEphemeral: false, body: body) {
                return reason
            }
            return nil
        }
        XCTAssertEqual(refusal(""), .bodyEmpty)
        XCTAssertEqual(refusal(#"{"qa_reply":1,"to":"x"}"#), .bodyPrefix)
        XCTAssertEqual(refusal(#"{"qa_file":2}"#), .bodyPrefix)
        XCTAssertEqual(refusal(#"{"qa_file_src":2}"#), .bodyPrefix)
        XCTAssertEqual(refusal(#"{"qa_file_cancel":2}"#), .bodyPrefix)
        XCTAssertNil(refusal(#"x {"qa_reply":1}"#))
    }

    func test_theBuilder_neverShortensTheBodyOrTheQuote_itRefusesInstead() {
        // 8191 bytes fit, 8192 do not; the escapes count (each quote is two bytes in the object).
        let overhead = #"{"qa_reply":1,"to":"73740a4d-0d1e-4f08-9f38-5ba1b8fe4472","k":"text","q":"","b":""}"#.utf8.count
        let fits = String(repeating: "a", count: 8191 - overhead)
        let tooLong = String(repeating: "a", count: 8192 - overhead)
        if case .success(let text) = MessageReplyCodec.build(to: serverId, kind: "text", quoteSource: nil, quotedIsEphemeral: false,
                                                             body: fits) {
            XCTAssertEqual(text.utf8.count, 8191)
        } else {
            XCTFail("8191 bytes must fit")
        }
        XCTAssertEqual(MessageReplyCodec.build(to: serverId, kind: "text", quoteSource: nil, quotedIsEphemeral: false, body: tooLong),
                       .failure(.size))
        // A multi-byte body counts in BYTES, not characters.
        let emoji = String(repeating: "\u{1F600}", count: 2100)
        XCTAssertEqual(MessageReplyCodec.build(to: serverId, kind: "text", quoteSource: nil, quotedIsEphemeral: false, body: emoji),
                       .failure(.size))
    }

    // MARK: What a reply shows

    func test_aReply_isShownAsItsBody_everywhereElseThanTheBubbleQuote() throws {
        let body = try replyBody(quoteSource: "originale", body: "la mia risposta")
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: body), "la mia risposta")
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: "ciao"), "ciao")
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: ""), "")
        // A rejected reply is not lost: the whole body is the text.
        let broken = #"{"qa_reply":1,"to":"nope","k":"text","q":"","b":"x"}"#
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: broken), broken)
        // `b` is never recognised again: a b that begins with a prefix is displayed as text.
        let inner = #"{"qa_file":2,"id":"x"}"#
        let wire = #"{"qa_reply":1,"to":"73740a4d-0d1e-4f08-9f38-5ba1b8fe4472","k":"text","q":"","b":"{\"qa_file\":2,\"id\":\"x\"}"}"#
        XCTAssertEqual(MessageReplyCodec.shownText(ofBody: wire), inner)
    }

    func test_aReplyIsStillOrdinaryTextForTheFileFormat() throws {
        XCTAssertEqual(FileV2ChatBody.classify(text: try replyBody()), .text)
    }

    func test_theWriteBoundary_keepsTheBodyAsReceived_andPreviewsB() throws {
        let body = try replyBody(quoteSource: "originale", body: "la mia risposta")
        let message = row(body)
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(message, preview: body))
        XCTAssertEqual(applied.message.plaintext, body)          // the row keeps the body as received
        XCTAssertEqual(applied.preview, "la mia risposta")       // previews and notifications use b, never q
        XCTAssertFalse(applied.preview.contains("originale"))
    }

    func test_theWriteBoundary_showsARejectedReplyAsTheTextItIs() {
        let broken = #"{"qa_reply":2,"anything":"visible"}"#
        let applied = FileV2ChatBody.applyInboundBoundary(row(broken), preview: broken)
        XCTAssertEqual(applied?.message.plaintext, broken)
        XCTAssertEqual(applied?.preview, broken)
    }

    // MARK: Which rows can be answered (13.5)

    func test_aTextWithAServerId_canBeAnswered() throws {
        let info = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row("ciao a tutti")))
        XCTAssertEqual(info.serverMessageId, serverId)
        XCTAssertEqual(info.kind, .text)
        XCTAssertEqual(info.source, "ciao a tutti")
        XCTAssertFalse(info.ephemeral)
    }

    func test_aMessageOfOneOwnWithoutAServerId_cannotBeAnswered() {
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: withoutServerId(row("ciao", outgoing: true))))
        let withEmptyId = row("ciao", outgoing: true, server: "")
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: withEmptyId))
    }

    func test_aServerIdThatIsNotInTheServersFormat_cannotBeAnswered() {
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("ciao", server: "73740A4D-0D1E-4F08-9F38-5BA1B8FE4472")))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("ciao", server: "srv-1")))
    }

    func test_aMeshMessage_aDeletedRow_aPlaceholderAndAnEmptyRow_cannotBeAnswered() {
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("ciao", viaMesh: true)))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("Messaggio eliminato", deletedAt: Date())))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("[messaggio cifrato non leggibile]", placeholder: true)))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("")))
    }

    func test_thePlaceholderOfARejectedFileMessage_cannotBeAnswered() {
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row(FileV2ChatBody.invalidText)))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row(FileV2ChatBody.unsupportedText)))
    }

    func test_aFileBeingSent_andAnAttachmentOfAnEarlierFormat_cannotBeAnswered() {
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row(FileV2ChatBody.glyph + "x.pdf", outgoing: true,
                                                          mime: FileV2ChatBody.pendingMime)))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("Nota vocale", mime: "audio/mp4")))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("Foto", mime: "image/jpeg")))
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row("Nota vocale", durationMs: 4200)))
    }

    func test_aReplyIsQuotedByItsB_neverByItsOwnQuote() throws {
        let body = try replyBody(quoteSource: "il messaggio originale", body: "la risposta")
        let info = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row(body)))
        XCTAssertEqual(info.kind, .text)
        XCTAssertEqual(info.source, "la risposta")   // quotes do not nest
    }

    func test_aRejectedReplyShownAsText_isQuotedByItsWholeBody() throws {
        let broken = #"{"qa_reply":3,"x":"y"}"#
        let info = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row(broken)))
        XCTAssertEqual(info.source, broken)
    }

    func test_aFileIsQuotedByItsName_aVoiceNoteByNothing() throws {
        let document = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row(try fileBody(kind: .file, name: "relazione.pdf"))))
        XCTAssertEqual(document.kind, .file)
        XCTAssertEqual(document.source, "relazione.pdf")

        let photo = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row(try fileBody(kind: .image, name: "foto.jpg"))))
        XCTAssertEqual(photo.kind, .image)
        XCTAssertEqual(photo.source, "foto.jpg")

        let video = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row(try fileBody(kind: .video, name: nil))))
        XCTAssertEqual(video.kind, .video)
        XCTAssertEqual(video.source, "")             // no nm: an empty q

        let voice = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row(try fileBody(kind: .voice, name: "nota.m4a"))))
        XCTAssertEqual(voice.kind, .voice)
        XCTAssertEqual(voice.source, "")
    }

    func test_anAvatar_isNotAChatMessage_andThumbIsNotAKindOfAReply() throws {
        XCTAssertNil(MessageReplyCodec.quoteInfo(for: row(try fileBody(kind: .avatar, name: nil))))
        // `avatar` and `thumb` are never the kind of a quoted message.
        XCTAssertNil(MessageReplyKind(rawValue: "avatar"))
        XCTAssertNil(MessageReplyKind(rawValue: "thumb"))
    }

    // MARK: Ephemeral messages (13.7)

    func test_aMessageWithALifetime_isQuotedWithAnEmptyQ() throws {
        let timer = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row("segreto", expiresAt: Date().addingTimeInterval(60))))
        XCTAssertTrue(timer.ephemeral)
        let viewOnce = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row("segreto", viewOnce: true)))
        XCTAssertTrue(viewOnce.ephemeral)
        let timedFile = try XCTUnwrap(MessageReplyCodec.quoteInfo(for: row(try fileBody(kind: .file, name: "x.pdf", ex: 60))))
        XCTAssertTrue(timedFile.ephemeral)

        for info in [timer, viewOnce, timedFile] {
            let built = MessageReplyCodec.build(to: info.serverMessageId, kind: info.kind.rawValue, quoteSource: info.source,
                                                quotedIsEphemeral: info.ephemeral, body: "ok")
            guard case .success(let text) = built, case .reply(let reply) = MessageReplyCodec.recognize(text) else {
                XCTFail("not a reply")
                continue
            }
            XCTAssertEqual(reply.quote, "", "nothing of an ephemeral message is copied into the reply")
        }
    }

    // MARK: Resolution (13.6)

    private func block(for body: String, among messages: [Message]) throws -> MessageReplyBlock {
        guard case .reply(let reply) = MessageReplyCodec.recognize(body) else {
            XCTFail("not a reply")
            return MessageReplyBlock(source: .unavailable, link: nil, author: nil, excerpt: "")
        }
        var rows: [MessageReplyRow] = []
        for message in messages {
            if let one = MessageReplyCodec.row(for: message, author: message.direction == .outgoing ? "Io" : "Anna") {
                rows.append(one)
            }
        }
        return MessageReplyCodec.resolve(reply, rows: rows)
    }

    func test_aFoundRow_isALink_andShowsTheLocalTextNotQ() throws {
        // A sender cannot make the quote of a message the receiver holds say something else.
        let forged = #"{"qa_reply":1,"to":"73740a4d-0d1e-4f08-9f38-5ba1b8fe4472","k":"text","q":"FALSO","b":"ok"}"#
        let result = try block(for: forged, among: [row("Il vero testo")])
        XCTAssertEqual(result.source, .local)
        XCTAssertEqual(result.link, serverId)
        XCTAssertEqual(result.author, "Anna")
        XCTAssertEqual(result.excerpt, "Il vero testo")
    }

    func test_aFoundRowThatIsAReply_isShownByItsB() throws {
        let inner = try replyBody(quoteSource: "piu' vecchio", body: "risposta intermedia")
        let body = try replyBody(quoteSource: "x", body: "ultima")
        let result = try block(for: body, among: [row(inner)])
        XCTAssertEqual(result.excerpt, "risposta intermedia")
    }

    func test_aFoundRowThatIsViewOnceOrVoice_showsNoContent() throws {
        let body = try replyBody()
        let viewOnce = try block(for: body, among: [row("segreto", viewOnce: true)])
        XCTAssertEqual(viewOnce.source, .local)
        XCTAssertEqual(viewOnce.excerpt, "")
        let voice = try block(for: body, among: [row(try fileBody(kind: .voice, name: "nota.m4a"))])
        XCTAssertEqual(voice.source, .local)
        XCTAssertEqual(voice.excerpt, "")
    }

    func test_aFoundFile_isShownByItsName() throws {
        let result = try block(for: try replyBody(kind: "file"), among: [row(try fileBody(kind: .file, name: "a\u{202E}b.pdf"))])
        XCTAssertEqual(result.excerpt, "ab.pdf")          // the bidirectional override is removed
    }

    func test_aGoneRow_showsNothing_andQIsNotShown() throws {
        let body = try replyBody(quoteSource: "contenuto scaduto")
        let result = try block(for: body, among: [row("Messaggio eliminato", deletedAt: Date())])
        XCTAssertEqual(result.source, .unavailable)
        XCTAssertNil(result.link)
        XCTAssertNil(result.author)
        XCTAssertEqual(result.excerpt, "")
    }

    func test_aRowThatIsNotFound_showsTheSanitisedQ_withoutAuthorOrLink() throws {
        let hostile = #"{"qa_reply":1,"to":"0a1b2c3d-0000-4000-8000-123456789abc","k":"text","q":"fattura‮fdp.exe\n\nriga","b":"ok"}"#
        let result = try block(for: hostile, among: [row("altro")])
        XCTAssertEqual(result.source, .quote)
        XCTAssertNil(result.link)
        XCTAssertNil(result.author)
        XCTAssertEqual(result.excerpt, "fatturafdp.exe riga")
    }

    func test_aVoiceQuoteNotFound_showsNothing() throws {
        let voice = #"{"qa_reply":1,"to":"0a1b2c3d-0000-4000-8000-123456789abc","k":"voice","q":"qualcosa","b":"ok"}"#
        let result = try block(for: voice, among: [])
        XCTAssertEqual(result.source, .quote)
        XCTAssertEqual(result.excerpt, "")
    }

    func test_theQuoteOfAMessageIsMatchedByTheServerId_notByTheLocalId() throws {
        let target = row("bersaglio", server: otherServerId)
        let decoy = row("esca", server: serverId)
        let body = try replyBody(to: otherServerId)
        let result = try block(for: body, among: [decoy, target])
        XCTAssertEqual(result.link, otherServerId)
        XCTAssertEqual(result.excerpt, "bersaglio")
    }
}

/// The reply at the store: the inbound write boundary previews `b`, and no edit can turn a row into a reply.
final class MessageReplyStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ConversationStore!
    private let convId = UUID()
    private let peer = "peer-1"
    private let serverId = "73740a4d-0d1e-4f08-9f38-5ba1b8fe4472"

    override func setUp() {
        super.setUp()
        // Same seam as ConversationStoreFileV2Tests: no usable keychain in a simulator test bundle.
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        let suite = "test.replystore.\(UUID().uuidString)"
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

    private func inbound(_ text: String, cmid: String = "cmid-1", server: String = "srv-1") -> Message {
        Message(id: UUID(), conversationId: convId, direction: .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: 1_745_000_100), deliveredAt: Date(), readAt: nil,
                status: .delivered, senderUserId: peer, serverMessageId: server, clientMsgId: cmid)
    }

    private func conversation() -> Conversation? {
        store.loadConversations().first(where: { $0.id == convId })
    }

    func test_aReply_isStoredAsReceived_andTheConversationPreviewsB() {
        let body = #"{"qa_reply":1,"to":"73740a4d-0d1e-4f08-9f38-5ba1b8fe4472","k":"text","q":"vecchio","b":"nuova risposta"}"#
        let result = store.recordInboundUserMessage(inbound(body), preview: body, incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(store.loadMessages(conversationId: convId).map { $0.plaintext }, [body])
        XCTAssertEqual(conversation()?.lastMessagePreview, "nuova risposta")
        XCTAssertEqual(conversation()?.unreadCount, 1)
    }

    func test_aRejectedReply_isStoredAndPreviewedAsText_neverLost() {
        let body = #"{"qa_reply":7,"b":"visibile"}"#
        let result = store.recordInboundUserMessage(inbound(body), preview: body, incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(store.loadMessages(conversationId: convId).map { $0.plaintext }, [body])
        XCTAssertEqual(conversation()?.lastMessagePreview, body)
    }

    func test_aReplyThatCarriesAReservedServiceMember_isDiscardedByTheServiceFilter_notShown() {
        // WIRE_SPEC 13.3: the structural filter runs before recognition; such a body is neither a reply nor a text.
        let body = #"{"qa_reply":1,"to":"73740a4d-0d1e-4f08-9f38-5ba1b8fe4472","k":"text","q":"","b":"x","qa_ctl":1}"#
        let result = store.recordInboundUserMessage(inbound(body), preview: body, incrementUnread: true, kind: .text)
        XCTAssertEqual(result, .refusedServiceShaped)
        XCTAssertTrue(store.loadMessages(conversationId: convId).isEmpty)
        XCTAssertNil(conversation()?.lastMessagePreview)
    }

    func test_anEditCannotTurnARowIntoAReply() {
        let original = inbound("testo", cmid: "cmid-edit", server: serverId)
        XCTAssertEqual(store.recordInboundUserMessage(original, preview: "testo", incrementUnread: false, kind: .text), .inserted)
        let forged = #"{"qa_reply":1,"to":"73740a4d-0d1e-4f08-9f38-5ba1b8fe4472","k":"text","q":"falso","b":"x"}"#
        XCTAssertFalse(store.applyEditByClientMsgId("cmid-edit", newPlaintext: forged))
        XCTAssertEqual(store.loadMessages(conversationId: convId).map { $0.plaintext }, ["testo"])
        XCTAssertTrue(store.applyEditByClientMsgId("cmid-edit", newPlaintext: "testo nuovo"))
    }
}

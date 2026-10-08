import XCTest
import QAudionEngine
@testable import QAudionApp

final class ConversationExporterTests: XCTestCase {

    private let uuid1 = UUID()
    private let convId = UUID()

    private func makeTextMsg(_ id: UUID, text: String, sentAt: Date, senderId: String?, direction: Message.Direction = .incoming) -> Message {
        return Message(
            id: id,
            conversationId: convId,
            direction: direction,
            plaintext: text,
            sentAt: sentAt,
            deliveredAt: nil,
            readAt: nil,
            status: .sent,
            senderUserId: senderId,
            deletedAt: nil
        )
    }

    func test_export_happyPath_formatsTextCorrectly() {
        let sent1 = Date(timeIntervalSince1970: 1777726200) // May 1, 2026, 12:50 PM UTC
        let msg1 = makeTextMsg(uuid1, text: "Ciao\nCome stai?", sentAt: sent1, senderId: "u1")

        let url = ConversationExporter.export(messages: [msg1], peerDisplayName: "Mario Rossi", myDisplayLabel: "Tu")

        XCTAssertNotNil(url, "Export should succeed and return a file URL")

        guard let url = url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Failed to read exported file")
            return
        }

        // Assert header is formatted correctly
        XCTAssertTrue(contents.contains("Q-Audion — Chat con Mario Rossi"))
        XCTAssertTrue(contents.contains("1 messaggio"))

        // Assert body is formatted correctly (newlines in body should be replaced by spaces)
        // Note: The timestamp depends on the local timezone during test execution.
        // We'll just check if the text parts are correctly stripped of newlines.
        XCTAssertTrue(contents.contains("Mario Rossi: Ciao Come stai?"))
    }

    func test_export_deletedMessage_formatsAsDeleted() {
        let sent1 = Date(timeIntervalSince1970: 1777726200)
        let msg = Message(
            id: uuid1,
            conversationId: convId,
            direction: .incoming,
            plaintext: "Secret",
            sentAt: sent1,
            deliveredAt: nil,
            readAt: nil,
            status: .sent,
            senderUserId: "u1",
            deletedAt: sent1
        )

        let url = ConversationExporter.export(messages: [msg], peerDisplayName: "Mario Rossi", myDisplayLabel: "Tu")
        guard let url = url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Failed to read exported file")
            return
        }

        XCTAssertTrue(contents.contains("Mario Rossi: <messaggio eliminato>"))
        XCTAssertFalse(contents.contains("Secret"))
    }

    func test_export_attachment_formatsWithPlaceholder() {
        let sent1 = Date(timeIntervalSince1970: 1777726200)
        let msg = Message(
            id: uuid1,
            conversationId: convId,
            direction: .outgoing,
            plaintext: "",
            sentAt: sent1,
            deliveredAt: nil,
            readAt: nil,
            status: .sent,
            senderUserId: nil,
            mediaDurationMs: 4200,
            mediaMimeType: "audio/mp4"
        )

        let url = ConversationExporter.export(messages: [msg], peerDisplayName: "Mario Rossi", myDisplayLabel: "Tu")
        guard let url = url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Failed to read exported file")
            return
        }

        XCTAssertTrue(contents.contains("Tu: <allegato: audio/mp4 · 4200ms>"))
    }

    func test_export_editedMessage_formatsWithSuffix() {
        let sent1 = Date(timeIntervalSince1970: 1777726200)
        let msg = Message(
            id: uuid1,
            conversationId: convId,
            direction: .outgoing,
            plaintext: "Edited text",
            sentAt: sent1,
            deliveredAt: nil,
            readAt: nil,
            status: .sent,
            senderUserId: nil,
            edited: true
        )

        let url = ConversationExporter.export(messages: [msg], peerDisplayName: "Mario Rossi", myDisplayLabel: "Tu")
        guard let url = url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Failed to read exported file")
            return
        }

        XCTAssertTrue(contents.contains("Tu: Edited text (modificato)"))
    }

    func test_export_writeFailure_returnsNil() {
        let sent1 = Date(timeIntervalSince1970: 1777726200)
        let msg = makeTextMsg(uuid1, text: "Should fail", sentAt: sent1, senderId: "u1")

        // 1. Save original attributes
        let tempDir = FileManager.default.temporaryDirectory
        var originalAttributes: [FileAttributeKey: Any]? = nil
        do {
            originalAttributes = try FileManager.default.attributesOfItem(atPath: tempDir.path)
        } catch {
            XCTFail("Could not read original attributes of temporaryDirectory: \(error)")
        }

        // 2. Defer restoring attributes to not break other tests
        defer {
            if let originalPosix = originalAttributes?[.posixPermissions] as? NSNumber {
                do {
                    try FileManager.default.setAttributes([.posixPermissions: originalPosix.shortValue], ofItemAtPath: tempDir.path)
                } catch {
                    XCTFail("Failed to restore original attributes: \(error)")
                }
            } else {
                // Fallback to 0o755 if original could not be read
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            }
        }

        // 3. Make temporaryDirectory read-only
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: tempDir.path)
        } catch {
            XCTFail("Could not set temporaryDirectory to read-only: \(error)")
            return
        }

        // 4. Try exporting and verify it returns nil
        let result = ConversationExporter.export(messages: [msg], peerDisplayName: "Mario Rossi", myDisplayLabel: "Tu")
        XCTAssertNil(result, "Export should return nil when file writing fails")
    }


    // MARK: - Replies (WIRE_SPEC 13)

    private let quotedServerId = "73740a4d-0d1e-4f08-9f38-5ba1b8fe4472"

    private func replyBody(to: String, quote: String, body: String) -> String {
        let result = MessageReplyCodec.build(to: to, kind: "text", quoteSource: quote, quotedIsEphemeral: false, body: body)
        guard case .success(let text) = result else {
            XCTFail("the builder refused: \(result)")
            return ""
        }
        return text
    }

    private func exported(_ messages: [Message]) -> String? {
        guard let url = ConversationExporter.export(messages: messages, peerDisplayName: "Mario Rossi", myDisplayLabel: "Tu") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func serverRow(_ text: String, outgoing: Bool, server: String, at: TimeInterval, deleted: Bool = false) -> Message {
        Message(id: UUID(), conversationId: convId, direction: outgoing ? .outgoing : .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: at), deliveredAt: nil, readAt: nil, status: .sent, senderUserId: "u1",
                serverMessageId: server, deletedAt: deleted ? Date(timeIntervalSince1970: at) : nil)
    }

    func test_export_reply_writesB_andWhatItAnswers() {
        let quoted = serverRow("Ci vediamo alle otto", outgoing: false, server: quotedServerId, at: 1777726200)
        let reply = serverRow(replyBody(to: quotedServerId, quote: "falso", body: "Va bene"), outgoing: true,
                              server: "0a1b2c3d-0000-4000-8000-123456789abc", at: 1777726260)
        guard let contents = exported([quoted, reply]) else { return XCTFail("Failed to read exported file") }
        // The author and the excerpt come from the local row (`q` is ignored), and the object is never written.
        XCTAssertTrue(contents.contains("Tu: Va bene (in risposta a Mario Rossi: Ci vediamo alle otto)"))
        XCTAssertFalse(contents.contains("qa_reply"))
        XCTAssertFalse(contents.contains("falso"))
    }

    func test_export_reply_toADeletedMessage_saysItIsNotAvailable_andNeverWritesQ() {
        let quoted = serverRow("Messaggio eliminato", outgoing: false, server: quotedServerId, at: 1777726200, deleted: true)
        let reply = serverRow(replyBody(to: quotedServerId, quote: "testo segreto", body: "Ok"), outgoing: true,
                              server: "0a1b2c3d-0000-4000-8000-123456789abc", at: 1777726260)
        guard let contents = exported([quoted, reply]) else { return XCTFail("Failed to read exported file") }
        XCTAssertTrue(contents.contains("Tu: Ok (in risposta a un messaggio: non disponibile)"))
        XCTAssertFalse(contents.contains("testo segreto"))
    }

    func test_export_reply_toAnUnknownMessage_writesTheSanitisedQ_withoutAuthor() {
        let reply = serverRow(replyBody(to: quotedServerId, quote: "citazione", body: "Ok"), outgoing: true,
                              server: "0a1b2c3d-0000-4000-8000-123456789abc", at: 1777726260)
        guard let contents = exported([reply]) else { return XCTFail("Failed to read exported file") }
        XCTAssertTrue(contents.contains("Tu: Ok (in risposta a un messaggio: citazione)"))
    }
}

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
}

import XCTest
@testable import QAudionEngine

/// What the chat does with the body of a message in front of the v2 file format (WIRE_SPEC 12.7.1): ordinary text, a valid
/// descriptor, a recognised body that was rejected, a control message; and the write boundary of an inbound message.
final class FileV2ChatBodyTests: XCTestCase {

    private let conversation = UUID()

    private func descriptorBody(name: String? = "report.pdf", size: UInt64 = 1234, ex: Int64? = nil,
                                xp: Int64? = nil) throws -> String {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: size)
        let source = FileV2Descriptor.Source(
            via: .srv, obj: "0a1b2c3d-0000-4000-8000-123456789abc",
            token: FileV2Descriptor.Token(v: String(repeating: "ab", count: 32), exp: 1_800_000_000_000, max: 30))
        let input = FileV2FileInput(encryptor: encryptor, kind: .file, source: source, name: name,
                                    mimeType: "application/pdf", ex: ex, xp: xp)
        return try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: input))
    }

    private func inbound(_ text: String) -> Message {
        Message(id: UUID(), conversationId: conversation, direction: .incoming, plaintext: text,
                sentAt: Date(timeIntervalSince1970: 1_745_000_000), deliveredAt: nil, readAt: nil, status: .delivered)
    }

    // MARK: Classification

    func test_ordinaryText_isText() {
        XCTAssertEqual(FileV2ChatBody.classify(text: "ciao"), .text)
        XCTAssertEqual(FileV2ChatBody.classify(text: ""), .text)
        // a valid descriptor whose first member is another member is ordinary text (12.7.1)
        XCTAssertEqual(FileV2ChatBody.classify(text: #"{"id":"AAAAAAAAAAAAAAAAAAAAAA==","qa_file":2}"#), .text)
    }

    func test_validDescriptor_isAFile_withTheValuesTheBubbleNeeds() throws {
        let body = try descriptorBody(name: "a/b\u{202E}c.pdf", size: 4321, ex: 60, xp: 0)
        guard case .file(let file) = FileV2ChatBody.classify(text: body) else { return XCTFail("not a file") }
        XCTAssertEqual(file.displayName, "a_bc.pdf")          // separator replaced, bidirectional control removed
        XCTAssertEqual(file.size, 4321)
        XCTAssertEqual(file.mimeType, "application/pdf")
        XCTAssertEqual(file.kind, "file")
        XCTAssertEqual(file.ex, 60)
        XCTAssertEqual(file.xp, 0)
        XCTAssertEqual(file.previewText, "📎 a_bc.pdf")
    }

    func test_aFileWithoutName_getsTheFallbackName() throws {
        let body = try descriptorBody(name: nil)
        guard case .file(let file) = FileV2ChatBody.classify(text: body) else { return XCTFail("not a file") }
        XCTAssertEqual(file.displayName, FileV2LocalName.fallback)
    }

    func test_theTextShownForAFile_neverHoldsTheDescriptor() throws {
        let body = try descriptorBody()
        let shown = try XCTUnwrap(FileV2ChatBody.classify(text: body).displayText)
        XCTAssertFalse(shown.contains("qa_file"))
        XCTAssertFalse(shown.contains("\"k\""))
    }

    func test_anotherVersion_isUnsupported_andGarbageWithThePrefixIsInvalid() {
        XCTAssertEqual(FileV2ChatBody.classify(text: #"{"qa_file":3,"future":true}"#), .unsupportedVersion)
        XCTAssertEqual(FileV2ChatBody.classify(text: #"{"qa_file":2,"id":"nope"}"#), .invalid)
        XCTAssertEqual(FileV2ChatBody.classify(text: #"{"qa_file":"2"}"#), .invalid)
        XCTAssertNotNil(FileV2ChatBody.unsupportedVersion.displayText)
        XCTAssertNotNil(FileV2ChatBody.invalid.displayText)
    }

    func test_controlMessages_areControl_validOrNot() throws {
        let cancel = try FileV2DescriptorBuilder.buildCancel(fileID: Data(repeating: 7, count: 16))
        XCTAssertEqual(FileV2ChatBody.classify(text: cancel), .control)
        XCTAssertEqual(FileV2ChatBody.classify(text: #"{"qa_file_src":2,"id":"bad"}"#), .control)
        XCTAssertEqual(FileV2ChatBody.classify(text: #"{"qa_file_cancel":9}"#), .control)
        XCTAssertNil(FileV2ChatBody.control.displayText)
    }

    func test_textTheUserTypes_mayNotBeAFileMessage() throws {
        XCTAssertTrue(FileV2ChatBody.isUserTextAllowed("ciao {\"qa_file\":2}"))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_file":2,"id":"x"}"#))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_file_src":2}"#))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(#"{"qa_file_cancel":2}"#))
        XCTAssertFalse(FileV2ChatBody.isUserTextAllowed(try descriptorBody()))
    }

    // MARK: The inbound write boundary

    func test_boundary_keepsTheBodyOfAValidDescriptor_andGivesItAPreviewOfItsOwn() throws {
        let body = try descriptorBody(name: "notes.txt")
        let message = inbound(body)
        let applied = try XCTUnwrap(FileV2ChatBody.applyInboundBoundary(message, preview: body))
        XCTAssertEqual(applied.message.plaintext, body)          // the download needs it
        XCTAssertEqual(applied.preview, "📎 notes.txt")
    }

    func test_boundary_replacesARejectedDescriptorByItsPlaceholder() {
        let invalid = inbound(#"{"qa_file":2,"id":"nope"}"#)
        let a = FileV2ChatBody.applyInboundBoundary(invalid, preview: invalid.plaintext)
        XCTAssertEqual(a?.message.plaintext, FileV2ChatBody.invalidText)
        XCTAssertEqual(a?.preview, FileV2ChatBody.invalidText)
        XCTAssertEqual(a?.message.id, invalid.id)                // same row, only the text changed

        let future = inbound(#"{"qa_file":7,"secret":"do not show"}"#)
        let b = FileV2ChatBody.applyInboundBoundary(future, preview: future.plaintext)
        XCTAssertEqual(b?.message.plaintext, FileV2ChatBody.unsupportedText)
        XCTAssertFalse(b?.preview.contains("secret") ?? true)
    }

    func test_boundary_refusesAControlMessage_andLeavesOrdinaryTextAlone() {
        let control = inbound(#"{"qa_file_cancel":2,"id":"AAAAAAAAAAAAAAAAAAAAAA=="}"#)
        XCTAssertNil(FileV2ChatBody.applyInboundBoundary(control, preview: control.plaintext))
        let text = inbound("ciao")
        let applied = FileV2ChatBody.applyInboundBoundary(text, preview: "ciao")
        XCTAssertEqual(applied?.message, text)
        XCTAssertEqual(applied?.preview, "ciao")
    }

    func test_thePlaceholderTextCanBeLocalisedByTheApp() {
        let original = FileV2ChatBody.placeholderText
        defer { FileV2ChatBody.placeholderText = original }
        FileV2ChatBody.placeholderText = { placeholder in
            switch placeholder {
            case .unsupportedVersion: return "update"
            case .invalid: return "invalid"
            }
        }
        let future = inbound(#"{"qa_file":7}"#)
        XCTAssertEqual(FileV2ChatBody.applyInboundBoundary(future, preview: "")?.message.plaintext, "update")
        XCTAssertEqual(FileV2ChatBody.unsupportedVersion.displayText, "update")
    }

    // MARK: The bubble of a file being sent

    func test_aFileBeingSent_showsItsNameUntilItHasADescriptor() throws {
        let sending = Message(id: UUID(), conversationId: conversation, direction: .outgoing,
                              plaintext: FileV2ChatBody.glyph + "foto\u{202E}.zip", sentAt: Date(), deliveredAt: nil,
                              readAt: nil, status: .sending, mediaMimeType: FileV2ChatBody.pendingMime)
        let info = try XCTUnwrap(FileV2ChatBody.bubbleInfo(for: sending))
        XCTAssertEqual(info.displayName, "foto.zip")
        XCTAssertEqual(info.size, 0)

        // once the row carries the descriptor, the bubble reads it from there
        let body = try descriptorBody(name: "foto.zip", size: 999)
        let sent = sending.replacingPlaintext(body)
        let plain = Message(id: sent.id, conversationId: conversation, direction: .outgoing, plaintext: body,
                            sentAt: Date(), deliveredAt: nil, readAt: nil, status: .sent)
        XCTAssertEqual(FileV2ChatBody.bubbleInfo(for: plain)?.size, 999)
        XCTAssertNil(FileV2ChatBody.bubbleInfo(for: inbound("ciao")))
    }
}

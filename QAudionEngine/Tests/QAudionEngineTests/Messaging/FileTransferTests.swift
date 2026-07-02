import XCTest
@testable import QAudionEngine

/// Wire-format tests for `FileTransfer.FileMarker.QFile` — the `qfile` v3
/// marker used for image + generic-file attachment sends on iOS.
///
/// W447 adds an optional `ex` field (per-attachment ephemeral-timer
/// override). These tests cover the Codable round-trip and the
/// backward-compat guarantee: old-shape JSON (no `ex` key at all) must
/// still decode with today's default behavior unchanged.
final class FileTransferQFileMarkerTests: XCTestCase {

    private func makeQFile(ex: Int? = nil) -> FileTransfer.FileMarker.QFile {
        FileTransfer.FileMarker.QFile(
            fileId: "file-123",
            name: "photo.jpg",
            size: 4096,
            mime: "image/jpeg",
            salt: String(repeating: "aa", count: 32),
            nonce: String(repeating: "bb", count: 12),
            tag: String(repeating: "cc", count: 16),
            keyId: "auto:abcd1234:peer-uuid",
            ts: 1_700_000_000_000,
            ex: ex
        )
    }

    // MARK: - Round-trip WITH `ex`

    func test_roundTrip_withEx_positiveTtl_preservesValue() throws {
        let marker = FileTransfer.FileMarker(qfile: makeQFile(ex: 300))
        let wire = try FileTransfer.serializeMarker(marker)
        XCTAssertTrue(wire.contains("\"ex\":300"))

        let decoded = FileTransfer.tryParseMarker(text: wire)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.qfile.ex, 300)
        XCTAssertEqual(decoded, marker)
    }

    func test_roundTrip_withEx_viewOnceSentinel_preservesValue() throws {
        let marker = FileTransfer.FileMarker(qfile: makeQFile(ex: -1))
        let wire = try FileTransfer.serializeMarker(marker)
        let decoded = FileTransfer.tryParseMarker(text: wire)
        XCTAssertEqual(decoded?.qfile.ex, -1)
    }

    // MARK: - Backward compat WITHOUT `ex`

    /// An envelope with no override set must encode WITHOUT the `ex` key
    /// at all — byte-identical wire shape to before this change.
    func test_encode_withoutEx_omitsExKey() throws {
        let marker = FileTransfer.FileMarker(qfile: makeQFile(ex: nil))
        let wire = try FileTransfer.serializeMarker(marker)
        XCTAssertFalse(wire.contains("\"ex\""))
    }

    /// Old-shape JSON (produced before W447, no `ex` key present at all)
    /// must still decode successfully with `ex` defaulting to nil — this
    /// is the core backward-compatibility guarantee for old decoders
    /// reading new data and new decoders reading old data.
    func test_decode_oldShapeJsonWithoutExKey_decodesWithNilDefault() throws {
        let oldShapeJson = """
        {"qfile":{"fileId":"file-123","name":"photo.jpg","size":4096,
        "mime":"image/jpeg","salt":"\(String(repeating: "aa", count: 32))",
        "nonce":"\(String(repeating: "bb", count: 12))",
        "tag":"\(String(repeating: "cc", count: 16))",
        "keyId":"auto:abcd1234:peer-uuid","ts":1700000000000}}
        """
        let decoded = FileTransfer.tryParseMarker(text: oldShapeJson)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.qfile.ex)
        // Sanity: the rest of the marker still decodes correctly.
        XCTAssertEqual(decoded?.qfile.fileId, "file-123")
        XCTAssertEqual(decoded?.qfile.mime, "image/jpeg")
    }

    func test_decode_exZero_meansNoOverride() throws {
        let marker = FileTransfer.FileMarker(qfile: makeQFile(ex: 0))
        let wire = try FileTransfer.serializeMarker(marker)
        let decoded = FileTransfer.tryParseMarker(text: wire)
        XCTAssertEqual(decoded?.qfile.ex, 0)
    }
}

/// Pure precedence-rule tests for ``AttachmentTimerResolver`` — mirrors
/// Desktop's `resolveAttachmentTimerSec` and Android's
/// `InboundFileAttachmentDispatcher`: a per-message override wins over
/// the conversation default whenever present and non-zero.
final class AttachmentTimerResolverTests: XCTestCase {

    func test_resolve_overridePresent_positiveTtl_winsOverDefault() {
        let result = AttachmentTimerResolver.resolve(overrideSeconds: 60, conversationDefault: 3600)
        XCTAssertEqual(result, 60)
    }

    func test_resolve_overridePresent_viewOnce_winsOverDefault() {
        let result = AttachmentTimerResolver.resolve(overrideSeconds: -1, conversationDefault: 3600)
        XCTAssertEqual(result, -1)
    }

    func test_resolve_overrideNil_fallsBackToConversationDefault() {
        let result = AttachmentTimerResolver.resolve(overrideSeconds: nil, conversationDefault: 3600)
        XCTAssertEqual(result, 3600)
    }

    func test_resolve_overrideZero_treatedAsAbsent_fallsBackToConversationDefault() {
        let result = AttachmentTimerResolver.resolve(overrideSeconds: 0, conversationDefault: 3600)
        XCTAssertEqual(result, 3600)
    }

    func test_resolve_overrideNil_conversationDefaultAlsoNil_returnsNil() {
        let result = AttachmentTimerResolver.resolve(overrideSeconds: nil, conversationDefault: nil)
        XCTAssertNil(result)
    }

    func test_resolve_overrideOff_conversationDefaultViewOnce_overrideWins() {
        // Explicit "off" isn't representable as a distinct wire value
        // (0 means "no override"), but a positive override should still
        // beat a view-once conversation default.
        let result = AttachmentTimerResolver.resolve(overrideSeconds: 120, conversationDefault: -1)
        XCTAssertEqual(result, 120)
    }

    func test_resolve_overrideNil_conversationDefaultViewOnce_fallsBackToViewOnce() {
        let result = AttachmentTimerResolver.resolve(overrideSeconds: nil, conversationDefault: -1)
        XCTAssertEqual(result, -1)
    }
}

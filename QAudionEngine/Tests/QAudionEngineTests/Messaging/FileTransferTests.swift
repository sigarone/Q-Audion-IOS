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

/// W-TUSRESUME — `FileTransfer.resumeUpload` (tier-1 resume): verifies the
/// deterministic re-seal (pinned salt/nonce/ts reproduces byte-identical
/// ciphertext to what `upload()` would have produced with those same
/// values), that `resumeFile` receives the ciphertext + fileId it should,
/// and the explicit `resumeNotSupported` signal when the caller's
/// `StorageApi` doesn't wire a `resumeFile` closure.
final class FileTransferResumeUploadTests: XCTestCase {

    private func makeVaultAdapter(pskMaterial: Data, keyId: String) -> FileTransfer.VaultAdapter {
        FileTransfer.VaultAdapter(
            forContact: { _ in FileTransfer.VaultEntry(keyId: keyId, material: pskMaterial) },
            primary: { FileTransfer.VaultEntry(keyId: keyId, material: pskMaterial) },
            allByPriority: { [FileTransfer.VaultEntry(keyId: keyId, material: pskMaterial)] }
        )
    }

    /// W-TUSRESUME (security-review follow-up) — `onResumeStateReady`'s
    /// `pskFingerprintHex` must be a SHA-256 of the ACTUAL PSK bytes used
    /// for this seal, and must differ when a different PSK is used —
    /// this is what lets `TusResumeStateStore.checkCorruption` later
    /// detect a rotated/re-bound PSK before a resume attempt.
    func test_upload_onResumeStateReady_pskFingerprintReflectsActualPsk() async throws {
        let pskA = Data(repeating: 0x71, count: 32)
        let pskB = Data(repeating: 0x72, count: 32)
        let plaintext = Data("fingerprint me".utf8)

        func capturePskFingerprint(psk: Data) async throws -> String {
            let vault = makeVaultAdapter(pskMaterial: psk, keyId: "peer-fp")
            let storage = FileTransfer.StorageApi(
                uploadFile: { _, _ in "unused" },
                downloadFile: { _ in throw FileTransferError.emptyVault },
                uploadFileWithProgress: { _, _, _, resumeCtx in
                    resumeCtx?.onFileIdMinted("f-id")
                    return "f-id"
                }
            )
            let transfer = FileTransfer(storage: storage, vault: vault, selfUserId: "me")
            var captured = ""
            _ = try await transfer.upload(
                recipientId: "peer-fp",
                bytes: plaintext,
                filename: "f.jpg",
                mime: "image/jpeg",
                resumeContext: (clientMsgId: "msg-fp", sourceBytes: plaintext),
                onResumeStateReady: { _, _, _, _, _, pskFingerprintHex in
                    captured = pskFingerprintHex
                }
            )
            return captured
        }

        let fpA1 = try await capturePskFingerprint(psk: pskA)
        let fpA2 = try await capturePskFingerprint(psk: pskA)
        let fpB = try await capturePskFingerprint(psk: pskB)

        XCTAssertFalse(fpA1.isEmpty)
        XCTAssertEqual(fpA1, fpA2, "same PSK must fingerprint identically every time")
        XCTAssertNotEqual(fpA1, fpB, "different PSKs must fingerprint differently")
    }

    func test_resumeUpload_reproducesByteIdenticalCiphertext_asOriginalUpload() async throws {
        // Prove the core premise of tier-1 resume: sealing the SAME
        // plaintext with the SAME pinned salt/nonce/ts (as `upload()`
        // captures via `onResumeStateReady`) via `resumeUpload` produces
        // byte-identical ciphertext to the original `upload()` call —
        // otherwise a server-side PATCH continuation would be corrupting
        // the assembled file.
        let psk = Data(repeating: 0x5A, count: 32)
        let vault = makeVaultAdapter(pskMaterial: psk, keyId: "peer-1")
        let plaintext = Data("resume me please".utf8)

        // First: a normal upload(), capturing the salt/nonce/ts it used.
        var capturedFileId = ""
        var capturedSaltHex = ""
        var capturedNonceHex = ""
        var capturedTs: Int64 = 0
        var capturedKeyId = ""
        let uploadStorage = FileTransfer.StorageApi(
            uploadFile: { _, _ in "unused" },
            downloadFile: { _ in throw FileTransferError.emptyVault },
            uploadFileWithProgress: { _, _, _, resumeCtx in
                capturedFileId = "minted-file-1"
                resumeCtx?.onFileIdMinted(capturedFileId)
                return capturedFileId
            }
        )
        let uploaderTransfer = FileTransfer(storage: uploadStorage, vault: vault, selfUserId: "me")
        let originalMarker = try await uploaderTransfer.upload(
            recipientId: "peer-1",
            bytes: plaintext,
            filename: "note.m4a",
            mime: "audio/mp4",
            resumeContext: (clientMsgId: "msg-1", sourceBytes: plaintext),
            onResumeStateReady: { fileId, saltHex, nonceHex, ts, keyId, _ in
                capturedFileId = fileId
                capturedSaltHex = saltHex
                capturedNonceHex = nonceHex
                capturedTs = ts
                capturedKeyId = keyId
            }
        )
        XCTAssertFalse(capturedSaltHex.isEmpty)

        // Second: resumeUpload() with the captured salt/nonce/ts — the
        // resumeFile closure receives the ciphertext it would PATCH.
        var resumedCiphertext: Data?
        var resumedFileId: String?
        let resumeStorage = FileTransfer.StorageApi(
            uploadFile: { _, _ in "unused" },
            downloadFile: { _ in throw FileTransferError.emptyVault },
            resumeFile: { fileId, ciphertext, _ in
                resumedFileId = fileId
                resumedCiphertext = ciphertext
            }
        )
        let resumerTransfer = FileTransfer(storage: resumeStorage, vault: vault, selfUserId: "me")
        let resumedMarker = try await resumerTransfer.resumeUpload(
            recipientId: "peer-1",
            bytes: plaintext,
            filename: "note.m4a",
            mime: "audio/mp4",
            fileId: capturedFileId,
            saltHex: capturedSaltHex,
            nonceHex: capturedNonceHex,
            ts: capturedTs,
            keyId: capturedKeyId
        )

        XCTAssertEqual(resumedFileId, capturedFileId)
        XCTAssertNotNil(resumedCiphertext)
        // Byte-identical ciphertext AND tag — the whole point of pinning
        // salt/nonce/ts rather than re-randomizing on resume.
        XCTAssertEqual(resumedMarker.qfile.tag, originalMarker.qfile.tag)
        XCTAssertEqual(resumedMarker.qfile.salt, originalMarker.qfile.salt)
        XCTAssertEqual(resumedMarker.qfile.nonce, originalMarker.qfile.nonce)
        XCTAssertEqual(resumedMarker.qfile.ts, originalMarker.qfile.ts)
    }

    func test_resumeUpload_noResumeFileWired_throwsResumeNotSupported() async throws {
        let psk = Data(repeating: 0x5B, count: 32)
        let vault = makeVaultAdapter(pskMaterial: psk, keyId: "peer-2")
        // StorageApi with NO resumeFile closure — the small-file
        // multipart-only case.
        let storage = FileTransfer.StorageApi(
            uploadFile: { _, _ in "unused" },
            downloadFile: { _ in throw FileTransferError.emptyVault }
        )
        let transfer = FileTransfer(storage: storage, vault: vault, selfUserId: "me")

        do {
            _ = try await transfer.resumeUpload(
                recipientId: "peer-2",
                bytes: Data("x".utf8),
                filename: "f.jpg",
                mime: "image/jpeg",
                fileId: "some-id",
                saltHex: String(repeating: "aa", count: 32),
                nonceHex: String(repeating: "bb", count: 12),
                ts: 1_700_000_000_000,
                keyId: "peer-2"
            )
            XCTFail("expected resumeNotSupported to be thrown")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .resumeNotSupported)
        }
    }

    func test_resumeUpload_noPskAvailable_throwsNoPskAvailable() async throws {
        let emptyVault = FileTransfer.VaultAdapter(
            forContact: { _ in nil },
            primary: { nil },
            allByPriority: { [] }
        )
        let storage = FileTransfer.StorageApi(
            uploadFile: { _, _ in "unused" },
            downloadFile: { _ in throw FileTransferError.emptyVault },
            resumeFile: { _, _, _ in }
        )
        let transfer = FileTransfer(storage: storage, vault: emptyVault, selfUserId: "me")

        do {
            _ = try await transfer.resumeUpload(
                recipientId: "peer-3",
                bytes: Data("x".utf8),
                filename: "f.jpg",
                mime: "image/jpeg",
                fileId: "some-id",
                saltHex: String(repeating: "aa", count: 32),
                nonceHex: String(repeating: "bb", count: 12),
                ts: 1_700_000_000_000,
                keyId: "peer-3"
            )
            XCTFail("expected noPskAvailable to be thrown")
        } catch let error as FileTransferError {
            XCTAssertEqual(error, .noPskAvailable)
        }
    }
}

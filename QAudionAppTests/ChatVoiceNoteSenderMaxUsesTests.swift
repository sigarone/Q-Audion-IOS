import XCTest
@testable import QAudionApp
import QAudionEngine

/// W-MAXUSES-PARITY (2026-09-30) — pins
/// `ChatVoiceNoteSender.chunkCountForMaxUses`, the pure helper that
/// reconstructs a `BCryptoDownloadTokenClient.computeMaxUses`-shaped chunk
/// count from a plaintext byte length for the legacy `qfile` marker path
/// (`prepareAttachmentMarkerJson`/`resumeAttachmentMarkerJson`), which has
/// no real per-chunk split to read a count off (single-shot
/// `FileTransfer.upload`/`resumeUpload` blob — see the helper's own doc).
///
/// Wired into CI: this file is on the include list of
/// `QAudionApp/project-apptests.yml` (an app-hosted unit-test bundle limited to
/// the files listed there) and runs in `.github/workflows/ios-app-tests.yml`.
/// The rest of `QAudionAppTests/` still has no target. The arithmetic under
/// test also has its own engine KATs (`BCryptoDownloadTokenClientTests`,
/// `chunkCount(forByteLength:)`), so this file only pins the sender-side
/// delegate plus the end-to-end sizing through `computeMaxUses`.
///
/// `@MainActor` on the class (not just the methods under test): both
/// `ChatVoiceNoteSender` and `ChatFileAttachmentSender` are themselves
/// `@MainActor`, so `chunkCountForMaxUses`/`defaultChunkSize` are
/// MainActor-isolated static members — same reason `CapabilityGateTests`
/// annotates its whole class rather than hopping per-call.
@MainActor
final class ChatVoiceNoteSenderMaxUsesTests: XCTestCase {

    // MARK: - chunkCountForMaxUses: pure KAT

    func test_chunkCountForMaxUses_nonPositiveByteLength_returnsZero() {
        // Zero/negative is not a real voice-note size, but must degrade
        // safely to "no chunks" (→ `computeMaxUses` then returns nil, same
        // as the "unknown size" contract it already documents) rather than
        // underflow or crash.
        XCTAssertEqual(ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: 0), 0)
        XCTAssertEqual(ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: -1), 0)
    }

    func test_chunkCountForMaxUses_roundsUpToTheNextWholeChunk() {
        // 1 byte still spans (part of) one 64 KiB chunk.
        XCTAssertEqual(ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: 1), 1)
        // Exactly one chunk (65 536 B = ChatFileAttachmentSender.defaultChunkSize).
        XCTAssertEqual(ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: 65_536), 1)
        // One byte over a whole chunk rounds up into a second one.
        XCTAssertEqual(ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: 65_537), 2)
    }

    func test_chunkCountForMaxUses_typicalVoiceNoteSize() {
        // A ~180 KB voice note (a few seconds of AAC) spans 3 chunks
        // (2 * 65 536 = 131 072 < 184 320 <= 3 * 65 536 = 196 608).
        XCTAssertEqual(ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: 184_320), 3)
    }

    // MARK: - End-to-end with BCryptoDownloadTokenClient.computeMaxUses

    func test_maxUsesSizing_smallVoiceNote_hitsTheSameFloorAsBeforeTheFix() {
        // A small voice note (well under the 4 MiB / 64-chunk first-restart
        // threshold) still floors to the server's own default-intent value
        // of 10 — this fix does not regress the common case, only stops it
        // from relying on the server's undocumented default to get there.
        let chunks = ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: 184_320)
        XCTAssertEqual(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: chunks), 10)
    }

    func test_maxUsesSizing_largeAttachment_scalesAboveTheFloor() {
        // A large image/voice note sent over the legacy qfile path
        // (8 MiB = 128 chunks of 64 KiB) now gets real headroom instead of
        // always hitting the 10-use floor — pinned against the exact value
        // `BCryptoDownloadTokenClientTests
        // .test_computeMaxUses_scalesWithChunkCount` already pins for 128
        // chunks (2 extra restarts, desired=12).
        let byteLength = 128 * ChatFileAttachmentSender.defaultChunkSize
        let chunks = ChatVoiceNoteSender.chunkCountForMaxUses(byteLength: byteLength)
        XCTAssertEqual(chunks, 128)
        XCTAssertEqual(BCryptoDownloadTokenClient.computeMaxUses(totalChunks: chunks), 12)
    }
}

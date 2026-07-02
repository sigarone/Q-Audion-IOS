import XCTest
import CryptoKit
@testable import QAudionEngine

/// W-TUSRESUME — persisted resume-state store + corruption-check logic.
/// Covers:
///   - `TusResumeStateStore` save/load/clear round-trip (keyed by
///     `clientMsgId`, mirrors `PendingGroupInviteStore`'s single-key
///     dictionary convention).
///   - `checkCorruption`'s three failure modes (missing file, size
///     mismatch, hash mismatch) all correctly rejecting a resume, and the
///     matching-file case correctly accepting one.
final class TusResumeStateTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TusResumeStateTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeState(
        clientMsgId: String,
        fileId: String = "file-1",
        sourceSizeAtStart: Int64,
        sourceSha256AtStart: String,
        pskFingerprintHex: String = String(repeating: "cc", count: 32)
    ) -> TusResumeState {
        TusResumeState(
            fileId: fileId,
            clientMsgId: clientMsgId,
            totalBytes: sourceSizeAtStart,
            sourceSizeAtStart: sourceSizeAtStart,
            sourceSha256AtStart: sourceSha256AtStart,
            saltHex: String(repeating: "aa", count: 32),
            nonceHex: String(repeating: "bb", count: 12),
            ts: 1_700_000_000_000,
            recipientUserId: "peer-1",
            filename: "voicenote-1.m4a",
            mime: "audio/mp4",
            pskFingerprintHex: pskFingerprintHex,
            durationMs: 4200,
            timerOverrideSeconds: nil
        )
    }

    private func writeFile(named name: String, contents: Data) -> String {
        let url = tempDir.appendingPathComponent(name)
        try! contents.write(to: url)
        return url.path
    }

    // MARK: - Store round-trip

    func test_store_saveThenLoad_roundTripsByClientMsgId() {
        let bytes = Data(repeating: 0x11, count: 64)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let state = makeState(clientMsgId: "msg-A", sourceSizeAtStart: fp.size, sourceSha256AtStart: fp.sha256Hex)

        TusResumeStateStore.save(state)
        defer { TusResumeStateStore.clear(clientMsgId: "msg-A") }

        let loaded = TusResumeStateStore.load(clientMsgId: "msg-A")
        XCTAssertEqual(loaded, state)
    }

    func test_store_load_missingKey_returnsNil() {
        XCTAssertNil(TusResumeStateStore.load(clientMsgId: "never-saved-\(UUID().uuidString)"))
    }

    func test_store_clear_removesOnlyTheTargetedKey() {
        let bytesA = Data(repeating: 0x22, count: 16)
        let bytesB = Data(repeating: 0x33, count: 16)
        let fpA = TusResumeStateStore.fingerprint(of: bytesA)
        let fpB = TusResumeStateStore.fingerprint(of: bytesB)
        let stateA = makeState(clientMsgId: "msg-clearA", sourceSizeAtStart: fpA.size, sourceSha256AtStart: fpA.sha256Hex)
        let stateB = makeState(clientMsgId: "msg-clearB", sourceSizeAtStart: fpB.size, sourceSha256AtStart: fpB.sha256Hex)

        TusResumeStateStore.save(stateA)
        TusResumeStateStore.save(stateB)
        defer { TusResumeStateStore.clear(clientMsgId: "msg-clearB") }

        TusResumeStateStore.clear(clientMsgId: "msg-clearA")

        XCTAssertNil(TusResumeStateStore.load(clientMsgId: "msg-clearA"))
        XCTAssertNotNil(TusResumeStateStore.load(clientMsgId: "msg-clearB"))
    }

    func test_store_save_overwritesExistingEntryForSameClientMsgId() {
        let bytesOld = Data(repeating: 0x44, count: 8)
        let bytesNew = Data(repeating: 0x55, count: 8)
        let fpOld = TusResumeStateStore.fingerprint(of: bytesOld)
        let fpNew = TusResumeStateStore.fingerprint(of: bytesNew)
        let original = makeState(clientMsgId: "msg-overwrite", fileId: "file-old", sourceSizeAtStart: fpOld.size, sourceSha256AtStart: fpOld.sha256Hex)
        let updated = makeState(clientMsgId: "msg-overwrite", fileId: "file-new", sourceSizeAtStart: fpNew.size, sourceSha256AtStart: fpNew.sha256Hex)

        TusResumeStateStore.save(original)
        TusResumeStateStore.save(updated)
        defer { TusResumeStateStore.clear(clientMsgId: "msg-overwrite") }

        let loaded = TusResumeStateStore.load(clientMsgId: "msg-overwrite")
        XCTAssertEqual(loaded?.fileId, "file-new")
    }

    // MARK: - fingerprint()

    func test_fingerprint_matchesManualSha256() {
        let bytes = Data("hello world".utf8)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(fp.sha256Hex, expectedHash)
        XCTAssertEqual(fp.size, Int64(bytes.count))
    }

    // MARK: - checkCorruption()

    func test_checkCorruption_matchingFile_returnsResumable() {
        let bytes = Data(repeating: 0x66, count: 1024)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let path = writeFile(named: "matching.bin", contents: bytes)
        let state = makeState(clientMsgId: "msg-ok", sourceSizeAtStart: fp.size, sourceSha256AtStart: fp.sha256Hex)

        let result = TusResumeStateStore.checkCorruption(state: state, sourcePath: path)
        XCTAssertEqual(result, .resumable)
    }

    func test_checkCorruption_missingFile_returnsCorrupted() {
        let bytes = Data(repeating: 0x77, count: 32)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let missingPath = tempDir.appendingPathComponent("does-not-exist.bin").path
        let state = makeState(clientMsgId: "msg-missing", sourceSizeAtStart: fp.size, sourceSha256AtStart: fp.sha256Hex)

        let result = TusResumeStateStore.checkCorruption(state: state, sourcePath: missingPath)
        guard case .corrupted(let reason) = result else {
            XCTFail("expected .corrupted for a missing file, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("missing"), "reason should mention the file is missing: \(reason)")
    }

    func test_checkCorruption_sizeMismatch_returnsCorrupted() {
        let originalBytes = Data(repeating: 0x88, count: 100)
        let fp = TusResumeStateStore.fingerprint(of: originalBytes)
        // On-disk file is a DIFFERENT size than what was recorded —
        // simulates the source having been re-recorded/replaced since
        // the interrupted attempt.
        let differentSizeBytes = Data(repeating: 0x88, count: 50)
        let path = writeFile(named: "size-mismatch.bin", contents: differentSizeBytes)
        let state = makeState(clientMsgId: "msg-sizemismatch", sourceSizeAtStart: fp.size, sourceSha256AtStart: fp.sha256Hex)

        let result = TusResumeStateStore.checkCorruption(state: state, sourcePath: path)
        guard case .corrupted(let reason) = result else {
            XCTFail("expected .corrupted for a size mismatch, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("size mismatch"), "reason should mention size mismatch: \(reason)")
    }

    func test_checkCorruption_hashMismatch_sameSizeDifferentContent_returnsCorrupted() {
        let originalBytes = Data(repeating: 0x99, count: 64)
        let fp = TusResumeStateStore.fingerprint(of: originalBytes)
        // Same SIZE as recorded, but different CONTENT — must be caught
        // by the hash check even though the (cheaper) size check alone
        // wouldn't catch it.
        var mutatedBytes = originalBytes
        mutatedBytes[0] = 0xAA
        XCTAssertEqual(mutatedBytes.count, originalBytes.count)
        let path = writeFile(named: "hash-mismatch.bin", contents: mutatedBytes)
        let state = makeState(clientMsgId: "msg-hashmismatch", sourceSizeAtStart: fp.size, sourceSha256AtStart: fp.sha256Hex)

        let result = TusResumeStateStore.checkCorruption(state: state, sourcePath: path)
        guard case .corrupted(let reason) = result else {
            XCTFail("expected .corrupted for a hash mismatch, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("sha256"), "reason should mention sha256 mismatch: \(reason)")
    }

    // MARK: - W-TUSRESUME (security-review follow-up): PSK fingerprint check

    func test_checkCorruption_pskFingerprintMatches_returnsResumable() {
        // Plaintext matches AND the caller's current PSK fingerprint
        // matches what was recorded -> resumable.
        let bytes = Data(repeating: 0xCC, count: 32)
        let psk = Data(repeating: 0xDD, count: 32)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let pskFp = TusResumeStateStore.fingerprint(ofPsk: psk)
        let path = writeFile(named: "psk-match.bin", contents: bytes)
        let state = makeState(
            clientMsgId: "msg-pskmatch", sourceSizeAtStart: fp.size,
            sourceSha256AtStart: fp.sha256Hex, pskFingerprintHex: pskFp
        )

        let result = TusResumeStateStore.checkCorruption(
            state: state, sourcePath: path, currentPskFingerprintHex: pskFp
        )
        XCTAssertEqual(result, .resumable)
    }

    func test_checkCorruption_pskFingerprintMismatch_returnsCorrupted() {
        // Plaintext is UNCHANGED (source file matches exactly) but the
        // PSK fingerprint differs from what was recorded — simulates the
        // contact's PSK having rotated/been re-bound between the failed
        // attempt and the retry. This is the exact scenario the
        // security review flagged: without this check, a stale resume
        // would silently PATCH a continuation sealed with a DIFFERENT
        // key than what the server's partial upload already has,
        // corrupting the assembled file without any error surfacing
        // until the recipient fails to decrypt.
        let bytes = Data(repeating: 0xEE, count: 32)
        let originalPsk = Data(repeating: 0x01, count: 32)
        let rotatedPsk = Data(repeating: 0x02, count: 32)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let originalPskFp = TusResumeStateStore.fingerprint(ofPsk: originalPsk)
        let rotatedPskFp = TusResumeStateStore.fingerprint(ofPsk: rotatedPsk)
        XCTAssertNotEqual(originalPskFp, rotatedPskFp)

        let path = writeFile(named: "psk-mismatch.bin", contents: bytes)
        let state = makeState(
            clientMsgId: "msg-pskmismatch", sourceSizeAtStart: fp.size,
            sourceSha256AtStart: fp.sha256Hex, pskFingerprintHex: originalPskFp
        )

        let result = TusResumeStateStore.checkCorruption(
            state: state, sourcePath: path, currentPskFingerprintHex: rotatedPskFp
        )
        guard case .corrupted(let reason) = result else {
            XCTFail("expected .corrupted for a PSK fingerprint mismatch, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("psk"), "reason should mention the psk mismatch: \(reason)")
    }

    func test_checkCorruption_noPskFingerprintSupplied_skipsPskCheck_backwardCompatible() {
        // A caller that doesn't pass `currentPskFingerprintHex` (the
        // parameter's default) gets the pre-existing plaintext-only
        // check — this is the backward-compatibility contract for any
        // call site that hasn't been updated to resolve a PSK yet.
        let bytes = Data(repeating: 0xFA, count: 16)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let path = writeFile(named: "no-psk-check.bin", contents: bytes)
        let state = makeState(
            clientMsgId: "msg-nopskcheck", sourceSizeAtStart: fp.size,
            sourceSha256AtStart: fp.sha256Hex, pskFingerprintHex: "irrelevant-if-not-checked"
        )

        let result = TusResumeStateStore.checkCorruption(state: state, sourcePath: path)
        XCTAssertEqual(result, .resumable)
    }

    func test_pskFingerprint_isDeterministic_andDiffersForDifferentKeys() {
        let pskA = Data(repeating: 0x11, count: 32)
        let pskB = Data(repeating: 0x22, count: 32)
        XCTAssertEqual(TusResumeStateStore.fingerprint(ofPsk: pskA), TusResumeStateStore.fingerprint(ofPsk: pskA))
        XCTAssertNotEqual(TusResumeStateStore.fingerprint(ofPsk: pskA), TusResumeStateStore.fingerprint(ofPsk: pskB))
    }

    // MARK: - Codable round-trip (JSON, as persisted in UserDefaults)

    func test_state_codableRoundTrip_preservesAllFields() throws {
        let bytes = Data(repeating: 0xBB, count: 16)
        let fp = TusResumeStateStore.fingerprint(of: bytes)
        let state = TusResumeState(
            fileId: "codable-file",
            clientMsgId: "codable-msg",
            totalBytes: fp.size,
            sourceSizeAtStart: fp.size,
            sourceSha256AtStart: fp.sha256Hex,
            saltHex: "0123456789abcdef",
            nonceHex: "fedcba9876543210",
            ts: 1_234_567_890_123,
            recipientUserId: "recipient-xyz",
            filename: "img-1.jpg",
            mime: "image/jpeg",
            pskFingerprintHex: String(repeating: "dd", count: 32),
            durationMs: nil,
            timerOverrideSeconds: 3600
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(TusResumeState.self, from: encoded)

        XCTAssertEqual(decoded, state)
        XCTAssertNil(decoded.durationMs)
        XCTAssertEqual(decoded.timerOverrideSeconds, 3600)
    }

    func test_store_loadAll_corruptedUserDefaultsData_decodesToEmptyMap() {
        // Best-effort local bookkeeping contract: garbage in UserDefaults
        // under the store's key must never crash or throw — it degrades
        // to "nothing resumable" so a caller always falls through to
        // tier 3 safely.
        let key = "qaudion.tus.resumeState.v1"
        let previous = UserDefaults.standard.data(forKey: key)
        defer {
            if let previous = previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(Data([0xFF, 0x00, 0x13, 0x37]), forKey: key)

        let all = TusResumeStateStore.loadAll()
        XCTAssertTrue(all.isEmpty)
    }
}

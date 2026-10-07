import XCTest
import CryptoKit
@testable import QAudionEngine

/// Behaviour of the file v2 library that the known-answer vectors do not cover: the anti-nonce-reuse rule, the
/// per-chunk and file-to-file streaming (resume, out-of-order and duplicate chunks, a changing source, memory),
/// the key commitment, the geometry and the API's refusals. The vectors themselves are in `FileV2KatTests`.
final class FileV2LibraryTests: XCTestCase {

    private typealias Support = FileV2TestSupport
    private let chunk = FileV2.chunkSize

    // MARK: Padme

    func testPadmeProperties() {
        var previous: UInt64 = 0
        var notMonotonic = 0, belowLength = 0, overheadTooBig = 0
        for length in UInt64(1)...300_000 {
            let padded = FileV2.padme(length)
            if padded < previous { notMonotonic += 1 }
            if padded < length { belowLength += 1 }
            previous = padded
            // Section 12.3: at most 12.5% up to 255 bytes, under 6.25% up to 64 KiB.
            if length <= 255 {
                if (padded - length) * 8 > length { overheadTooBig += 1 }
            } else if length <= 65_536 {
                if (padded - length) * 16 >= length { overheadTooBig += 1 }
            }
        }
        XCTAssertEqual(notMonotonic, 0, "padme is monotonic")
        XCTAssertEqual(belowLength, 0, "padme never shortens")
        XCTAssertEqual(overheadTooBig, 0, "padme overhead above the figures of section 12.3")
    }

    func testPadmeEdges() {
        XCTAssertEqual(FileV2.padme(0), 0)
        XCTAssertEqual(FileV2.padme(1), 1)
        XCTAssertEqual(FileV2.padme(FileV2.maxSize), FileV2.maxStream, "padme(5 GiB) is exactly 5 GiB")
        // No trap on overflow: the format never accepts these lengths.
        XCTAssertEqual(FileV2.padme(UInt64.max), UInt64.max)
        // The overhead stays under 3.2% up to 4 GiB and under 1.6% beyond (section 12.3).
        let upToFourGiB: [UInt64] = [65_537, 1 << 20, (1 << 20) + 1, 100_000_007, 1 << 30, (1 << 32) - 1]
        for length in upToFourGiB {
            let padded = FileV2.padme(length)
            XCTAssertLessThan(Double(padded - length) / Double(length), 0.032, "padme(\(length))")
        }
        let beyondFourGiB: [UInt64] = [(1 << 32) + 1, 4_500_000_000, FileV2.maxSize - 1]
        for length in beyondFourGiB {
            let padded = FileV2.padme(length)
            XCTAssertLessThan(Double(padded - length) / Double(length), 0.016, "padme(\(length))")
            XCTAssertLessThanOrEqual(padded, FileV2.maxStream)
        }
    }

    func testChunkAlignmentOfPaddedStreams() {
        // Padme never makes a chunk of pure padding: the last chunk always carries at least one real byte.
        let sizes: [UInt64] = [1, 1023, 1 << 20, (1 << 20) + 1, (2 << 20) - 1, (3 << 20) + 5, 5 << 30]
        for size in sizes {
            guard let encryptor = try? FileV2Encryptor(fileKey: Data(count: 32), fileID: Data(count: 16),
                                                       plaintextSize: size) else {
                return XCTFail("encryptor for \(size)")
            }
            XCTAssertGreaterThan(encryptor.chunkFileLength(encryptor.totalChunks - 1), 0, "size \(size)")
            XCTAssertEqual(encryptor.chunkFileLength(0), min(chunk, Int(min(size, UInt64(Int.max)))))
        }
    }

    // MARK: Geometry

    func testGeometryOfParts() throws {
        let encryptor = try FileV2Encryptor(fileKey: Data(count: 32), fileID: Data(count: 16),
                                            plaintextSize: UInt64(20 * chunk))
        // Section 12.10: a part is 8 chunks and starts at 64 + p x 8 x STRIDE.
        XCTAssertEqual(encryptor.blobOffset(ofChunk: 0), 64)
        XCTAssertEqual(encryptor.blobOffset(ofChunk: 8), 64 + 8 * UInt64(FileV2.stride))
        XCTAssertEqual(encryptor.blobOffset(ofChunk: 16), 64 + 16 * UInt64(FileV2.stride))
        XCTAssertEqual(encryptor.totalChunks, 20)
        XCTAssertEqual(encryptor.blobLength, 64 + UInt64(20 * chunk) + 20 * 16)
        XCTAssertEqual(encryptor.sealedChunkLength(0), FileV2.stride)
    }

    /// The public geometry helpers are total: an index outside the file, negative included, never traps (no
    /// `UInt64(index)` of a negative number, no overflow): lengths are 0 and the offset is `nil`.
    func testGeometryNeverTrapsOnAnIndexOutsideTheFile() throws {
        let size = UInt64(2 * chunk + 5)
        let encryptor = try FileV2Encryptor(fileKey: Data(count: 32), fileID: Data(count: 16), plaintextSize: size)
        let receiver = try FileV2Decryptor(fileID: encryptor.fileID, fileKey: encryptor.fileKey,
                                           header: encryptor.header.bytes, size: size)
        XCTAssertEqual(encryptor.totalChunks, 3)
        let outside = [-1, -2, Int.min, Int.min + 1, Int.max, Int.max - 1, 3, 4, 5120, 1 << 40]
        for index in outside {
            XCTAssertEqual(encryptor.chunkStreamLength(index), 0, "chunkStreamLength(\(index))")
            XCTAssertEqual(encryptor.chunkFileLength(index), 0, "chunkFileLength(\(index))")
            XCTAssertEqual(encryptor.sealedChunkLength(index), 0, "sealedChunkLength(\(index))")
            XCTAssertNil(encryptor.blobOffset(ofChunk: index), "blobOffset(\(index))")
            XCTAssertEqual(receiver.chunkStreamLength(index), 0, "receiver chunkStreamLength(\(index))")
            XCTAssertEqual(receiver.sealedChunkLength(index), 0, "receiver sealedChunkLength(\(index))")
            XCTAssertNil(receiver.blobOffset(ofChunk: index), "receiver blobOffset(\(index))")
            XCTAssertFalse(receiver.isVerified(chunk: index))
        }
        // Inside the file they are the real numbers.
        XCTAssertEqual(encryptor.chunkStreamLength(0), chunk)
        // 2 MiB + 5 bytes pad to 2 MiB + 64 KiB (Padme): the last chunk holds 5 real bytes and the padding.
        XCTAssertEqual(encryptor.streamLength, UInt64(2 * chunk + 65_536))
        XCTAssertEqual(encryptor.chunkStreamLength(2), 65_536)
        XCTAssertEqual(encryptor.chunkFileLength(2), 5)
        XCTAssertEqual(encryptor.sealedChunkLength(2), 65_536 + FileV2.tagSize)
        XCTAssertEqual(encryptor.blobOffset(ofChunk: 2), 64 + 2 * UInt64(FileV2.stride))
        XCTAssertEqual(receiver.sealedChunkLength(1), FileV2.stride)
        XCTAssertEqual(receiver.blobOffset(ofChunk: 1), 64 + UInt64(FileV2.stride))
        // The calls that take an index refuse it without a trap too.
        XCTAssertThrowsError(try encryptor.sealChunk(index: Int.min, fileBytes: Data()))
        XCTAssertNil(try receiver.openChunk(index: Int.min, sealed: Data()))
        XCTAssertNil(try receiver.openChunk(index: Int.max, sealed: Data()))
        XCTAssertFalse(receiver.markUnverified(chunk: Int.min))
    }

    func testEncryptorRefusesSizesAndKeysOutOfRange() {
        XCTAssertThrowsError(try FileV2Encryptor(fileKey: Data(count: 32), fileID: Data(count: 16), plaintextSize: 0))
        XCTAssertThrowsError(try FileV2Encryptor(fileKey: Data(count: 32), fileID: Data(count: 16),
                                                 plaintextSize: FileV2.maxSize + 1))
        XCTAssertThrowsError(try FileV2Encryptor(fileKey: Data(count: 31), fileID: Data(count: 16), plaintextSize: 1))
        XCTAssertThrowsError(try FileV2Encryptor(fileKey: Data(count: 32), fileID: Data(count: 15), plaintextSize: 1))
        XCTAssertNoThrow(try FileV2Encryptor(fileKey: Data(count: 32), fileID: Data(count: 16),
                                             plaintextSize: FileV2.maxSize))
        XCTAssertThrowsError(try FileV2Encryptor.makeNew(plaintextSize: 0))
        XCTAssertThrowsError(try FileV2Encryptor.resume(fileKey: Data(count: 31), fileID: Data(count: 16),
                                                        plaintextSize: 1, persistedTags: [:]))
    }

    func testFreshKeyMaterialIsRandomAndNeverReused() throws {
        let keys = (0..<8).map { _ in FileV2.generateFileKey() }
        let ids = (0..<8).map { _ in FileV2.generateFileID() }
        XCTAssertEqual(Set(keys).count, 8)
        XCTAssertEqual(Set(ids).count, 8)
        XCTAssertTrue(keys.allSatisfy { $0.count == 32 })
        XCTAssertTrue(ids.allSatisfy { $0.count == 16 })
        let first = try FileV2Encryptor.makeNew(plaintextSize: 10)
        let second = try FileV2Encryptor.makeNew(plaintextSize: 10)
        XCTAssertNotEqual(first.fileKey, second.fileKey)
        XCTAssertNotEqual(first.fileID, second.fileID)
        XCTAssertNotEqual(first.header.commitment, second.header.commitment)
        XCTAssertTrue(first.tagEntries.isEmpty, "a new file has encrypted nothing")
    }

    // MARK: The header

    func testHeaderParseRefusesEveryMalformedHeader() throws {
        let encryptor = try FileV2Encryptor(fileKey: Data(repeating: 7, count: 32), fileID: Data(repeating: 9, count: 16),
                                            plaintextSize: 1023)
        let good = encryptor.header.bytes
        XCTAssertEqual(try FileV2Header.parse(good), encryptor.header)
        func assertBadHeader(_ mutate: (inout [UInt8]) -> Void, _ label: String) {
            var raw = [UInt8](good)
            mutate(&raw)
            XCTAssertThrowsError(try FileV2Header.parse(Data(raw)), label) { error in
                XCTAssertEqual(error as? FileV2Error, .badHeader, label)
            }
        }
        assertBadHeader({ $0[3] = 0x01 }, "version byte")
        assertBadHeader({ $0[0] ^= 0x80 }, "magic")
        assertBadHeader({ for i in 20..<28 { $0[i] = 0 } }, "stream_len 0")
        assertBadHeader({ for i in 20..<28 { $0[i] = 0 }; $0[20] = 0x7F }, "stream_len beyond MAX_STREAM")
        assertBadHeader({ $0[31] = 2 }, "total_chunks incoherent with stream_len")
        assertBadHeader({ for i in 28..<32 { $0[i] = 0 } }, "total_chunks 0")
        XCTAssertThrowsError(try FileV2Header.parse(good.prefix(63))) { XCTAssertEqual($0 as? FileV2Error, .badHeader) }
        XCTAssertThrowsError(try FileV2Header.parse(good + Data([0]))) { XCTAssertEqual($0 as? FileV2Error, .badHeader) }
        // A slice with a non-zero start index parses like the original.
        let padded = Data([1, 2, 3]) + good
        XCTAssertEqual(try FileV2Header.parse(padded.dropFirst(3)), encryptor.header)
    }

    // MARK: Key commitment (section 12.6)

    func testABlobOpensUnderOneKeyOnly() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let id = FileV2.generateFileID()
        let keyA = FileV2.generateFileKey()
        var keyB = keyA
        keyB[0] ^= 1
        let size: UInt64 = 5000
        let sender = try FileV2Encryptor(fileKey: keyA, fileID: id, plaintextSize: size)
        let plain = directory.appendingPathComponent("plain")
        let blob = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        try sender.encryptFile(from: plain, to: blob)

        // Key B with the header of the blob: the commitment is not the one derived from key B.
        XCTAssertThrowsError(try FileV2Decryptor(fileID: id, fileKey: keyB, header: sender.header.bytes, size: size)) {
            XCTAssertEqual($0 as? FileV2Error, .commitMismatch)
        }
        // Key B with ITS OWN header (a sender that hands another key and header for the same blob): the source
        // header differs from the descriptor header.
        let other = try FileV2Encryptor(fileKey: keyB, fileID: id, plaintextSize: size)
        let receiverB = try FileV2Decryptor(fileID: id, fileKey: keyB, header: other.header.bytes, size: size)
        XCTAssertNotEqual(other.header.commitment, sender.header.commitment)
        XCTAssertThrowsError(try receiverB.decryptFile(from: blob, to: directory.appendingPathComponent("out-b"))) {
            XCTAssertEqual($0 as? FileV2Error, .headerMismatch)
        }
        // And the right key opens it.
        let receiverA = try FileV2Decryptor(fileID: id, fileKey: keyA, header: sender.header.bytes, size: size)
        XCTAssertNoThrow(try receiverA.decryptFile(from: blob, to: directory.appendingPathComponent("out-a")))
    }

    func testKeyIsNeverTheAesKey() {
        // K_enc is derived: it differs from K, and from the PRK.
        let key = Data((0..<32).map { UInt8($0) })
        let keys = FileV2Crypto.derive(fileKey: key, fileID: Data(count: 16))
        XCTAssertNotEqual(keys.encryptionKey.withUnsafeBytes { Data($0) }, key)
        XCTAssertNotEqual(keys.encryptionKey.withUnsafeBytes { Data($0) }, keys.prk)
        XCTAssertNotEqual(keys.commitment, keys.encryptionKey.withUnsafeBytes { Data($0) })
    }

    // MARK: Anti-nonce-reuse rule (section 12.8)

    func testChangedChunkIsRefusedAndNothingIsReturned() throws {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: UInt64(2 * chunk + 100))
        let content = Support.plaintextBlock(offset: UInt64(chunk), count: chunk)
        let first = try encryptor.sealChunk(index: 1, fileBytes: content)
        // The same content again: identical bytes, deterministic, accepted (a retry or a resume).
        XCTAssertEqual(try encryptor.sealChunk(index: 1, fileBytes: content), first)
        XCTAssertFalse(encryptor.isCancelled)

        // A different content at the same index would reuse the nonce under the same key: refused.
        var changed = content
        changed[17] ^= 0x01
        XCTAssertThrowsError(try encryptor.sealChunk(index: 1, fileBytes: changed)) { error in
            XCTAssertEqual(error as? FileV2Error, .contentChanged)
            XCTAssertEqual((error as? FileV2Error)?.code, "cancelled")
        }
        // Nothing was recorded for the changed content: the ledger still holds the tag of the original, one entry.
        XCTAssertEqual(encryptor.tagLedger.count, 1)
        XCTAssertEqual(encryptor.tagLedger.tag(at: 1), Data(first.suffix(FileV2.tagSize)))
        XCTAssertEqual(encryptor.tagEntries, [1: Data(first.suffix(FileV2.tagSize))])
    }

    /// CANCELLED is sticky: after the first conflict the transfer is over, whatever is asked next. The sender sends
    /// `qa_file_cancel` and starts a NEW file with a new `K` and `file_id`; nothing more is ever sealed under this one,
    /// not even a chunk whose content is unchanged, and the key is gone.
    func testCancelledIsStickyAfterTheFirstConflict() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(2 * chunk + 100)
        let encryptor = try FileV2Encryptor(fileKey: FileV2.generateFileKey(), fileID: FileV2.generateFileID(),
                                            plaintextSize: size)
        let content0 = Support.plaintextBlock(offset: 0, count: chunk)
        let sealed0 = try encryptor.sealChunk(index: 0, fileBytes: content0)
        var edited = content0
        edited[0] ^= 0xFF
        XCTAssertThrowsError(try encryptor.sealChunk(index: 0, fileBytes: edited)) {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        XCTAssertTrue(encryptor.isCancelled)

        // Every later seal is refused, by every path: the unchanged chunk, a chunk never sealed, a handle, a whole file.
        XCTAssertThrowsError(try encryptor.sealChunk(index: 0, fileBytes: content0), "the original chunk") {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        XCTAssertThrowsError(try encryptor.sealChunk(index: 1, fileBytes: Support.plaintextBlock(offset: UInt64(chunk),
                                                                                                count: chunk)),
                             "a chunk never sealed") {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        let plain = directory.appendingPathComponent("plain")
        try Support.writePlaintextFile(size: size, to: plain)
        let handle = try FileHandle(forReadingFrom: plain)
        defer { try? handle.close() }
        XCTAssertThrowsError(try encryptor.sealChunk(index: 0, from: handle), "from a handle") {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        let blob = directory.appendingPathComponent("blob")
        XCTAssertThrowsError(try encryptor.encryptFile(from: plain, to: blob), "file to file") {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        // The sticky state still says "cancelled" (wire code), not "closed", and the ledger did not move.
        XCTAssertEqual(FileV2Error.contentChanged.code, "cancelled")
        XCTAssertEqual(encryptor.tagLedger.count, 1)
        XCTAssertEqual(encryptor.tagEntries[0], Data(sealed0.suffix(FileV2.tagSize)))
        // The key is wiped: there is nothing left to reuse.
        XCTAssertTrue(encryptor.fileKey.isEmpty)
        // Closing does not clear the cancellation.
        encryptor.close()
        XCTAssertTrue(encryptor.isCancelled)
        XCTAssertThrowsError(try encryptor.sealChunk(index: 0, fileBytes: content0)) {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
    }

    /// A source that changed size is the same rule (section 12.8 rule 1): it cancels for good too.
    func testASourceThatChangedCancelsTheEncryptorForGood() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let plain = directory.appendingPathComponent("plain")
        try Support.writePlaintextFile(size: UInt64(chunk + 100), to: plain)
        // Declares more than there is: a short read inside the handle path.
        let shrunk = try FileV2Encryptor.makeNew(plaintextSize: UInt64(chunk + 4000))
        let handle = try FileHandle(forReadingFrom: plain)
        defer { try? handle.close() }
        XCTAssertNoThrow(try shrunk.sealChunk(index: 0, from: handle))
        XCTAssertThrowsError(try shrunk.sealChunk(index: 1, from: handle)) { XCTAssertEqual($0 as? FileV2Error, .contentChanged) }
        XCTAssertTrue(shrunk.isCancelled)
        XCTAssertThrowsError(try shrunk.sealChunk(index: 0, from: handle), "chunk 0 is refused now too") {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        // A file of another size at the start of encryptFile.
        let wrongSize = try FileV2Encryptor.makeNew(plaintextSize: 3000)
        XCTAssertThrowsError(try wrongSize.encryptFile(from: plain, to: directory.appendingPathComponent("blob"))) {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        XCTAssertTrue(wrongSize.isCancelled)
    }

    func testRuleSurvivesAResumeThroughThePersistedTags() throws {
        let key = FileV2.generateFileKey(), id = FileV2.generateFileID()
        let size = UInt64(2 * chunk + 100)
        let firstRun = try FileV2Encryptor(fileKey: key, fileID: id, plaintextSize: size)
        let content0 = Support.plaintextBlock(offset: 0, count: chunk)
        let sealed0 = try firstRun.sealChunk(index: 0, fileBytes: content0)

        // The pipeline stores `tagEntries` in the local transfer state and hands it back on resume: the encryptor owns
        // the ledger and loads it AT CONSTRUCTION, before anything can be sealed.
        let persisted = firstRun.tagEntries
        XCTAssertEqual(persisted.count, 1)
        let resumed = try FileV2Encryptor.resume(fileKey: key, fileID: id, plaintextSize: size, persistedTags: persisted)
        XCTAssertEqual(resumed.tagEntries, persisted)
        XCTAssertEqual(resumed.header, firstRun.header)
        XCTAssertEqual(try resumed.sealChunk(index: 0, fileBytes: content0), sealed0)
        var edited = content0
        edited[0] ^= 0xFF
        XCTAssertThrowsError(try resumed.sealChunk(index: 0, fileBytes: edited)) {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
        XCTAssertTrue(resumed.isCancelled)
        // Without the persisted tags the same edit would go through: that is why no public initialiser can start a
        // resume with an empty ledger (the initialiser for given key material is internal; `makeNew` draws fresh
        // material, and `resume` takes the tags).
        let forgetful = try FileV2Encryptor(fileKey: key, fileID: id, plaintextSize: size)
        XCTAssertNoThrow(try forgetful.sealChunk(index: 0, fileBytes: edited))
    }

    func testResumeRefusesACorruptedPersistedState() throws {
        let key = FileV2.generateFileKey(), id = FileV2.generateFileID()
        let size = UInt64(2 * chunk + 100)        // 3 chunks
        let tag = Data(count: FileV2.tagSize)
        XCTAssertNoThrow(try FileV2Encryptor.resume(fileKey: key, fileID: id, plaintextSize: size,
                                                    persistedTags: [0: tag, 2: tag]))
        XCTAssertNoThrow(try FileV2Encryptor.resume(fileKey: key, fileID: id, plaintextSize: size, persistedTags: [:]),
                         "a transfer that sealed nothing")
        let corrupted: [[Int: Data]] = [[-1: tag], [3: tag], [FileV2.maxChunks: tag], [Int.max: tag],
                                        [0: Data(count: 15)], [0: Data(count: 17)], [0: Data()]]
        for entries in corrupted {
            XCTAssertThrowsError(try FileV2Encryptor.resume(fileKey: key, fileID: id, plaintextSize: size,
                                                            persistedTags: entries), "\(entries.keys)") { error in
                guard case FileV2Error.invalidArgument = error else { return XCTFail("\(error)") }
            }
        }
        // The ledger itself.
        XCTAssertNoThrow(try FileV2TagLedger(entries: [0: tag, FileV2.maxChunks - 1: tag], chunkCount: FileV2.maxChunks))
        XCTAssertThrowsError(try FileV2TagLedger(entries: [-1: tag], chunkCount: FileV2.maxChunks))
        XCTAssertThrowsError(try FileV2TagLedger(entries: [FileV2.maxChunks: tag], chunkCount: FileV2.maxChunks))
        XCTAssertThrowsError(try FileV2TagLedger(entries: [5: tag], chunkCount: 5))
    }

    func testSealChunkRefusesAWrongIndexOrLength() throws {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: UInt64(chunk + 10))
        XCTAssertThrowsError(try encryptor.sealChunk(index: -1, fileBytes: Data(count: chunk)))
        XCTAssertThrowsError(try encryptor.sealChunk(index: encryptor.totalChunks, fileBytes: Data(count: 10)))
        XCTAssertThrowsError(try encryptor.sealChunk(index: 0, fileBytes: Data(count: chunk - 1)))
        XCTAssertThrowsError(try encryptor.sealChunk(index: 1, fileBytes: Data(count: 11)))
        XCTAssertEqual(encryptor.tagLedger.count, 0, "a refused call records nothing")
        XCTAssertFalse(encryptor.isCancelled, "a malformed call is not a conflict")
        XCTAssertNoThrow(try encryptor.sealChunk(index: 0, fileBytes: Data(count: chunk)))
    }

    // MARK: Closing: no sealing, no opening with a zeroed key

    func testAClosedEncryptorNeverSealsAndHoldsNoKey() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let plain = directory.appendingPathComponent("plain")
        try Support.writePlaintextFile(size: 100, to: plain)
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: 100)
        let copyOfKey = encryptor.fileKey
        XCTAssertEqual(copyOfKey.count, 32)
        XCTAssertNoThrow(try encryptor.sealChunk(index: 0, fileBytes: Support.plaintextBlock(offset: 0, count: 100)))

        encryptor.close()
        XCTAssertTrue(encryptor.fileKey.isEmpty, "the key is wiped")
        XCTAssertFalse(encryptor.isCancelled, "closing is not a conflict")
        let handle = try FileHandle(forReadingFrom: plain)
        defer { try? handle.close() }
        XCTAssertThrowsError(try encryptor.sealChunk(index: 0, fileBytes: Support.plaintextBlock(offset: 0, count: 100))) {
            XCTAssertEqual($0 as? FileV2Error, .closed)
        }
        XCTAssertThrowsError(try encryptor.sealChunk(index: 0, from: handle)) { XCTAssertEqual($0 as? FileV2Error, .closed) }
        XCTAssertThrowsError(try encryptor.encryptFile(from: plain, to: directory.appendingPathComponent("blob"))) {
            XCTAssertEqual($0 as? FileV2Error, .closed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("blob").path))
        XCTAssertEqual(FileV2Error.closed.code, "closed")
        encryptor.close()   // idempotent
        // The header (public) and the tags already recorded are still readable: a closed encryptor only stops sealing.
        XCTAssertEqual(encryptor.tagEntries.count, 1)
        XCTAssertEqual(encryptor.header.bytes.count, FileV2.headerLength)
        // The copy of K handed out earlier is the caller's own value.
        XCTAssertEqual(copyOfKey.count, 32)
    }

    func testWipeOverwritesTheSecretBytes() {
        var secret = Data((1...32).map { UInt8($0) })
        FileV2Secret.wipe(&secret)
        XCTAssertTrue(secret.isEmpty)
        var empty = Data()
        FileV2Secret.wipe(&empty)
        XCTAssertTrue(empty.isEmpty)
        var keys = FileV2Crypto.derive(fileKey: Data(repeating: 5, count: 32), fileID: Data(repeating: 6, count: 16))
        XCTAssertEqual(keys.prk.count, 32)
        XCTAssertEqual(keys.noncePrefix.count, 8)
        keys.wipe()
        XCTAssertTrue(keys.prk.isEmpty)
        XCTAssertTrue(keys.noncePrefix.isEmpty)
    }

    func testAClosedReceiverNeitherOpensNorWritesNorFinalizes() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let plain = directory.appendingPathComponent("plain")
        let blob = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: 500, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: 500)
        try sender.encryptFile(from: plain, to: blob)
        let sealed = try Data(contentsOf: blob).dropFirst(FileV2.headerLength)

        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: 500)
        XCTAssertNotNil(try receiver.openChunk(index: 0, sealed: Data(sealed)))
        receiver.close()
        let outURL = directory.appendingPathComponent("out")
        XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: nil))
        let output = try FileHandle(forUpdating: outURL)
        defer { try? output.close() }
        XCTAssertThrowsError(try receiver.openChunk(index: 0, sealed: Data(sealed))) { XCTAssertEqual($0 as? FileV2Error, .closed) }
        XCTAssertThrowsError(try receiver.receive(index: 0, sealed: Data(sealed), writingTo: output)) {
            XCTAssertEqual($0 as? FileV2Error, .closed)
        }
        XCTAssertThrowsError(try receiver.finalize(output: output)) { XCTAssertEqual($0 as? FileV2Error, .closed) }
        XCTAssertThrowsError(try receiver.decryptFile(from: blob, to: directory.appendingPathComponent("out2"))) {
            XCTAssertEqual($0 as? FileV2Error, .closed)
        }
        XCTAssertEqual(try Data(contentsOf: outURL).count, 0, "nothing was written after close")
        XCTAssertEqual(receiver.verifiedCount, 0)
        receiver.close()    // idempotent
    }

    func testPartsSealedInParallelEqualTheSequentialBlob() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(7 * chunk + 12_345)
        let plain = directory.appendingPathComponent("plain")
        try Support.writePlaintextFile(size: size, to: plain)
        let key = FileV2.generateFileKey(), id = FileV2.generateFileID()

        let sequential = try FileV2Encryptor(fileKey: key, fileID: id, plaintextSize: size)
        let sequentialBlob = directory.appendingPathComponent("sequential")
        try sequential.encryptFile(from: plain, to: sequentialBlob)
        let expected = try Data(contentsOf: sequentialBlob)

        // Several workers, one index each, a handle each, one shared encryptor. Every index is sealed twice (a retry).
        let parallel = try FileV2Encryptor(fileKey: key, fileID: id, plaintextSize: size)
        let count = parallel.totalChunks
        var results = [Data?](repeating: nil, count: count)
        let resultsLock = NSLock()
        let failures = NSLock()
        var failed = 0
        DispatchQueue.concurrentPerform(iterations: count) { index in
            do {
                let handle = try FileHandle(forReadingFrom: plain)
                defer { try? handle.close() }
                let sealed = try parallel.sealChunk(index: index, from: handle)
                let again = try parallel.sealChunk(index: index, from: handle)
                guard sealed == again else { throw FileV2Error.contentChanged }
                resultsLock.lock(); results[index] = sealed; resultsLock.unlock()
            } catch {
                failures.lock(); failed += 1; failures.unlock()
            }
        }
        XCTAssertEqual(failed, 0)
        var assembled = parallel.header.bytes
        for index in 0..<count { assembled.append(try XCTUnwrap(results[index], "chunk \(index) missing")) }
        XCTAssertEqual(assembled, expected)
        XCTAssertEqual(parallel.tagLedger.count, count)
        XCTAssertEqual(parallel.tagEntries, sequential.tagEntries)
        XCTAssertFalse(parallel.isCancelled)
    }

    /// One worker hits the conflict while others seal: the cancellation is seen by all of them, nothing is returned after
    /// it and the encryptor never "un-cancels".
    func testAConflictInOneWorkerCancelsTheOthers() throws {
        let size = UInt64(8 * chunk)
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: size)
        let contents = (0..<8).map { Support.plaintextBlock(offset: UInt64($0 * chunk), count: chunk) }
        // Record every tag once.
        for index in 0..<8 { _ = try encryptor.sealChunk(index: index, fileBytes: contents[index]) }
        var tampered = contents[3]
        tampered[1] ^= 1
        var conflicts = 0, refused = 0, sealedAfter = 0
        let counters = NSLock()
        DispatchQueue.concurrentPerform(iterations: 9) { worker in
            if worker == 8 {
                // The conflicting worker.
                do {
                    _ = try encryptor.sealChunk(index: 3, fileBytes: tampered)
                } catch {
                    counters.lock(); conflicts += 1; counters.unlock()
                }
                return
            }
            // The other workers keep sealing unchanged content; whatever they get is either valid or a refusal.
            for _ in 0..<5 {
                do {
                    _ = try encryptor.sealChunk(index: worker, fileBytes: contents[worker])
                    counters.lock(); sealedAfter += 1; counters.unlock()
                } catch {
                    counters.lock(); refused += 1; counters.unlock()
                }
            }
        }
        XCTAssertEqual(conflicts, 1)
        XCTAssertTrue(encryptor.isCancelled)
        XCTAssertEqual(refused + sealedAfter, 8 * 5)
        // After the dust settles nothing seals any more.
        for index in 0..<8 {
            XCTAssertThrowsError(try encryptor.sealChunk(index: index, fileBytes: contents[index]), "chunk \(index)") {
                XCTAssertEqual($0 as? FileV2Error, .contentChanged)
            }
        }
    }

    // MARK: Streaming: the source

    func testEncryptFileRefusesASourceOfAnotherSize() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let plain = directory.appendingPathComponent("plain")
        try Support.writePlaintextFile(size: 3000, to: plain)
        let destination = directory.appendingPathComponent("blob")
        for declared in [UInt64(2999), 3001] {
            let encryptor = try FileV2Encryptor.makeNew(plaintextSize: declared)
            XCTAssertThrowsError(try encryptor.encryptFile(from: plain, to: destination), "declared \(declared)") {
                XCTAssertEqual($0 as? FileV2Error, .contentChanged)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(encryptor.isCancelled)
        }
    }

    func testSealChunkFromAHandleThatShrankIsContentChanged() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let plain = directory.appendingPathComponent("plain")
        try Support.writePlaintextFile(size: UInt64(chunk + 100), to: plain)
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: UInt64(chunk + 4000))   // declares more than there is
        let handle = try FileHandle(forReadingFrom: plain)
        defer { try? handle.close() }
        XCTAssertNoThrow(try encryptor.sealChunk(index: 0, from: handle))
        XCTAssertThrowsError(try encryptor.sealChunk(index: 1, from: handle)) {
            XCTAssertEqual($0 as? FileV2Error, .contentChanged)
        }
    }

    func testEncryptFileNeverOverwrites() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let plain = directory.appendingPathComponent("plain")
        try Support.writePlaintextFile(size: 100, to: plain)
        let existing = directory.appendingPathComponent("existing")
        try Data("keep me".utf8).write(to: existing)
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: 100)
        XCTAssertThrowsError(try encryptor.encryptFile(from: plain, to: existing)) {
            XCTAssertEqual($0 as? FileV2Error, .invalidArgument("destination exists"))
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8))
        XCTAssertFalse(encryptor.isCancelled, "a refused destination is not a conflict")
    }

    // MARK: Streaming: the receiver

    func testRoundTripWithFreshRandomKeysAcrossBoundarySizes() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let sizes: [UInt64] = [1, 2, 255, 256, 4095, 65_536, UInt64(chunk) - 1, UInt64(chunk), UInt64(chunk) + 1,
                               UInt64(2 * chunk) - 1, UInt64(2 * chunk) + 1]
        for size in sizes {
            let plain = directory.appendingPathComponent("p-\(size)")
            let blob = directory.appendingPathComponent("b-\(size)")
            let out = directory.appendingPathComponent("o-\(size)")
            try Support.writePlaintextFile(size: size, to: plain)
            let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
            try sender.encryptFile(from: plain, to: blob)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: blob.path)[.size] as? UInt64,
                           sender.blobLength, "size \(size)")
            let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                               header: sender.header.bytes, size: size)
            try receiver.decryptFile(from: blob, to: out)
            XCTAssertEqual(try Data(contentsOf: out), try Data(contentsOf: plain), "size \(size)")
            XCTAssertTrue(receiver.isComplete)
        }
    }

    /// The sealed chunks of a blob, in order.
    private func sealedChunks(of blob: Data, sender: FileV2Encryptor) throws -> [Data] {
        try (0..<sender.totalChunks).map { index in
            let offset = Int(try XCTUnwrap(sender.blobOffset(ofChunk: index)))
            return blob.subdata(in: offset..<offset + sender.sealedChunkLength(index))
        }
    }

    /// Chunks in any order, a duplicate, an index past the end, a tampered chunk and an early finalize.
    func testReceiverCountsOnTheMapOfVerifiedChunks() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(3 * chunk + 5000)
        let plain = directory.appendingPathComponent("plain")
        let blobURL = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        try sender.encryptFile(from: plain, to: blobURL)
        let chunks = try sealedChunks(of: try Data(contentsOf: blobURL), sender: sender)
        func sealed(_ index: Int) -> Data { chunks[index] }

        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: size)
        XCTAssertEqual(receiver.totalChunks, 4)
        let outURL = directory.appendingPathComponent("out")
        XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: nil))
        let output = try FileHandle(forUpdating: outURL)
        defer { try? output.close() }

        XCTAssertEqual(try receiver.receive(index: 3, sealed: sealed(3), writingTo: output), .written)
        XCTAssertTrue(receiver.isVerified(chunk: 3))
        XCTAssertEqual(receiver.verifiedCount, 1)
        // The same chunk five more times: ignored, still one verified chunk. Completion is the map, not the messages.
        for _ in 0..<5 {
            XCTAssertEqual(try receiver.receive(index: 3, sealed: sealed(3), writingTo: output), .alreadyVerified)
        }
        XCTAssertEqual(receiver.verifiedCount, 1)
        // An already verified chunk is ignored, not even opened: whatever bytes arrive for it change nothing.
        XCTAssertEqual(try receiver.receive(index: 3, sealed: Data(count: 5), writingTo: output), .alreadyVerified)
        XCTAssertEqual(receiver.verifiedCount, 1)

        // An index past the end is dropped without an error; so is a negative one.
        XCTAssertEqual(try receiver.receive(index: 4, sealed: Data(count: 10), writingTo: output), .discarded)
        XCTAssertEqual(try receiver.receive(index: Int.max, sealed: Data(), writingTo: output), .discarded)
        XCTAssertEqual(try receiver.receive(index: -1, sealed: Data(), writingTo: output), .discarded)
        XCTAssertEqual(receiver.verifiedCount, 1)

        // A tampered chunk and a chunk of the wrong length fail, mark nothing and can be asked for again.
        var tampered = sealed(1)
        tampered[100] ^= 0x01
        XCTAssertThrowsError(try receiver.receive(index: 1, sealed: tampered, writingTo: output)) {
            XCTAssertEqual($0 as? FileV2Error, .chunkAuth)
        }
        XCTAssertThrowsError(try receiver.receive(index: 1, sealed: sealed(1).dropLast(), writingTo: output)) {
            XCTAssertEqual($0 as? FileV2Error, .chunkAuth)
        }
        XCTAssertThrowsError(try receiver.receive(index: 1, sealed: sealed(2), writingTo: output)) {
            XCTAssertEqual($0 as? FileV2Error, .chunkAuth, "a chunk at the wrong index does not open")
        }
        XCTAssertFalse(receiver.isVerified(chunk: 1))
        XCTAssertEqual(receiver.verifiedCount, 1)
        XCTAssertEqual(receiver.missingChunks, [0, 1, 2])

        // Not complete: finalize refuses.
        XCTAssertThrowsError(try receiver.finalize(output: output)) {
            XCTAssertEqual($0 as? FileV2Error, .sizeMismatch)
        }

        // The rest, in a different order, with the retry of chunk 1 from "another source".
        XCTAssertEqual(try receiver.receive(index: 2, sealed: sealed(2), writingTo: output), .written)
        XCTAssertEqual(try receiver.receive(index: 0, sealed: sealed(0), writingTo: output), .written)
        XCTAssertEqual(try receiver.receive(index: 1, sealed: sealed(1), writingTo: output), .written)
        XCTAssertTrue(receiver.isComplete)
        XCTAssertEqual(receiver.missingChunks, [])
        try receiver.finalize(output: output)
        XCTAssertEqual(try Data(contentsOf: outURL), try Data(contentsOf: plain))
    }

    /// Chunks delivered from several threads at once (parallel parts, several sources): every chunk offered four times
    /// concurrently ends with exactly one `written` and three `alreadyVerified`, the map is exact, and the output is the file.
    func testConcurrentDeliveryOfTheSameChunksFromManyThreads() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(11 * chunk + 777)
        let plain = directory.appendingPathComponent("plain")
        let blobURL = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        try sender.encryptFile(from: plain, to: blobURL)
        let chunks = try sealedChunks(of: try Data(contentsOf: blobURL), sender: sender)

        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: size)
        let outURL = directory.appendingPathComponent("out")
        XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: nil))
        let output = try FileHandle(forUpdating: outURL)
        defer { try? output.close() }

        let total = receiver.totalChunks
        let copies = 4
        var outcomes: [FileV2Decryptor.ChunkOutcome] = []
        var errors = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: total * copies) { iteration in
            // Every chunk is offered by `copies` workers, interleaved by the scheduler.
            let index = iteration % total
            do {
                let outcome = try receiver.receive(index: index, sealed: chunks[index], writingTo: output)
                lock.lock(); outcomes.append(outcome); lock.unlock()
            } catch {
                lock.lock(); errors += 1; lock.unlock()
            }
        }
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(outcomes.count, total * copies)
        XCTAssertEqual(outcomes.filter { $0 == .written }.count, total, "exactly one writer per chunk")
        XCTAssertEqual(outcomes.filter { $0 == .alreadyVerified }.count, total * (copies - 1))
        XCTAssertTrue(receiver.isComplete)
        XCTAssertEqual(receiver.verifiedCount, total)
        XCTAssertEqual(receiver.missingChunks, [])
        try receiver.finalize(output: output)
        XCTAssertEqual(try Data(contentsOf: outURL), try Data(contentsOf: plain))
    }

    func testResumeFromAPersistedMapOfVerifiedChunks() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(3 * chunk + 5000)
        let plain = directory.appendingPathComponent("plain")
        let blobURL = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        try sender.encryptFile(from: plain, to: blobURL)
        let chunks = try sealedChunks(of: try Data(contentsOf: blobURL), sender: sender)
        func sealed(_ index: Int) -> Data { chunks[index] }
        let outURL = directory.appendingPathComponent("out")
        XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: nil))

        // First session: chunks 0 and 2, then the app goes away.
        let firstOutput = try FileHandle(forUpdating: outURL)
        let first = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                        header: sender.header.bytes, size: size)
        _ = try first.receive(index: 0, sealed: sealed(0), writingTo: firstOutput)
        _ = try first.receive(index: 2, sealed: sealed(2), writingTo: firstOutput)
        try firstOutput.close()
        let persisted = first.verifiedChunks
        XCTAssertEqual(persisted, [0, 2])

        // Second session: restored map, every chunk offered again, in any order and from any source.
        let secondOutput = try FileHandle(forUpdating: outURL)
        defer { try? secondOutput.close() }
        let second = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                         header: sender.header.bytes, size: size, verifiedChunks: persisted)
        XCTAssertEqual(second.missingChunks, [1, 3])
        // The output still holds the restored chunks: nothing is dropped.
        XCTAssertEqual(try second.dropVerifiedChunksMissing(in: secondOutput), [])
        for index in [3, 2, 1, 0] {
            let outcome = try second.receive(index: index, sealed: sealed(index), writingTo: secondOutput)
            XCTAssertEqual(outcome, persisted.contains(index) ? .alreadyVerified : .written, "chunk \(index)")
        }
        try second.finalize(output: secondOutput)
        XCTAssertEqual(try Data(contentsOf: outURL), try Data(contentsOf: plain))

        XCTAssertThrowsError(try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                                 header: sender.header.bytes, size: size, verifiedChunks: [9]))
        XCTAssertThrowsError(try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                                 header: sender.header.bytes, size: size, verifiedChunks: [-1]))
    }

    /// A restored map is the receiver's own local state and is trusted as such, but not blindly: a chunk whose bytes are
    /// no longer in the output file is unmarked (`dropVerifiedChunksMissing`), and any chunk the pipeline distrusts can be
    /// unmarked by hand (`markUnverified`), so it is requested and verified again.
    func testARestoredMapIsCheckedAgainstTheOutputFile() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(3 * chunk + 5000)
        let plain = directory.appendingPathComponent("plain")
        let blobURL = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        try sender.encryptFile(from: plain, to: blobURL)
        let chunks = try sealedChunks(of: try Data(contentsOf: blobURL), sender: sender)
        let outURL = directory.appendingPathComponent("out")
        XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: nil))

        let firstOutput = try FileHandle(forUpdating: outURL)
        let first = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                        header: sender.header.bytes, size: size)
        for index in [0, 2, 3] { _ = try first.receive(index: index, sealed: chunks[index], writingTo: firstOutput) }
        try firstOutput.close()
        XCTAssertEqual(first.verifiedChunks, [0, 2, 3])

        // The output file lost its tail (a crash, a partial restore): it now holds a little more than chunk 0.
        let handle = try FileHandle(forUpdating: outURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(chunk) + 10)
        let second = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                         header: sender.header.bytes, size: size, verifiedChunks: first.verifiedChunks)
        XCTAssertEqual(try second.dropVerifiedChunksMissing(in: handle), [2, 3])
        XCTAssertEqual(second.verifiedChunks, [0])
        XCTAssertEqual(second.missingChunks, [1, 2, 3])
        XCTAssertEqual(try second.dropVerifiedChunksMissing(in: handle), [], "idempotent")

        // By hand.
        XCTAssertTrue(second.markUnverified(chunk: 0))
        XCTAssertFalse(second.markUnverified(chunk: 0), "already unmarked")
        XCTAssertFalse(second.markUnverified(chunk: 1), "never verified")
        XCTAssertFalse(second.markUnverified(chunk: -1))
        XCTAssertFalse(second.markUnverified(chunk: 99))
        XCTAssertEqual(second.verifiedCount, 0)
        XCTAssertEqual(second.missingChunks, [0, 1, 2, 3])
        // And everything can be delivered again and the file comes out right.
        for index in [3, 1, 0, 2] { _ = try second.receive(index: index, sealed: chunks[index], writingTo: handle) }
        try second.finalize(output: handle)
        XCTAssertEqual(try Data(contentsOf: outURL), try Data(contentsOf: plain))
    }

    /// Section 12.9, incomplete transfer: a stream that ends with chunks missing is `size_mismatch`, at a chunk
    /// boundary or inside a chunk, and never `bad_padding` (the padding check stays last, on a complete stream only).
    func testAnIncompleteStreamIsSizeMismatchAndNeverBadPadding() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(2 * chunk + 100)        // a padded last chunk
        let plain = directory.appendingPathComponent("plain")
        let blobURL = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        try sender.encryptFile(from: plain, to: blobURL)
        let chunks = try sealedChunks(of: try Data(contentsOf: blobURL), sender: sender)
        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: size)
        let outURL = directory.appendingPathComponent("out")
        XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: nil))
        let output = try FileHandle(forUpdating: outURL)
        defer { try? output.close() }

        // Nothing received, then the first chunk only: the source ended early (at a chunk boundary).
        XCTAssertThrowsError(try receiver.endOfStream()) { XCTAssertEqual($0 as? FileV2Error, .sizeMismatch) }
        XCTAssertEqual(try receiver.receive(index: 0, sealed: chunks[0], writingTo: output), .written)
        XCTAssertThrowsError(try receiver.endOfStream()) { XCTAssertEqual($0 as? FileV2Error, .sizeMismatch) }
        XCTAssertThrowsError(try receiver.finalize(output: output)) { XCTAssertEqual($0 as? FileV2Error, .sizeMismatch) }
        // The last chunk ends inside its tag: those bytes are not a chunk, the caller does not deliver them, and the
        // answer is the same.
        XCTAssertEqual(try receiver.receive(index: 1, sealed: chunks[1], writingTo: output), .written)
        XCTAssertThrowsError(try receiver.endOfStream()) { XCTAssertEqual($0 as? FileV2Error, .sizeMismatch) }
        XCTAssertEqual(receiver.missingChunks, [2])
        // Complete: the end of the stream is fine, and the padding is checked by finalize.
        XCTAssertEqual(try receiver.receive(index: 2, sealed: chunks[2], writingTo: output), .written)
        XCTAssertNoThrow(try receiver.endOfStream())
        XCTAssertNoThrow(try receiver.finalize(output: output))
        receiver.close()
        XCTAssertThrowsError(try receiver.endOfStream()) { XCTAssertEqual($0 as? FileV2Error, .closed) }
    }

    func testDecryptFileRefusesAUsedDecryptorAndAnExistingDestination() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let plain = directory.appendingPathComponent("plain")
        let blob = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: 500, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: 500)
        try sender.encryptFile(from: plain, to: blob)
        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: 500)
        let out = directory.appendingPathComponent("out")
        try receiver.decryptFile(from: blob, to: out)
        // Used: nothing may be skipped as "already verified" into a new, empty destination.
        XCTAssertThrowsError(try receiver.decryptFile(from: blob, to: directory.appendingPathComponent("out2"))) {
            XCTAssertEqual($0 as? FileV2Error, .invalidArgument("decryptFile needs a fresh decryptor"))
        }
        let fresh = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                        header: sender.header.bytes, size: 500)
        XCTAssertThrowsError(try fresh.decryptFile(from: blob, to: out)) {
            XCTAssertEqual($0 as? FileV2Error, .invalidArgument("destination exists"))
        }
    }

    /// A failed `decryptFile` removes the destination AND empties the map of verified chunks: the chunks it claimed are
    /// gone with the file, so a later delivery into another output must not skip them as "already verified". The
    /// decryptor stays open and fresh: the pipeline may try another source.
    func testAFailedDecryptFileLeavesAFreshDecryptor() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(3 * chunk + 5000)
        let plain = directory.appendingPathComponent("plain")
        let blob = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        try sender.encryptFile(from: plain, to: blob)
        var corrupted = try Data(contentsOf: blob)
        corrupted[Int(try XCTUnwrap(sender.blobOffset(ofChunk: 2))) + 1000] ^= 0x01     // chunk 2 fails after 0 and 1 pass
        let corruptedURL = directory.appendingPathComponent("corrupted")
        try corrupted.write(to: corruptedURL)

        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: size)
        let failedOutput = directory.appendingPathComponent("failed")
        XCTAssertThrowsError(try receiver.decryptFile(from: corruptedURL, to: failedOutput)) {
            XCTAssertEqual($0 as? FileV2Error, .chunkAuth)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedOutput.path), "no partial plaintext stays on disk")
        XCTAssertEqual(receiver.verifiedCount, 0, "the chunks of the removed file are not claimed any more")
        XCTAssertEqual(receiver.missingChunks, [0, 1, 2, 3])
        // Fresh and open: the good blob decrypts completely into another output.
        let output = directory.appendingPathComponent("output")
        try receiver.decryptFile(from: blob, to: output)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: plain))
    }

    func testBlobShorterThanItsHeaderIsAHeaderMismatch() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: 10)
        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: 10)
        let blob = directory.appendingPathComponent("short")
        try Data(count: 63).write(to: blob)
        XCTAssertThrowsError(try receiver.decryptFile(from: blob, to: directory.appendingPathComponent("out"))) {
            XCTAssertEqual($0 as? FileV2Error, .headerMismatch)
        }
        try Data().write(to: blob, options: .atomic)
        XCTAssertThrowsError(try receiver.decryptFile(from: blob, to: directory.appendingPathComponent("out"))) {
            XCTAssertEqual($0 as? FileV2Error, .headerMismatch)
        }
    }

    func testVerifySourceHeader() throws {
        let sender = try FileV2Encryptor.makeNew(plaintextSize: 10)
        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: 10)
        XCTAssertNoThrow(try receiver.verifySourceHeader(sender.header.bytes))
        var other = sender.header.bytes
        other[10] ^= 1
        XCTAssertThrowsError(try receiver.verifySourceHeader(other)) { XCTAssertEqual($0 as? FileV2Error, .headerMismatch) }
        XCTAssertThrowsError(try receiver.verifySourceHeader(Data())) { XCTAssertEqual($0 as? FileV2Error, .headerMismatch) }
        XCTAssertThrowsError(try receiver.verifySourceHeader(sender.header.bytes + Data([0]))) {
            XCTAssertEqual($0 as? FileV2Error, .headerMismatch)
        }
    }

    // MARK: Memory

    /// Peak memory must not depend on the file size: a 96 MiB file is encrypted and decrypted one chunk at a time.
    /// Loading it whole (or its blob) would add 96 MiB or more; the allowance is well below that.
    func testPeakMemoryDoesNotDependOnTheFileSize() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(96 * chunk)
        let plain = directory.appendingPathComponent("plain")
        let blob = directory.appendingPathComponent("blob")
        let out = directory.appendingPathComponent("out")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: size)

        // Warm the allocator and CryptoKit on the first chunks, then measure.
        let handle = try FileHandle(forReadingFrom: plain)
        _ = try sender.sealChunk(index: 0, from: handle)
        _ = try sender.sealChunk(index: 1, from: handle)
        try handle.close()
        guard let baseline = Support.residentMemoryBytes() else { return XCTFail("cannot read the resident memory") }
        let allowance = UInt64(40 * chunk)    // 40 MiB: far above one chunk, far below the 96 MiB file

        var peakEncrypt = baseline
        try sender.encryptFile(from: plain, to: blob) { _ in
            if let now = Support.residentMemoryBytes() { peakEncrypt = max(peakEncrypt, now) }
        }
        var peakDecrypt = baseline
        try receiver.decryptFile(from: blob, to: out) { _ in
            if let now = Support.residentMemoryBytes() { peakDecrypt = max(peakDecrypt, now) }
        }
        XCTAssertLessThan(peakEncrypt - baseline, allowance, "encryption memory grew with the file")
        XCTAssertLessThan(peakDecrypt - baseline, allowance, "decryption memory grew with the file")
        XCTAssertEqual(try Support.sha256Hex(ofFile: out), try Support.sha256Hex(ofFile: plain))
    }

    func testProgressCountsEveryChunkOnce() throws {
        let directory = try Support.makeTempDirectory(for: self)
        let size = UInt64(2 * chunk + 1)
        let plain = directory.appendingPathComponent("plain")
        let blob = directory.appendingPathComponent("blob")
        try Support.writePlaintextFile(size: size, to: plain)
        let sender = try FileV2Encryptor.makeNew(plaintextSize: size)
        var seen: [Int] = []
        try sender.encryptFile(from: plain, to: blob) { seen.append($0) }
        XCTAssertEqual(seen, Array(1...sender.totalChunks))
        let receiver = try FileV2Decryptor(fileID: sender.fileID, fileKey: sender.fileKey,
                                           header: sender.header.bytes, size: size)
        var received: [Int] = []
        try receiver.decryptFile(from: blob, to: directory.appendingPathComponent("out")) { received.append($0) }
        XCTAssertEqual(received, Array(1...receiver.totalChunks))
    }

    // MARK: Errors

    func testErrorCodesAreTheWireCodes() {
        XCTAssertEqual(FileV2Error.badDescriptor.code, "bad_descriptor")
        XCTAssertEqual(FileV2Error.badHeader.code, "bad_header")
        XCTAssertEqual(FileV2Error.commitMismatch.code, "commit_mismatch")
        XCTAssertEqual(FileV2Error.headerMismatch.code, "header_mismatch")
        XCTAssertEqual(FileV2Error.chunkAuth.code, "chunk_auth")
        XCTAssertEqual(FileV2Error.badPadding.code, "bad_padding")
        XCTAssertEqual(FileV2Error.sizeMismatch.code, "size_mismatch")
        XCTAssertEqual(FileV2Error.cancelled.code, "cancelled")
        XCTAssertEqual(FileV2Error.unsupportedVersion.code, "unsupported_version")
        XCTAssertEqual(FileV2Error.contentChanged.code, "cancelled")
        XCTAssertEqual(FileV2Error.closed.code, "closed")
        XCTAssertEqual(FileV2Error.invalidArgument("x").code, "invalid_argument")
    }
}

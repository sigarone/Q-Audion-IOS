import XCTest
@testable import QAudionEngine

/// The send state store (step 2b): the journal format, the file store and its durability, and what it must survive.
final class FileV2SendStoreTests: XCTestCase {

    private func makeStore(durability: FileV2Durability = FileV2SystemDurability()) throws -> (FileV2FileSendStore, URL) {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self).appendingPathComponent("send", isDirectory: true)
        return (try FileV2FileSendStore(directory: directory, durability: durability), directory)
    }

    private func journalURL(_ directory: URL, _ id: String = SendStoreFixtures.transferID) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("qsj")
    }

    // MARK: Format

    func testCRC32MatchesTheStandardCheckValue() {
        // The check value of CRC-32/IEEE for the ASCII digits 1 to 9.
        XCTAssertEqual(FileV2CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(FileV2CRC32.checksum([UInt8]()), 0)
    }

    func testEveryEventRoundTripsThroughTheJournal() throws {
        let (store, _) = try makeStore()
        let begin = SendStoreFixtures.begin()
        try store.begin(begin)
        try store.append(.object(SendStoreFixtures.objectRecord()), to: begin.transferID)
        try store.append(.token(SendStoreFixtures.tokenRecord()), to: begin.transferID)
        try store.append(SendStoreFixtures.tags(part: 0, chunks: 0..<8), to: begin.transferID)
        try store.append(SendStoreFixtures.tags(part: 1, chunks: 8..<11), to: begin.transferID)
        try store.append(.partDone(0), to: begin.transferID)
        try store.append(.phase(.completed), to: begin.transferID)

        let recovered = try store.load(begin.transferID)
        XCTAssertEqual(recovered.begin, begin)
        XCTAssertEqual(recovered.object, SendStoreFixtures.objectRecord())
        XCTAssertEqual(recovered.token, SendStoreFixtures.tokenRecord())
        XCTAssertEqual(recovered.tags.count, 11)
        for index in 0..<11 { XCTAssertEqual(recovered.tags[index], SendStoreFixtures.tag(UInt8(index))) }
        XCTAssertEqual(recovered.confirmedParts, [0])
        XCTAssertEqual(recovered.phase, .completed)
        XCTAssertEqual(recovered.droppedTailBytes, 0)
        XCTAssertFalse(recovered.hasConflictingTags)
        XCTAssertFalse(recovered.descriptorMayHaveBeenSent)
    }

    func testANewObjectForgetsTheConfirmedPartsAndReopensACompletedTransfer() throws {
        let (store, _) = try makeStore()
        let id = SendStoreFixtures.transferID
        try store.begin(SendStoreFixtures.begin())
        try store.append(.object(SendStoreFixtures.objectRecord()), to: id)
        try store.append(.partDone(0), to: id)
        try store.append(.partDone(1), to: id)
        try store.append(.phase(.completed), to: id)
        try store.append(.phase(.announcing), to: id)

        var recovered = try store.load(id)
        XCTAssertEqual(recovered.phase, .announcing)
        XCTAssertTrue(recovered.descriptorMayHaveBeenSent)
        XCTAssertEqual(recovered.confirmedParts, [0, 1])

        // The object was deleted by the server and made again: nothing is confirmed, the transfer uploads again, and the fact that a
        // descriptor MAY have gone out stays.
        try store.append(.object(SendStoreFixtures.objectRecord(obj: "ffffffff-0000-4000-8000-0123456789ab")), to: id)
        recovered = try store.load(id)
        XCTAssertEqual(recovered.confirmedParts, [])
        XCTAssertEqual(recovered.phase, .uploading)
        XCTAssertTrue(recovered.descriptorMayHaveBeenSent)
        XCTAssertEqual(recovered.object?.obj, "ffffffff-0000-4000-8000-0123456789ab")
    }

    func testTwoRecordsThatDisagreeAboutATagAreFlagged() throws {
        let (store, _) = try makeStore()
        let id = SendStoreFixtures.transferID
        try store.begin(SendStoreFixtures.begin())
        try store.append(.tags(part: 0, entries: [FileV2SendTag(index: 3, tag: SendStoreFixtures.tag(1))]), to: id)
        try store.append(.tags(part: 0, entries: [FileV2SendTag(index: 3, tag: SendStoreFixtures.tag(1))]), to: id)
        XCTAssertFalse(try store.load(id).hasConflictingTags, "the same tag twice is not a conflict")
        try store.append(.tags(part: 0, entries: [FileV2SendTag(index: 3, tag: SendStoreFixtures.tag(2))]), to: id)
        XCTAssertTrue(try store.load(id).hasConflictingTags)
    }

    // MARK: begin is atomic

    func testBeginRefusesAnIdThatExistsAndLeavesNoTemporaryFile() throws {
        let (store, directory) = try makeStore()
        try store.begin(SendStoreFixtures.begin())
        XCTAssertThrowsError(try store.begin(SendStoreFixtures.begin())) {
            XCTAssertEqual($0 as? FileV2SendStoreError, .alreadyExists)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [SendStoreFixtures.transferID + ".qsj"])
    }

    func testAJournalThatNeverReachedItsRenameIsNotATransfer() throws {
        let (store, directory) = try makeStore()
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("22222222-0000-0000-0000-000000000000.tmp"))
        try store.begin(SendStoreFixtures.begin())
        XCTAssertEqual(try store.listTransferIDs(), [SendStoreFixtures.transferID])
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [SendStoreFixtures.transferID + ".qsj"], "the stray temporary file is removed")
    }

    func testLoadOfAnIdThatDoesNotExistIsNotFound() throws {
        let (store, _) = try makeStore()
        XCTAssertThrowsError(try store.load("0000")) { XCTAssertEqual($0 as? FileV2SendStoreError, .notFound) }
        XCTAssertNoThrow(try store.remove("0000"), "remove is idempotent")
    }

    func testIdsThatCouldBuildAPathAreRefused() throws {
        let (store, directory) = try makeStore()
        for bad in ["", "../escape", "a/b", "A-UPPER", "dot.dot", "ünï", String(repeating: "a", count: 65), "a\u{0}b", ".."] {
            var record = SendStoreFixtures.begin()
            record.transferID = bad
            XCTAssertThrowsError(try store.begin(record), "id \(bad.debugDescription)") {
                XCTAssertEqual($0 as? FileV2SendStoreError, .invalidIdentifier)
            }
            XCTAssertThrowsError(try store.append(.partDone(0), to: bad))
            XCTAssertThrowsError(try store.load(bad))
            XCTAssertThrowsError(try store.remove(bad))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(fileV2IsValidTransferID(SendStoreFixtures.transferID))
        XCTAssertTrue(fileV2IsValidTransferID(String(repeating: "a", count: 64)))
    }

    func testRemoveDeletesTheJournalAndIsIdempotent() throws {
        let (store, directory) = try makeStore()
        try store.begin(SendStoreFixtures.begin())
        try store.append(.partDone(0), to: SendStoreFixtures.transferID)
        try store.remove(SendStoreFixtures.transferID)
        try store.remove(SendStoreFixtures.transferID)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(try store.listTransferIDs(), [])
        XCTAssertThrowsError(try store.load(SendStoreFixtures.transferID))
    }

    // MARK: Durability

    func testEveryAppendIsFlushedBeforeItReturnsAndTheBeginFlushesTheDirectoryToo() throws {
        let log = SendEventLog()
        let durability = RecordingDurability(log: log)
        let (store, directory) = try makeStore(durability: durability)
        let setupFlushes = durability.directoryFlushCount

        try store.begin(SendStoreFixtures.begin())
        XCTAssertGreaterThanOrEqual(durability.fileFlushCount, 1, "the begin record is flushed")
        XCTAssertGreaterThan(durability.directoryFlushCount, setupFlushes, "and the rename is made durable")

        log.clear()
        for part in 0..<5 {
            try store.append(SendStoreFixtures.tags(part: part, chunks: (part * 8)..<(part * 8 + 8)), to: SendStoreFixtures.transferID)
        }
        let flushes = log.events.filter { $0.hasPrefix("fsync.file") }
        XCTAssertEqual(flushes.count, 5, "one flush per append")

        // At every flush the whole record is already in the file: the flush covers what was just written.
        let finalSize = try FileV2SendStoreTests.size(of: journalURL(directory))
        XCTAssertEqual(flushes.last, "fsync.file(size=\(finalSize))")
    }

    func testAFailingFlushFailsTheAppendAndTheNextOneReopensAndRescansTheJournal() throws {
        struct Failing: FileV2Durability {
            let failing: FileV2Locked<Bool>
            func flush(file handle: FileHandle) throws {
                if failing.withValue({ $0 }) { throw FileV2SendStoreError.io("sync") }
                try FileV2SystemDurability().flush(file: handle)
            }
            func flush(directory url: URL) throws {}
        }
        let failing = FileV2Locked(false)
        let (store, directory) = try makeStore(durability: Failing(failing: failing))
        let id = SendStoreFixtures.transferID
        try store.begin(SendStoreFixtures.begin())
        try store.append(.partDone(0), to: id)
        let good = try FileV2SendStoreTests.size(of: journalURL(directory))

        failing.withValue { $0 = true }
        XCTAssertThrowsError(try store.append(.partDone(1), to: id)) { XCTAssertEqual($0 as? FileV2SendStoreError, .io("sync")) }
        XCTAssertGreaterThan(try FileV2SendStoreTests.size(of: journalURL(directory)), good, "the failed record is on disk")

        // The record was written but never acknowledged: the caller treats it as failed, and the journal may hold it. That is harmless
        // (an extra tag only ever constrains a later seal), and the next append goes after it, with no torn tail between.
        failing.withValue { $0 = false }
        try store.append(.partDone(2), to: id)
        let recovered = try store.load(id)
        XCTAssertEqual(recovered.confirmedParts, [0, 1, 2])
        XCTAssertEqual(recovered.droppedTailBytes, 0)
    }

    // MARK: A truncated or corrupt tail

    /// A journal with a begin record and a few events, and the offset at which each record ends.
    private func writeSampleJournal(_ store: FileV2FileSendStore, directory: URL) throws -> [Int] {
        let id = SendStoreFixtures.transferID
        try store.begin(SendStoreFixtures.begin())
        var boundaries: [Int] = [try FileV2SendStoreTests.size(of: journalURL(directory))]
        let events: [FileV2SendJournalEvent] = [
            .object(SendStoreFixtures.objectRecord()), .token(SendStoreFixtures.tokenRecord()),
            SendStoreFixtures.tags(part: 0, chunks: 0..<8), .partDone(0), SendStoreFixtures.tags(part: 1, chunks: 8..<16),
            .phase(.completed)
        ]
        for event in events {
            try store.append(event, to: id)
            boundaries.append(try FileV2SendStoreTests.size(of: journalURL(directory)))
        }
        return boundaries
    }

    func testAJournalCutAtAnyByteRecoversEverythingBeforeTheCutAndNothingAfter() throws {
        let (store, directory) = try makeStore()
        let boundaries = try writeSampleJournal(store, directory: directory)
        let full = [UInt8](try Data(contentsOf: journalURL(directory)))
        let id = SendStoreFixtures.transferID
        let beginEnd = boundaries[0]
        let (trial, trialDirectory) = try makeStore()      // nothing is appended here, so one store can read every cut

        for cut in 0...full.count {
            try Data(full[0..<cut]).write(to: journalURL(trialDirectory))
            if cut < beginEnd {
                XCTAssertThrowsError(try trial.load(id), "cut at \(cut): no begin record, no transfer") {
                    guard case .corrupt = $0 as? FileV2SendStoreError else { return XCTFail("cut at \(cut): \($0)") }
                }
                continue
            }
            let lastBoundary = boundaries.last(where: { $0 <= cut }) ?? beginEnd
            let recovered = try trial.load(id)
            XCTAssertEqual(recovered.droppedTailBytes, cut - lastBoundary, "cut at \(cut)")
            let expectedRecords = boundaries.firstIndex(of: lastBoundary) ?? 0
            XCTAssertEqual(recovered.object != nil, expectedRecords >= 1, "cut at \(cut)")
            XCTAssertEqual(recovered.token != nil, expectedRecords >= 2, "cut at \(cut)")
            XCTAssertEqual(recovered.tags.count, (expectedRecords >= 3 ? 8 : 0) + (expectedRecords >= 5 ? 8 : 0), "cut at \(cut)")
            XCTAssertEqual(recovered.confirmedParts.count, expectedRecords >= 4 ? 1 : 0, "cut at \(cut)")
            XCTAssertEqual(recovered.phase, expectedRecords >= 6 ? .completed : .uploading, "cut at \(cut)")
        }
    }

    func testTheNextAppendAfterATornTailCutsItOffInsteadOfWritingAfterIt() throws {
        let (store, directory) = try makeStore()
        let boundaries = try writeSampleJournal(store, directory: directory)
        let full = [UInt8](try Data(contentsOf: journalURL(directory)))
        let id = SendStoreFixtures.transferID
        // Tear the tags record of part 1 (the longest, 174 bytes) in the middle: what is left of it is longer than the record the next append
        // writes, so an append that did not cut the garbage off first would leave some of it after the new record.
        let cut = (boundaries[boundaries.count - 3] + boundaries[boundaries.count - 2]) / 2
        XCTAssertGreaterThan(cut - boundaries[boundaries.count - 3], 13, "more garbage than the 13 bytes of the record appended next")

        let (reopened, reopenedDirectory) = try makeStore()
        try Data(full[0..<cut]).write(to: journalURL(reopenedDirectory))
        XCTAssertEqual(try reopened.load(id).phase, .uploading, "the torn record, and the phase record after it, are ignored")
        XCTAssertEqual(try reopened.load(id).tags.count, 8, "only the tags of part 0 survive")
        try reopened.append(.partDone(7), to: id)
        let recovered = try reopened.load(id)
        XCTAssertEqual(recovered.droppedTailBytes, 0, "the new record follows the last good one, not the garbage")
        XCTAssertTrue(recovered.confirmedParts.contains(7))
        XCTAssertEqual(recovered.tags.count, 8)

        // A fresh store instance (a restart) reads the same thing.
        let restarted = try FileV2FileSendStore(directory: reopenedDirectory)
        XCTAssertEqual(try restarted.load(id), recovered)
    }

    func testAFlippedBitInTheLastRecordIsATailAndEarlierRecordsSurvive() throws {
        let (store, directory) = try makeStore()
        let boundaries = try writeSampleJournal(store, directory: directory)
        var bytes = [UInt8](try Data(contentsOf: journalURL(directory)))
        let lastRecordStart = boundaries[boundaries.count - 2]
        for offset in lastRecordStart..<bytes.count {
            var flipped = bytes
            flipped[offset] ^= 0x10
            let (trial, trialDirectory) = try makeStore()
            try Data(flipped).write(to: journalURL(trialDirectory))
            let recovered = try trial.load(SendStoreFixtures.transferID)
            XCTAssertEqual(recovered.phase, .uploading, "flip at \(offset): the damaged phase record is not applied")
            XCTAssertEqual(recovered.droppedTailBytes, bytes.count - lastRecordStart, "flip at \(offset)")
            XCTAssertEqual(recovered.tags.count, 16)
        }
        bytes.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
        try Data(bytes).write(to: journalURL(directory))
        let appended = try FileV2FileSendStore(directory: directory).load(SendStoreFixtures.transferID)
        XCTAssertEqual(appended.phase, .completed, "garbage after the last record is a tail: the records before it all apply")
        XCTAssertEqual(appended.droppedTailBytes, 13)
    }

    func testAnAbsurdLengthNeverSizesAnAllocationAndEndsTheScan() throws {
        let (store, directory) = try makeStore()
        _ = try writeSampleJournal(store, directory: directory)
        var bytes = [UInt8](try Data(contentsOf: journalURL(directory)))
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0x04] + [UInt8](repeating: 0, count: 20))
        try Data(bytes).write(to: journalURL(directory))
        let recovered = try FileV2FileSendStore(directory: directory).load(SendStoreFixtures.transferID)
        XCTAssertEqual(recovered.phase, .completed)
        XCTAssertEqual(recovered.droppedTailBytes, 25)
    }

    func testAFileThatIsNotAJournalOrHasNoBeginRecordIsCorrupt() throws {
        let (store, directory) = try makeStore()
        let id = SendStoreFixtures.transferID
        for content in [[UInt8](), Array("not a journal at all".utf8), FileV2JournalFormat.magic] {
            try Data(content).write(to: journalURL(directory))
            XCTAssertThrowsError(try store.load(id)) {
                guard case .corrupt = $0 as? FileV2SendStoreError else { return XCTFail("\($0)") }
            }
        }
        // A well-formed record that is not a begin record first.
        var bytes = FileV2JournalFormat.magic
        bytes.append(contentsOf: try FileV2JournalFormat.encode(.partDone(1)))
        try Data(bytes).write(to: journalURL(directory))
        XCTAssertThrowsError(try store.load(id)) {
            XCTAssertEqual($0 as? FileV2SendStoreError, .corrupt("begin"))
        }
    }

    func testARecordWithAValidChecksumAndAnUndecodablePayloadIsCorruptNotATail() throws {
        let (store, directory) = try makeStore()
        _ = try writeSampleJournal(store, directory: directory)
        var bytes = [UInt8](try Data(contentsOf: journalURL(directory)))
        // A tags record whose declared count does not match its length, with a correct checksum.
        var body: [UInt8] = [FileV2JournalFormat.RecordType.tags.rawValue]
        body += [0, 0, 0, 0, 5]            // part 0, count 5, but no entries follow
        var frame = FileV2Crypto.bigEndian(UInt32(5))
        frame += body
        frame += FileV2Crypto.bigEndian(FileV2CRC32.checksum(body))
        bytes += frame
        try Data(bytes).write(to: journalURL(directory))
        XCTAssertThrowsError(try FileV2FileSendStore(directory: directory).load(SendStoreFixtures.transferID)) {
            XCTAssertEqual($0 as? FileV2SendStoreError, .corrupt("tags"))
        }
    }

    // MARK: Concurrency

    func testParallelAppendsAreAllDurableAndNoneIsTorn() throws {
        let (store, _) = try makeStore(durability: NoopDurability())
        let id = SendStoreFixtures.transferID
        try store.begin(SendStoreFixtures.begin())
        let group = DispatchGroup()
        for worker in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for part in 0..<40 {
                    let index = worker * 40 + part
                    try? store.append(.tags(part: index, entries: [FileV2SendTag(index: index, tag: SendStoreFixtures.tag(UInt8(index & 0xFF)))]), to: id)
                }
                group.leave()
            }
        }
        group.wait()
        let recovered = try store.load(id)
        XCTAssertEqual(recovered.tags.count, 320)
        XCTAssertEqual(recovered.droppedTailBytes, 0)
        XCTAssertFalse(recovered.hasConflictingTags)
    }

    // MARK: What the files hold, and what they say about themselves

    func testTheDirectoryAndTheJournalAreExcludedFromBackup() throws {
        #if canImport(Darwin)
        let (store, directory) = try makeStore()
        try store.begin(SendStoreFixtures.begin())
        for url in [directory, journalURL(directory)] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, "\(url.lastPathComponent) is excluded from backups")
        }
        #else
        throw XCTSkip("backup exclusion is an Apple platform attribute")
        #endif
    }

    func testTheJournalHoldsTheBlobsAndNotAnythingElseThatIsSecret() throws {
        let (store, directory) = try makeStore()
        let blob = Data(repeating: 0x5C, count: 16)
        var record = SendStoreFixtures.begin(wrappedKey: blob)
        record.metadata.name = "a-file.txt"
        try store.begin(record)
        let text = try FileV2SendStoreTests.rawText(journalURL(directory))
        XCTAssertTrue(text.contains(blob.base64EncodedString()), "the wrapped blob is what is stored")
        XCTAssertFalse(text.contains("\"k\""), "there is no key member")
        XCTAssertFalse(text.contains("\"tok\""), "and no token member")
    }

    func testNoTypeOfTheStorePrintsAnIdAKeyATagAPathOrAName() throws {
        let begin = SendStoreFixtures.begin(locator: "/private/var/mobile/Containers/Data/secret-folder/holiday.mov")
        var pieces: [Any] = [begin, begin.conversation, begin.source, begin.metadata, SendStoreFixtures.objectRecord(),
                             SendStoreFixtures.tokenRecord()]
        let recovered = try { () -> FileV2SendRecovered in
            let (store, _) = try makeStore()
            try store.begin(begin)
            try store.append(SendStoreFixtures.tags(part: 0, chunks: 0..<8), to: begin.transferID)
            return try store.load(begin.transferID)
        }()
        pieces.append(recovered)
        pieces.append(FileV2SendStoreError.corrupt("begin"))

        let forbidden: [String] = [
            begin.transferID, "11111111-2222-3333", "user-bob", "report.pdf", "holiday", "secret-folder", "/private",
            "0a1b2c3d-0000-4000", Data(repeating: 0xA1, count: 16).base64EncodedString(),
            Data(repeating: 0xB2, count: 64).base64EncodedString(), Data(repeating: 0xC3, count: 16).base64EncodedString(),
            Data(repeating: 0xD4, count: 16).base64EncodedString(), "application/pdf"
        ]
        for piece in pieces {
            let text = SendStoreFixtures.printed(piece)
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(type(of: piece)) prints \(word.prefix(12))...")
            }
        }
        // The first 8 characters of an id may be printed.
        XCTAssertTrue(SendStoreFixtures.printed(begin).contains("11111111"))
    }

    // MARK: Helpers

    private static func size(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func rawText(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

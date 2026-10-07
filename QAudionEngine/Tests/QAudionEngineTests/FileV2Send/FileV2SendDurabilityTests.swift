import XCTest
@testable import QAudionEngine
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What makes an append durable (a failing `F_FULLFSYNC` fails the append, so the part is never PUT), what keeps the journal out of every
/// backup (a store that cannot exclude it does not start, and does not write a journal), and what the descriptions of the types say.
final class FileV2SendDurabilityTests: XCTestCase {

    private func makeStore(durability: FileV2Durability, protection: FileV2FileProtection = FileV2SystemFileProtection()) throws
        -> (FileV2FileSendStore, URL) {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self).appendingPathComponent("send", isDirectory: true)
        return (try FileV2FileSendStore(directory: directory, durability: durability, protection: protection), directory)
    }

    // MARK: F_FULLFSYNC

    func testAFullSyncThatFailsFailsTheAppendAndTheBegin() throws {
        let errorNumber = FileV2Locked<Int32>(0)
        let (store, directory) = try makeStore(durability: FileV2SystemDurability(fullSync: { _ in errorNumber.withValue { $0 } }))
        let id = SendStoreFixtures.transferID
        try store.begin(SendStoreFixtures.begin())

        for fatal in [EIO, ENOSPC, EBADF, EINTR, EPERM] {
            errorNumber.withValue { $0 = fatal }
            XCTAssertThrowsError(try store.append(.partDone(0), to: id), "errno \(fatal) is a failure") {
                XCTAssertEqual($0 as? FileV2SendStoreError, .io("full sync"))
            }
        }
        errorNumber.withValue { $0 = EIO }
        XCTAssertThrowsError(try store.begin(SendStoreFixtures.begin(id: "second-transfer"))) {
            XCTAssertEqual($0 as? FileV2SendStoreError, .io("full sync"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), [id + ".qsj"],
                       "the begin that was not durable left no journal and no temporary file")

        // A file system that does not know the request is the one failure that is tolerated: fsync has done what the platform offers.
        for tolerated in [ENOTSUP, EINVAL] {
            errorNumber.withValue { $0 = tolerated }
            XCTAssertNoThrow(try store.append(.partDone(1), to: id), "errno \(tolerated)")
        }
        errorNumber.withValue { $0 = 0 }
        XCTAssertNoThrow(try store.append(.partDone(2), to: id))
        XCTAssertTrue(try store.load(id).confirmedParts.contains(2))
    }

    func testAFullSyncThatFailsOnTheDirectoryFailsTheFlushToo() throws {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self)
        XCTAssertThrowsError(try FileV2SystemDurability(fullSync: { _ in EIO }).flush(directory: directory)) {
            XCTAssertEqual($0 as? FileV2SendStoreError, .io("full sync"))
        }
        XCTAssertNoThrow(try FileV2SystemDurability(fullSync: { _ in ENOTSUP }).flush(directory: directory))
        XCTAssertNoThrow(try FileV2SystemDurability(fullSync: { _ in 0 }).flush(directory: directory))
    }

    func testEveryFlushOfAFileAsksTheFullSyncAboutThatFilesDescriptor() throws {
        let calls = FileV2Locked(0)
        let (store, _) = try makeStore(durability: FileV2SystemDurability(fullSync: { _ in
            calls.withValue { $0 += 1 }
            return 0
        }))
        try store.begin(SendStoreFixtures.begin())
        let afterBegin = calls.withValue { $0 }
        XCTAssertGreaterThanOrEqual(afterBegin, 2, "the begin record's file, and the directory entry of its rename")
        try store.append(.partDone(0), to: SendStoreFixtures.transferID)
        try store.append(.partDone(1), to: SendStoreFixtures.transferID)
        XCTAssertEqual(calls.withValue { $0 }, afterBegin + 2, "one per append")
    }

    func testAFullSyncThatFailsOnATagsRecordMeansThePartIsNeverPut() async throws {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        let log = rig.log
        // The request fails only while a tags record is being appended: the instrumented store logs the start of every append and the
        // recording durability logs the flush right before it asks the platform, so the start of the append is the event before the last.
        let durability = FileV2SystemDurability(fullSync: { _ in
            let events = log.events
            guard events.count >= 2 else { return 0 }
            let appending = events[events.count - 2]
            return appending.hasPrefix("journal.tags ") && appending.hasSuffix(".begin") ? EIO : 0
        })
        let store = try rig.makeStore(over: durability)
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let result = await (try rig.makePipeline(store: store)).send(rig.makeRequest(source, id: "no-full-sync"))
        assertSendFailure(result, .storage)
        XCTAssertEqual(rig.server.puts.count, 0, "the PUT never ran: the tags were not durable")

        // The state is kept; when the platform flushes again the transfer goes on, and no chunk ever carries two tags.
        let again = await (try rig.makePipeline()).resume(transferID: "no-full-sync")
        XCTAssertEqual(again, .sentOk)
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    // MARK: Backup exclusion

    private struct RefusingProtection: FileV2FileProtection {
        let refuses: @Sendable (URL) -> Bool

        func excludeFromBackup(_ url: URL) throws {
            if refuses(url) { throw FileV2SendStoreError.io("backup exclusion") }
        }

        func applyDataProtection(_ url: URL) {}
    }

    func testAStoreThatCannotExcludeItsDirectoryFromBackupDoesNotStart() throws {
        let directory = try FileV2TestSupport.makeTempDirectory(for: self).appendingPathComponent("send", isDirectory: true)
        XCTAssertThrowsError(try FileV2FileSendStore(directory: directory, durability: NoopDurability(),
                                                     protection: RefusingProtection { _ in true })) {
            XCTAssertEqual($0 as? FileV2SendStoreError, .io("backup exclusion"))
        }
    }

    func testAJournalThatCannotBeExcludedFromBackupIsNeverWrittenAndTheSendFailsBeforeAnyUpload() async throws {
        let rig = try SendRig(self)
        let refusing = RefusingProtection { $0.pathExtension == "tmp" || $0.pathExtension == "qsj" }      // the files, not the directory
        let store = try rig.makeStore(over: NoopDurability(), protection: refusing)
        XCTAssertThrowsError(try store.begin(SendStoreFixtures.begin())) { XCTAssertEqual($0 as? FileV2SendStoreError, .io("backup exclusion")) }
        XCTAssertEqual(try rig.journalNames(), [], "no journal and no temporary file")

        let result = await (try rig.makePipeline(store: store)).send(rig.makeRequest(GeneratedSource(size: 700_000), id: "no-backup-exclusion"))
        assertSendFailure(result, .storage)
        XCTAssertEqual(rig.fake.calls.count, 0, "nothing was uploaded, nothing was even created on the server")
        XCTAssertTrue(rig.channel.announced.isEmpty)
        try rig.assertNothingIsLeftBehind()
    }

    func testTheJournalIsExcludedFromBackupWhileItIsStillEmpty() throws {
        let sizes = FileV2Locked<[String]>([])
        final class Observing: FileV2FileProtection, @unchecked Sendable {
            let sizes: FileV2Locked<[String]>

            init(sizes: FileV2Locked<[String]>) {
                self.sizes = sizes
            }

            func excludeFromBackup(_ url: URL) throws {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
                sizes.withValue { $0.append("\(url.pathExtension.isEmpty ? "directory" : url.pathExtension)=\(size)") }
            }

            func applyDataProtection(_ url: URL) {}
        }
        let (store, _) = try makeStore(durability: NoopDurability(), protection: Observing(sizes: sizes))
        try store.begin(SendStoreFixtures.begin())
        XCTAssertEqual(sizes.withValue { $0 }.last, "tmp=0", "the wrapped key is never in a file a backup could take, not even for a moment")
        XCTAssertTrue(sizes.withValue { $0 }.first?.hasPrefix("directory") ?? false)
    }

    func testTheSystemProtectionSetsTheExclusionAndThrowsWhenItCannot() throws {
        #if canImport(Darwin)
        let directory = try FileV2TestSupport.makeTempDirectory(for: self)
        let file = directory.appendingPathComponent("journal.qsj")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        XCTAssertNoThrow(try FileV2SystemFileProtection().excludeFromBackup(file))
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertThrowsError(try FileV2SystemFileProtection().excludeFromBackup(directory.appendingPathComponent("missing"))) {
            XCTAssertEqual($0 as? FileV2SendStoreError, .io("backup exclusion"))
        }
        #else
        throw XCTSkip("backup exclusion is an Apple platform attribute")
        #endif
    }

    // MARK: What the descriptions say

    func testTheDescriptionsContainTheValuesTheyInterpolateWithIdsCutToEightCharacters() throws {
        XCTAssertEqual(FileV2SendTag(index: 1234, tag: Data(count: FileV2.tagSize)).description, "FileV2SendTag(index=1234)")
        let request = FileV2SendRequest(transferID: "abcdef0123456789-and-the-rest", source: GeneratedSource(size: 1),
                                        conversation: .group(groupID: "private-group"), metadata: FileV2SendMetadata(kind: .file))
        XCTAssertEqual(request.description, "FileV2SendRequest(id=abcdef01, group)")
        let begin = SendStoreFixtures.begin()
        XCTAssertEqual(begin.description, "FileV2SendBeginRecord(id=11111111, size=3000000, direct)")
        XCTAssertEqual(SendStoreFixtures.objectRecord().description, "FileV2SendObjectRecord(obj=0a1b2c3d, parts=1)")
        XCTAssertEqual(SendStoreFixtures.tokenRecord().description, "FileV2SendTokenRecord(scope=user, max=30)")
        XCTAssertEqual(begin.conversation.description, "FileV2Conversation(direct)")
        XCTAssertEqual(begin.metadata.description, "FileV2SendMetadata(kind=file)")
        XCTAssertEqual(begin.source.description, "FileV2SourceIdentity(size=3000000)")
        let recovered = FileV2SendRecovered(begin: begin, droppedTailBytes: 0)
        XCTAssertEqual(recovered.description,
                       "FileV2SendRecovered(FileV2SendBeginRecord(id=11111111, size=3000000, direct), phase=uploading, tags=0, confirmed=0)")
        let resumable = FileV2ResumableTransfer(transferID: "abcdef0123456789", phase: .announcePending, conversation: .direct(userID: "x"),
                                                source: begin.source, createdMs: 1, confirmedParts: 3, isRunning: false)
        XCTAssertEqual(resumable.description, "FileV2ResumableTransfer(id=abcdef01, phase=announcePending, parts=3, running=false)")
        XCTAssertEqual(FileV2SendStoreError.io("sync").description, "FileV2SendStoreError(io: sync)")
        XCTAssertEqual(FileV2SendStoreError.corrupt("tags").description, "FileV2SendStoreError(corrupt: tags)")
        XCTAssertEqual(FileV2SendStoreError.busy.description, "FileV2SendStoreError(busy)")
        XCTAssertEqual(FileV2SendStoreError.protectedDataUnavailable.description, "FileV2SendStoreError(protected_data_unavailable)")
        XCTAssertEqual(FileV2SendFailure(.busy).description, "FileV2SendFailure(busy)")
        XCTAssertEqual(FileV2SecretError.failed(-34018).description, "FileV2SecretError(failed: -34018)")

        // A string literal that lost the backslash before an interpolation prints the text of the interpolation instead of its value.
        let everything: [String] = [
            FileV2SendTag(index: 7, tag: Data(count: FileV2.tagSize)).description, request.description, begin.description,
            SendStoreFixtures.objectRecord().description, SendStoreFixtures.tokenRecord().description, recovered.description,
            resumable.description, FileV2SendStoreError.io("sync").description, FileV2SendFailure(.network).description
        ]
        for text in everything {
            for fragment in ["(index)", "(fileV2ShortID", "(conversation.", "(type(of", "\\("] {
                XCTAssertFalse(text.contains(fragment), "\(text) prints the text of an interpolation")
            }
        }
        // The ids of a dump are cut the same way.
        let dumped = SendStoreFixtures.printed(request)
        XCTAssertTrue(dumped.contains("abcdef01"))
        XCTAssertFalse(dumped.contains("abcdef012"), "no more than 8 characters of the id")
        XCTAssertFalse(dumped.contains("private-group"))
    }
}

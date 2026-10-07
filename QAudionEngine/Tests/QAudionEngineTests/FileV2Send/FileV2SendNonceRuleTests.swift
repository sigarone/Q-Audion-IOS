import XCTest
@testable import QAudionEngine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// WIRE_SPEC 12.8: the nonce-reuse rule. Encryption is deterministic, so a chunk may be sealed again on a retry or a resume instead of
/// being kept on disk, PROVIDED the content did not change. The tests change the content the way the rule is about: between runs, in a
/// chunk whose tag was journaled but whose part may have been PUT, with the size and the modification time left alone (the one change
/// rule 1 cannot see), and check that the changed chunk is never transmitted, the transfer is cancelled, and a new transfer has new key
/// material.
final class FileV2SendNonceRuleTests: XCTestCase {

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        return rig
    }

    /// Part 1 of a three-part file is sealed (its tags journaled) and the process dies before the PUT reaches the server.
    private func crashedBeforeThePutOfPartOne(_ rig: SendRig, _ source: GeneratedSource, id: String) async throws {
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: id))
        XCTAssertEqual(first, .interrupted)
        XCTAssertEqual(rig.server.puts.map { $0.part }, [0])
        rig.server.revive()
    }

    // MARK: Rule 2: a chunk whose tag differs is never transmitted

    func testASourceChangedBetweenRunsInAChunkOfAPartThatWasAboutToBeSentIsCancelledAndNothingDifferentIsTransmitted() async throws {
        for changedChunk in [8, 11, 15] {          // the first, a middle and the last chunk of part 1
            let rig = try sequentialRig()
            let source = GeneratedSource(size: SendTestSizes.threeParts)
            try await crashedBeforeThePutOfPartOne(rig, source, id: "changed")
            let begin = try rig.makeStore().load("changed").begin
            var firstKey = try rig.wrapper.unwrap(begin.wrappedKey)
            defer { FileV2Secret.wipe(&firstKey) }
            let identityBefore = try source.currentIdentity()

            source.mutate(chunk: changedChunk)                                  // other bytes, same size, same modification time
            XCTAssertTrue(try source.currentIdentity().isUnchanged(comparedTo: identityBefore), "rule 1 cannot see this change")

            let second = await (try rig.makePipeline()).resume(transferID: "changed")
            XCTAssertEqual(second, .failed(FileV2SendFailure(.sourceChanged)), "chunk \(changedChunk)")

            // Cancelled: the object deleted, the secrets and the journal gone, no descriptor.
            XCTAssertEqual(rig.fake.objectCount, 0, "chunk \(changedChunk)")
            XCTAssertTrue(rig.fake.calls.contains { $0.op == .delete }, "chunk \(changedChunk)")
            try rig.assertNothingIsLeftBehind()
            XCTAssertTrue(rig.channel.announced.isEmpty)
            // Nothing was transmitted for part 1 or after: only the first run's PUT of part 0 ever left the process, and every chunk
            // that was ever transmitted carries the tag of its first transmission.
            XCTAssertEqual(rig.server.puts.map { $0.part }, [0], "chunk \(changedChunk)")
            rig.assertNoChunkWasEverTransmittedWithADifferentTag()
            XCTAssertEqual(rig.telemetry.count { $0 == .contentChanged }, 1)

            // The caller restarts: a NEW transfer, with a new K and a new file_id, over the changed source.
            source.touch()
            let restart = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "restarted"))
            XCTAssertEqual(restart, .sentOk, "chunk \(changedChunk)")
            let descriptor = try rig.lastDescriptor()
            XCTAssertNotEqual(descriptor.fileKey, firstKey, "a new K")
            XCTAssertNotEqual(descriptor.fileID, begin.fileID, "a new file_id")
            try rig.assertBlobEqualsOneShot(descriptor: descriptor, source: source)
        }
    }

    func testTheChangedChunkIsNeverTransmittedEvenWhenTheRestOfThePartIsUnchanged() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        try await crashedBeforeThePutOfPartOne(rig, source, id: "one-chunk")
        let before = rig.server.puts.count
        source.mutate(chunk: 12)
        let result = await (try rig.makePipeline()).resume(transferID: "one-chunk")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(rig.server.puts.count, before)
        XCTAssertFalse(rig.log.events.contains { $0.hasPrefix("server.put.start part=1") })
    }

    func testAChunkThatWasNeverSealedBeforeIsFreeToHaveChanged() async throws {
        // Chunk 16 (part 2) was never sealed by the first run: there is no tag to compare, the changed content is simply its first seal.
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        try await crashedBeforeThePutOfPartOne(rig, source, id: "fresh-chunk")
        source.mutate(chunk: 16)
        let result = await (try rig.makePipeline()).resume(transferID: "fresh-chunk")
        XCTAssertEqual(result, .sentOk)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
    }

    // MARK: Rule 1: size or modification time

    func testASourceWhoseModificationTimeChangedIsCancelledBeforeAnythingIsSealed() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        try await crashedBeforeThePutOfPartOne(rig, source, id: "touched")
        let readsBefore = source.readCount
        source.touch()
        let result = await (try rig.makePipeline()).resume(transferID: "touched")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(source.readCount, readsBefore, "the source is not even read")
        XCTAssertEqual(rig.server.puts.count, 1)
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testASourceChangedAfterTheUploadStillCancelsAResumeThatOnlyAnnounces() async throws {
        // Nothing is left to upload, so no part is sealed and no tag is compared: rule 1 alone stops a descriptor of the OLD content from going
        // out for a file the user has saved again.
        let rig = try sequentialRig()
        rig.channel.setOutcomes([.unavailable, .sent])
        let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "announce-only"))
        assertSendFailure(first, .announceNotSent)
        XCTAssertEqual(rig.fake.objectCount, 1)

        source.touch()
        let second = await (try rig.makePipeline()).resume(transferID: "announce-only")
        assertSendFailure(second, .sourceChanged)
        XCTAssertEqual(rig.fake.objectCount, 0, "cancelled: the object is deleted")
        XCTAssertEqual(rig.channel.announced.count, 1, "no descriptor goes out after the change")
        try rig.assertNothingIsLeftBehind()
    }

    func testASourceWhoseSizeChangedIsCancelledBeforeAnythingIsSealed() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts, locator: "grown")
        try await crashedBeforeThePutOfPartOne(rig, source, id: "grown")
        // The file grew by a byte: another source object with the same locator.
        rig.sources.register(GeneratedSource(size: SendTestSizes.threeParts + 1, locator: "grown"))
        let result = await (try rig.makePipeline()).resume(transferID: "grown")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(rig.server.puts.count, 1)
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testAFileOnDiskThatIsEditedAndHasItsTimeRestoredIsCaughtByTheLedger() async throws {
        // The same trick on a real file: edit one byte of a chunk whose tags are journaled, put the modification time back.
        let rig = try sequentialRig()
        let generated = GeneratedSource(size: SendTestSizes.threeParts)
        let url = rig.root.appendingPathComponent("edited.bin")
        try generated.write(to: url)
        let originalTime = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let request = FileV2SendRequest(transferID: "edited", source: FileV2FileSource(url: url), conversation: .direct(userID: "bob"),
                                        metadata: FileV2SendMetadata(kind: .file))
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))
        let first = await (try rig.makePipeline()).send(request)
        XCTAssertEqual(first, .interrupted)

        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: UInt64(9 * FileV2.chunkSize + 5))
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalTime], ofItemAtPath: url.path)
        let identityNow = try FileV2FileSource(url: url).currentIdentity()
        XCTAssertEqual(identityNow.size, SendTestSizes.threeParts)

        rig.server.revive()
        let second = await (try rig.makePipeline()).resume(transferID: "edited")
        XCTAssertEqual(second, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(rig.server.puts.map { $0.part }, [0], "the edited chunk was never transmitted")
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
        try rig.assertNothingIsLeftBehind()
    }

    func testASourceThatChangesWhileItIsBeingUploadedIsCaughtBeforeTheNextPart() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setHook { op, call in
            if op == .putPart && call == 1 { source.touch() }      // saved again while part 1 is on the wire
        }
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "moving"))
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(rig.server.puts.map { $0.part }, [0, 1], "no part is sealed after the change was seen")
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testASourceThatChangesAfterTheLastPartIsCaughtBeforeComplete() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
        rig.server.setHook { op, call in
            if op == .putPart && call == 1 { source.touch() }      // during the last part
        }
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "late"))
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .complete }.count, 0, "a blob that may mix two versions is never closed")
        XCTAssertTrue(rig.channel.announced.isEmpty)
        XCTAssertEqual(rig.fake.objectCount, 0)
    }

    /// A source that claims three parts and runs out of bytes after ten chunks.
    private final class ShrinkingSource: FileV2SendSource, @unchecked Sendable {
        let inner = GeneratedSource(size: SendTestSizes.threeParts, locator: "shrinking")

        func currentIdentity() throws -> FileV2SourceIdentity { try inner.currentIdentity() }

        func makeReader() throws -> FileV2SourceReader { Reader(owner: inner) }

        final class Reader: FileV2SourceReader {
            let owner: GeneratedSource

            init(owner: GeneratedSource) {
                self.owner = owner
            }

            func read(offset: UInt64, length: Int) throws -> Data {
                if offset >= UInt64(10 * FileV2.chunkSize) { throw FileV2SendSourceError.shortRead }
                guard let bytes = owner.bytes(offset: offset, length: length) else { throw FileV2SendSourceError.shortRead }
                return bytes
            }

            func close() {}
        }
    }

    func testASourceThatShrinksUnderTheReadIsASourceChange() async throws {
        let rig = try sequentialRig()
        let request = FileV2SendRequest(transferID: "shrinks", source: ShrinkingSource(), conversation: .direct(userID: "bob"),
                                        metadata: FileV2SendMetadata(kind: .file))
        let result = await (try rig.makePipeline()).send(request)
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    // MARK: Rule 3: a part that fails is sent again with the same bytes

    func testARetryAfterAFailureSendsTheSameBytesFromMemoryNeverFromAChangedSource() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let pristine = GeneratedSource(size: SendTestSizes.threeParts)          // the same content, never touched
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 503, code: "storage_error"), times: 1, part: 1)
        // Between the failed attempt and the retry the source changes under the process.
        rig.server.setHook { op, call in
            if op == .putPart && call == 2 { source.mutate(chunk: 9) }
        }
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "retry-bytes"))
        XCTAssertEqual(result, .sentOk)
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
        // The blob on the server is the ORIGINAL content: the retry did not read the source again.
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: pristine)
    }

    func testAPartConflictAnswerOfTheServerIsASourceChange() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        // The server holds part 1 with other bytes: for a deterministic sender this can only mean the source changed.
        rig.fake.injectFailure(.putPart, error: FileV2ServerError(status: 409, code: "part_conflict"), times: 1, part: 1)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "conflict"))
        assertSendFailure(result, .sourceChanged, code: "part_conflict")
        XCTAssertEqual(rig.fake.objectCount, 0, "cancelled: the object is deleted")
        try rig.assertNothingIsLeftBehind()
    }

    func testALostAnswerIsRetriedAndTheServersDuplicateAnswerIsASuccess() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        // Part 1 reaches the server and the answer is lost: the retry gets 200 with duplicate: true (same part, same digest).
        rig.fake.injectFailure(.putPart, error: URLError(.networkConnectionLost), times: 1, part: 1, when: .afterEffect)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "duplicate"))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(rig.telemetry.count { if case .partUploaded(_, let duplicate) = $0 { return duplicate } else { return false } }, 1)
        XCTAssertEqual(rig.telemetry.count { $0 == .retried }, 1)
        XCTAssertEqual(rig.sleeper.delays, [1000], "one backoff of a second")
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }
}

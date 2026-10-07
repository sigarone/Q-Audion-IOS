import XCTest
@testable import QAudionEngine

/// Resume after a crash (WIRE_SPEC 12.8): the process dies at a chosen call of the server, a NEW pipeline over the same journal, the same
/// secure store and the same server resumes, and the transfer completes with a blob that is byte for byte a one-shot encryption.
///
/// A crash is simulated by the recording server: from the chosen call on every call throws `CancellationError` at once, the pipeline
/// does nothing more, and what survives is what the journal, the secure store and the server hold.
final class FileV2SendResumeTests: XCTestCase {

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1        // the server asks for one part at a time: the crash points are exact
        return rig
    }

    // MARK: A crash at every part boundary

    func testCrashAtEveryPartBoundaryThenResumeCompletesWithAnIdenticalBlob() async throws {
        let size = SendTestSizes.threeParts
        let parts = SendTestSizes.parts(ofSize: size)
        XCTAssertEqual(parts, 3)
        for applyEffect in [false, true] {
            for crashCall in 0..<parts {
                let label = "crash at PUT \(crashCall), effect \(applyEffect)"
                let rig = try sequentialRig()
                let source = GeneratedSource(size: size)
                let id = "crash-\(crashCall)-\(applyEffect)"
                rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: crashCall, applyEffect: applyEffect))

                // The first run dies.
                let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: id))
                XCTAssertEqual(first, .interrupted, label)
                XCTAssertTrue(rig.server.isDead, label)

                // What the dead process left: a journal that holds the tags of every part it PUT or was about to PUT, a wrapped key, no
                // descriptor, nothing deleted.
                let left = try rig.makeStore().load(id)
                XCTAssertEqual(left.tags.count, [8, 16, 17][crashCall], "tags of parts 0...\(crashCall) are durable \(label)")
                XCTAssertNotNil(left.object, label)
                XCTAssertEqual(rig.wrapper.count, 2, "the key and the token \(label)")
                XCTAssertTrue(rig.channel.announced.isEmpty, label)
                XCTAssertFalse(rig.log.events.contains("server.delete"), label)

                // The second run, a new process.
                rig.server.revive()
                let collector = StateCollector()
                let second = await (try rig.makePipeline()).resume(transferID: id, onState: collector.sink)
                XCTAssertEqual(second, .sentOk, label)

                let descriptor = try rig.lastDescriptor()
                try rig.assertBlobEqualsOneShot(descriptor: descriptor, source: source)

                // Parts the server had are not sent again; every part was PUT once in all, and a part sent twice would carry the same bytes.
                let puts = rig.server.puts
                XCTAssertEqual(puts.count, parts, label)
                XCTAssertEqual(Set(puts.map { $0.part }), Set(0..<parts), label)
                let received = applyEffect ? crashCall + 1 : crashCall
                XCTAssertEqual(rig.fake.calls.filter { $0.op == .partsMap }.count, received > 0 ? 1 : 0,
                               "one look at the server's map when it has parts \(label)")

                // The ordering of the nonce rule holds over both runs.
                XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(rig.log.events, totalChunks: descriptor.header.totalChunks), [], label)
                XCTAssertEqual(SendEventAnalysis.everyTagAppendIsFlushed(rig.log.events), [], label)
                try rig.assertNothingIsLeftBehind()
            }
        }
    }

    func testResumeAsksTheServerWhichPartsItHasAndSendsOnlyTheMissingOnes() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: true))     // parts 0 and 1 reach the server
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "only-missing"))
        XCTAssertEqual(first, .interrupted)
        rig.log.clear()
        rig.server.revive()
        let collector = StateCollector()
        let second = await (try rig.makePipeline()).resume(transferID: "only-missing", onState: collector.sink)
        XCTAssertEqual(second, .sentOk)
        XCTAssertEqual(SendEventAnalysis.putStarts(rig.log.events), [2], "only the missing part is uploaded")
        let progress = collector.states.compactMap { state -> Int? in
            if case .uploading(let value) = state { return value.partsDone }
            return nil
        }
        XCTAssertEqual(progress.first, 2, "the progress starts from what the server already has")
        XCTAssertEqual(progress.last, 3)
    }

    func testAResumeThatMakesNoProgressStillReadsTheSourceOnlyForMissingParts() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 2, applyEffect: true))     // all parts are on the server
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "all-parts-up"))
        let readsBefore = source.readCount
        rig.server.revive()
        let second = await (try rig.makePipeline()).resume(transferID: "all-parts-up")
        XCTAssertEqual(second, .sentOk)
        XCTAssertEqual(source.readCount, readsBefore, "nothing is read or sealed again when the server has every part")
        XCTAssertEqual(rig.server.puts.count, 3)
    }

    // MARK: A crash around create, complete and the announce

    func testCrashDuringCreateBeforeOrAfterItsEffectIsRecoveredByTheIdempotentCreate() async throws {
        for applyEffect in [false, true] {
            let rig = try sequentialRig()
            let source = GeneratedSource(size: 900_000)
            rig.server.setCrash(RecordingServer.CrashPlan(op: .create, call: 0, applyEffect: applyEffect))
            let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "crash-create"))
            XCTAssertEqual(first, .interrupted)
            XCTAssertEqual(try rig.makeStore().load("crash-create").object, nil, "the journal never heard of the object")
            XCTAssertEqual(rig.fake.objectCount, applyEffect ? 1 : 0)

            rig.server.revive()
            let second = await (try rig.makePipeline()).resume(transferID: "crash-create")
            XCTAssertEqual(second, .sentOk)
            XCTAssertEqual(rig.fake.objectCount, 1, "the object that existed is found again, not made a second time (effect \(applyEffect))")
            try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
            try rig.assertNothingIsLeftBehind()
        }
    }

    func testCrashDuringCompleteBeforeOrAfterItsEffectDoesNotUploadAnythingAgain() async throws {
        for applyEffect in [false, true] {
            let rig = try sequentialRig()
            let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
            rig.server.setCrash(RecordingServer.CrashPlan(op: .complete, call: 0, applyEffect: applyEffect))
            let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "crash-complete"))
            XCTAssertEqual(first, .interrupted)
            XCTAssertEqual(try rig.makeStore().load("crash-complete").phase, .uploading, "the journal never heard of the complete")
            rig.log.clear()
            rig.server.revive()
            let second = await (try rig.makePipeline()).resume(transferID: "crash-complete")
            XCTAssertEqual(second, .sentOk)
            XCTAssertEqual(SendEventAnalysis.putStarts(rig.log.events), [], "no part is uploaded again (effect \(applyEffect))")
            try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
        }
    }

    func testCrashWhileTheDescriptorIsBeingHandedOverAnnouncesAgainWithTheSameKeyAndNoUpload() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
        rig.channel.setHangs(true)
        let pipeline = try rig.makePipeline()
        let running = Task { await pipeline.send(rig.makeRequest(source, id: "crash-announce")) }
        try await pollUntilTrue { !rig.channel.announced.isEmpty }
        running.cancel()                                           // the process dies with the handover unanswered
        let first = await running.value
        XCTAssertEqual(first, .interrupted)
        let left = try rig.makeStore().load("crash-announce")
        XCTAssertEqual(left.phase, .announcing)
        XCTAssertTrue(left.descriptorMayHaveBeenSent)

        rig.channel.setHangs(false)
        rig.log.clear()
        let second = await (try rig.makePipeline()).resume(transferID: "crash-announce")
        XCTAssertEqual(second, .sentOk)
        XCTAssertEqual(rig.channel.announced.count, 2)
        XCTAssertEqual(Set(rig.channel.announced.map { $0.key }), ["crash-announce"], "the chat can dedupe: the same key both times")
        let before = try FileV2Descriptor.parse(rig.channel.announced[0].body)
        let after = try FileV2Descriptor.parse(rig.channel.announced[1].body)
        XCTAssertEqual(before.fileKey, after.fileKey)
        XCTAssertEqual(before.fileID, after.fileID)
        XCTAssertEqual(before.source.obj, after.source.obj)
        XCTAssertEqual(SendEventAnalysis.putStarts(rig.log.events), [], "no upload for an announce")
        try rig.assertNothingIsLeftBehind()
    }

    func testCancelAfterACrashDuringTheHandoverDeletesTheObjectAndSendsCancelThroughTheChat() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
        rig.channel.setHangs(true)
        let pipeline = try rig.makePipeline()
        let running = Task { await pipeline.send(rig.makeRequest(source, id: "cancel-after-crash")) }
        try await pollUntilTrue { !rig.channel.announced.isEmpty }
        running.cancel()
        _ = await running.value
        let descriptor = try FileV2Descriptor.parse(rig.channel.announced[0].body)
        let objectBefore = rig.fake.objectCount
        XCTAssertEqual(objectBefore, 1)

        let restarted = try rig.makePipeline()
        let existed = await restarted.cancel(transferID: "cancel-after-crash")
        XCTAssertTrue(existed)
        XCTAssertEqual(rig.fake.objectCount, 0, "the object is deleted")
        XCTAssertEqual(rig.channel.controls.count, 1, "the descriptor may have gone out: the receiver is told")
        let control = try XCTUnwrap(rig.channel.controls.first)
        guard case .cancel(let message) = FileV2Message.recognize(control.body) else { return XCTFail("not a cancel message") }
        XCTAssertEqual(message.fileID, descriptor.fileID)
        XCTAssertEqual(control.conversation, .direct(userID: "bob"))
        try rig.assertNothingIsLeftBehind()
    }

    // MARK: A journal that cannot be trusted

    func testATornTagRecordOfAPartThatNeverReachedTheServerCostsNothing() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))     // tags of part 1 durable, PUT never made
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "torn-unsent"))
        // The crash tore the append of those tags too: the journal ends in the middle of the record.
        let events = try rig.journalEvents(id: "torn-unsent")
        XCTAssertEqual(InstrumentedStore.label(try XCTUnwrap(events.last)), "tags part=1 chunks=8,9,10,11,12,13,14,15")
        try rig.cutJournal(id: "torn-unsent", droppingLast: 1, leaving: 7)

        rig.server.revive()
        let result = await (try rig.makePipeline()).resume(transferID: "torn-unsent")
        XCTAssertEqual(result, .sentOk, "a part that was never PUT can be sealed again and its tags recorded anew")
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    func testAJournalThatLostTheTagsOfAPartTheServerHoldsCancelsTheTransfer() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: true))     // part 1 IS on the server
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "lost-tags"))
        try rig.cutJournal(id: "lost-tags", droppingLast: 1)                                          // ... and its tags are gone
        let putsBefore = rig.server.puts.count

        rig.server.revive()
        let result = await (try rig.makePipeline()).resume(transferID: "lost-tags")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.stateLost)))
        XCTAssertEqual(rig.server.puts.count, putsBefore, "nothing is transmitted when the tags that vouch for the bytes are gone")
        XCTAssertEqual(rig.fake.objectCount, 0, "the object is deleted")
        try rig.assertNothingIsLeftBehind()
    }

    func testTwoRecordsThatDisagreeAboutATagCancelTheTransfer() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: false))
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "conflicting"))
        try rig.makeStore().inner.append(.tags(part: 0, entries: [FileV2SendTag(index: 0, tag: Data(repeating: 9, count: 16))]), to: "conflicting")
        rig.server.revive()
        let result = await (try rig.makePipeline()).resume(transferID: "conflicting")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.stateLost)))
        XCTAssertEqual(rig.server.puts.count, 1, "only the first part ever left")
        try rig.assertNothingIsLeftBehind()
    }

    func testAJournalWithoutItsBeginRecordIsRemovedAndReported() async throws {
        let rig = try sequentialRig()
        let pipeline = try rig.makePipeline()
        try FileManager.default.createDirectory(at: rig.storeDirectory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: rig.storeDirectory.appendingPathComponent("broken.qsj"))
        let result = await pipeline.resume(transferID: "broken")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.stateLost)))
        XCTAssertEqual(try rig.journalNames(), [])
        let nothing = await pipeline.resume(transferID: "never-existed")
        XCTAssertEqual(nothing, .failed(FileV2SendFailure(.stateLost)))
    }

    func testAKeyThatTheSecureStoreNoLongerHoldsCancelsTheTransfer() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: true))
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "key-lost"))
        let begin = try rig.makeStore().load("key-lost").begin
        rig.wrapper.destroy(begin.wrappedKey)                                // the Keychain was reset

        rig.server.revive()
        let result = await (try rig.makePipeline()).resume(transferID: "key-lost")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.stateLost)))
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testASourceThatCannotBeFoundAgainCancelsTheTransfer() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: true))
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "source-gone"))
        rig.sources.failLookups = true
        rig.server.revive()
        let result = await (try rig.makePipeline()).resume(transferID: "source-gone")
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    // MARK: A resume that only announces does not need the source

    /// A transfer whose upload is over and whose descriptor the chat refused (`ANNOUNCE_NOT_SENT`): its state is `announcePending`.
    private func announcePending(_ rig: SendRig, source: GeneratedSource, id: String) async throws {
        rig.channel.setOutcomes([.unavailable, .sent])
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: id))
        assertSendFailure(first, .announceNotSent)
        XCTAssertEqual(rig.fake.objectCount, 1)
        XCTAssertEqual(try rig.makeStore().load(id).phase, .announcePending)
    }

    func testAnAnnounceOnlyResumeWhoseSourceIsGoneKeepsTheUploadedBlobAndAnnouncesIt() async throws {
        // The review's probe: an iOS temporary copy that the system purged before the re-announce used to destroy a blob that was complete.
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        try await announcePending(rig, source: source, id: "source-gone-announce")
        let putsBefore = rig.server.puts.count
        let firstDescriptor = try rig.lastDescriptor()

        rig.sources.failLookups = true                                           // the source cannot be found any more
        let second = await (try rig.makePipeline()).resume(transferID: "source-gone-announce")
        XCTAssertEqual(second, .sentOk)
        XCTAssertEqual(rig.fake.objectCount, 1, "the uploaded blob is still there")
        XCTAssertFalse(rig.fake.calls.contains { $0.op == .delete })
        XCTAssertEqual(rig.server.puts.count, putsBefore, "no upload")
        XCTAssertEqual(rig.channel.announced.count, 2)
        let secondDescriptor = try rig.lastDescriptor()
        XCTAssertEqual(secondDescriptor.fileKey, firstDescriptor.fileKey)
        XCTAssertEqual(secondDescriptor.source.obj, firstDescriptor.source.obj)
        XCTAssertEqual(rig.telemetry.count { $0 == .contentChanged }, 0, "a missing source is not a changed source here")
        try rig.assertBlobEqualsOneShot(descriptor: secondDescriptor, source: GeneratedSource(size: SendTestSizes.threeParts))
        try rig.assertNothingIsLeftBehind()
    }

    func testAResumeInTheMiddleOfTheAnnounceAlsoDoesNotNeedTheSource() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
        rig.channel.setHangs(true)
        let pipeline = try rig.makePipeline()
        let running = Task { await pipeline.send(rig.makeRequest(source, id: "announcing-source-gone")) }
        try await pollUntilTrue { !rig.channel.announced.isEmpty }
        running.cancel()                                                         // the process dies with the handover unanswered
        _ = await running.value
        XCTAssertEqual(try rig.makeStore().load("announcing-source-gone").phase, .announcing)

        rig.channel.setHangs(false)
        rig.sources.failLookups = true
        let second = await (try rig.makePipeline()).resume(transferID: "announcing-source-gone")
        XCTAssertEqual(second, .sentOk)
        XCTAssertEqual(rig.channel.announced.count, 2)
        XCTAssertEqual(rig.fake.objectCount, 1)
    }

    func testAResumeThatStillHasPartsToUploadNeedsTheSourceAndCancelsWithoutIt() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: true))
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "still-uploading"))
        rig.sources.failLookups = true
        rig.server.revive()
        let result = await (try rig.makePipeline()).resume(transferID: "still-uploading")
        assertSendFailure(result, .sourceChanged)
        XCTAssertEqual(rig.fake.objectCount, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testAnAnnounceOnlyResumeWhoseObjectTheServerLostFindsTheSourceWhenAnUploadBecomesNecessary() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        try await announcePending(rig, source: source, id: "object-lost")
        let oldObject = try XCTUnwrap(try rig.makeStore().load("object-lost").object?.obj)
        try await rig.fake.delete(obj: oldObject)                                // the server lost it
        XCTAssertEqual(rig.fake.objectCount, 0)

        // The source is still there: the object is made again from the same header and every part is sent again with the same bytes (the
        // ledger of the journal), under rule 1, which is checked now.
        let second = await (try rig.makePipeline()).resume(transferID: "object-lost")
        XCTAssertEqual(second, .sentOk)
        let descriptor = try rig.lastDescriptor()
        XCTAssertNotEqual(descriptor.source.obj, oldObject, "a NEW object")
        try rig.assertBlobEqualsOneShot(descriptor: descriptor, source: source)
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
        rig.assertNoChunkWasEverTransmittedWithADifferentTag()
        try rig.assertNothingIsLeftBehind()
    }

    func testAnAnnounceOnlyResumeWhoseObjectTheServerLostAndWhoseSourceIsGoneIsCancelled() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        try await announcePending(rig, source: source, id: "object-and-source-lost")
        try await rig.fake.delete(obj: try XCTUnwrap(try rig.makeStore().load("object-and-source-lost").object?.obj))
        let putsBefore = rig.server.puts.count

        rig.sources.failLookups = true
        let second = await (try rig.makePipeline()).resume(transferID: "object-and-source-lost")
        assertSendFailure(second, .sourceChanged)
        XCTAssertEqual(rig.server.puts.count, putsBefore, "nothing could be uploaded and nothing was")
        XCTAssertEqual(rig.fake.objectCount, 0, "the object made again is deleted too")
        XCTAssertEqual(rig.channel.announced.count, 1, "no descriptor goes out for an object that has no blob")
        try rig.assertNothingIsLeftBehind()
    }

    // MARK: The server deleted the object (6 h idle, 24 h absolute)

    func testAnObjectTheServerDeletedIsMadeAgainFromTheSameHeaderAndEveryPartIsSentAgainWithTheSameBytes() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setCrash(RecordingServer.CrashPlan(op: .putPart, call: 1, applyEffect: true))      // parts 0 and 1 are on the server
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "expired"))
        let begin = try rig.makeStore().load("expired").begin
        let oldObject = try XCTUnwrap(try rig.makeStore().load("expired").object?.obj)
        let tagEventsBefore = try rig.journalEvents(id: "expired").filter { if case .tags = $0 { return true } else { return false } }.count
        XCTAssertEqual(tagEventsBefore, 2)

        // Seven hours pass: the unfinished object idles past the server's 6 hours and the hourly clean-up deletes it.
        rig.clock.advance(ms: 7 * 3_600_000)
        rig.fake.cleanup()
        XCTAssertEqual(rig.fake.objectCount, 0)

        rig.server.revive()
        let second = await (try rig.makePipeline()).resume(transferID: "expired")
        XCTAssertEqual(second, .sentOk)
        let descriptor = try rig.lastDescriptor()
        XCTAssertEqual(descriptor.fileKey.count, 32)
        XCTAssertEqual(descriptor.fileID, begin.fileID, "the same file id")
        XCTAssertEqual(descriptor.header.bytes, begin.header, "the same header")
        XCTAssertNotEqual(descriptor.source.obj, oldObject, "a NEW object")
        try rig.assertBlobEqualsOneShot(descriptor: descriptor, source: source)

        // Parts 0 and 1 travelled twice, with the same bytes (the ledger rule): the digests of every transmission of a part are equal.
        let puts = rig.server.puts
        XCTAssertEqual(puts.count, 5)
        for part in 0..<3 {
            XCTAssertEqual(Set(puts.filter { $0.part == part }.map { $0.digest }).count, 1, "part \(part) was sent with one set of bytes")
        }
        // And there was no second set of tags: part 2's tags are the only ones this run appended.
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(rig.log.events, totalChunks: descriptor.header.totalChunks), [])
    }

    func testAnObjectThatDisappearsInTheMiddleOfARunIsMadeAgainAndTheRunCompletes() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        // At the third PUT the server's clean-up has deleted the object (the clock jumped seven hours): the PUT is a 404.
        rig.server.setHook { [rig] op, call in
            if op == .putPart && call == 2 {
                rig.clock.advance(ms: 7 * 3_600_000)
                rig.fake.cleanup()
            }
        }
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "vanishes"))
        XCTAssertEqual(result, .sentOk)
        let descriptor = try rig.lastDescriptor()
        try rig.assertBlobEqualsOneShot(descriptor: descriptor, source: source)
        XCTAssertEqual(rig.telemetry.count { $0 == .objectRecreated }, 1)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .create }.count, 2)
        let tagRecords = rig.log.events.filter { $0.hasPrefix("journal.tags ") && $0.hasSuffix(".done") }
        XCTAssertEqual(tagRecords.count, 3, "every chunk's tag was journaled once: the re-seal of a journaled chunk appends nothing")
        for part in 0..<3 {
            XCTAssertEqual(Set(rig.server.puts.filter { $0.part == part }.map { $0.digest }).count, 1, "part \(part): one set of bytes")
        }
    }

    func testAnObjectThatDisappearsAndASourceThatChangedNeverTransmitsTheChangedBytes() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.server.setHook { [rig] op, call in
            if op == .putPart && call == 2 {
                rig.clock.advance(ms: 7 * 3_600_000)
                rig.fake.cleanup()
                source.mutate(chunk: 3)                  // same size, same time, other bytes in part 0
            }
        }
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "vanishes-and-changes"))
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceChanged)))
        let puts = rig.server.puts
        XCTAssertEqual(puts.filter { $0.part == 0 }.count, 1, "part 0 was never sent a second time with changed bytes")
        XCTAssertEqual(rig.fake.objectCount, 0, "the new object is deleted too")
        try rig.assertNothingIsLeftBehind()
    }
}

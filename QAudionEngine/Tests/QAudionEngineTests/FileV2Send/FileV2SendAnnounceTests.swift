import XCTest
@testable import QAudionEngine

/// The end of a transfer: the descriptor goes to the chat, and the transfer is reported as sent only when the chat SENT it.
final class FileV2SendAnnounceTests: XCTestCase {

    private func sequentialRig() throws -> SendRig {
        let rig = try SendRig(self)
        rig.fake.maxPartsInFlight = 1
        return rig
    }

    func testSentIsReportedOnlyWhenTheChatSentTheDescriptor() async throws {
        for (outcome, expected) in [(FileV2AnnounceOutcome.sent, FileV2SendState.sentOk),
                                    (.queued, .sentAnnouncePending)] {
            let rig = try sequentialRig()
            rig.channel.setOutcomes([outcome])
            let collector = StateCollector()
            let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)), onState: collector.sink)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(collector.states.filter { $0 == .sentOk }.count, expected == .sentOk ? 1 : 0, "sent only on the chat's sent")
            XCTAssertEqual(collector.states.last, expected)
            // Either way the chat has the descriptor and owns it from here: this side keeps no key and no token.
            try rig.assertNothingIsLeftBehind()
            XCTAssertEqual(rig.fake.objectCount, 1, "the blob stays on the server for the recipients")
            XCTAssertEqual(rig.telemetry.count { $0 == .finished(code: expected == .sentOk ? "sent" : "announce_pending") }, 1)
        }
    }

    func testAChatThatCannotCarryTheDescriptorKeepsTheBlobAndARetryOnlyAnnouncesAgain() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        rig.channel.setOutcomes([.unavailable, .sent])
        let collector = StateCollector()
        let first = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "announce-later"), onState: collector.sink)
        let failure = assertFailure(first, .announceNotSent)
        XCTAssertTrue(failure?.keepsState ?? false)
        XCTAssertFalse(collector.states.contains(.sentOk), "never sent: the chat said it could not")
        XCTAssertEqual(rig.server.puts.count, 3)
        XCTAssertEqual(try rig.journalNames(), ["announce-later.qsj"], "state kept")
        XCTAssertEqual(rig.wrapper.count, 2)
        XCTAssertEqual(rig.fake.objectCount, 1, "blob kept")
        let list = await (try rig.makePipeline()).listResumable()
        XCTAssertEqual(list.first?.phase, .announcePending)

        // Later (the chat is back): only the announce is repeated.
        rig.log.clear()
        let putsBefore = rig.server.puts.count
        let collector2 = StateCollector()
        let second = await (try rig.makePipeline()).resume(transferID: "announce-later", onState: collector2.sink)
        XCTAssertEqual(second, .sentOk)
        XCTAssertEqual(rig.server.puts.count, putsBefore, "no re-upload")
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .complete }.count, 1, "no second complete")
        XCTAssertEqual(rig.channel.announced.count, 2)
        XCTAssertFalse(collector2.states.contains { if case .uploading = $0 { return true } else { return false } })
        // Same file, same key, same object: only the token may be a new one.
        let before = try FileV2Descriptor.parse(rig.channel.announced[0].body)
        let after = try FileV2Descriptor.parse(rig.channel.announced[1].body)
        XCTAssertEqual(before.fileKey, after.fileKey)
        XCTAssertEqual(before.fileID, after.fileID)
        XCTAssertEqual(before.header.bytes, after.header.bytes)
        XCTAssertEqual(before.source.obj, after.source.obj)
        try rig.assertBlobEqualsOneShot(descriptor: after, source: source)
        try rig.assertNothingIsLeftBehind()
    }

    func testTheDescriptorIsBuiltFromTheStateAfterARestartAndEqualsTheBuildersOutput() async throws {
        let rig = try sequentialRig()
        let metadata = FileV2SendMetadata(kind: .image, name: "photo ü.jpg", mimeType: "image/jpeg",
                                          media: FileV2SendMetadata.Media(w: 1920, h: 1080), preview: Data(repeating: 3, count: 100), ex: -1, xp: 1)
        rig.channel.setOutcomes([.unavailable, .sent])
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 900_000), id: "after-restart", metadata: metadata))

        // The second run is a new process: it rebuilds the descriptor from the journal and the secure store.
        let seen = FileV2Locked<String?>(nil)
        rig.channel.setHook { [rig] body in
            guard let recovered = try? rig.store?.load("after-restart"), let key = try? rig.wrapper.unwrap(recovered.begin.wrappedKey),
                  let record = recovered.token, let tokenData = try? rig.wrapper.unwrap(record.wrappedValue),
                  let object = recovered.object else { return }
            let source = FileV2Descriptor.Source(via: .srv, obj: object.obj,
                                                 token: FileV2Descriptor.Token(v: String(decoding: tokenData, as: UTF8.self), exp: record.exp,
                                                                               max: Int64(record.max)))
            let file = FileV2FileInput(fileID: recovered.begin.fileID, fileKey: key, header: recovered.begin.header,
                                       size: recovered.begin.plaintextSize, kind: .image, source: source, name: "photo ü.jpg",
                                       mimeType: "image/jpeg", media: FileV2Descriptor.Media(w: 1920, h: 1080),
                                       preview: Data(repeating: 3, count: 100), ex: -1, xp: 1)
            seen.withValue { $0 = try? FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: file)) }
            _ = body
        }
        let second = await (try rig.makePipeline()).resume(transferID: "after-restart")
        XCTAssertEqual(second, .sentOk)
        let expected = try XCTUnwrap(seen.withValue { $0 })
        XCTAssertEqual(Array(try XCTUnwrap(rig.channel.announced.last?.body).utf8), Array(expected.utf8))
        let parsed = try FileV2Descriptor.parse(expected)
        XCTAssertEqual(parsed.name, "photo ü.jpg")
        XCTAssertEqual(parsed.ex, -1)
        XCTAssertEqual(parsed.xp, 1)
    }

    func testAnAnnounceThatTheChatKeepsRefusingKeepsTheStateEveryTime() async throws {
        let rig = try sequentialRig()
        rig.channel.setOutcomes([.unavailable])
        let pipeline = try rig.makePipeline()
        _ = await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000), id: "refused-chat"))
        for _ in 0..<3 {
            let again = await (try rig.makePipeline()).resume(transferID: "refused-chat")
            assertFailure(again, .announceNotSent)
            XCTAssertEqual(try rig.journalNames(), ["refused-chat.qsj"])
            XCTAssertEqual(rig.wrapper.count, 2, "no new secret piles up: each token replaces the one before")
        }
        XCTAssertEqual(rig.server.puts.count, 1)
    }

    func testAnObjectThatIsGoneWhenTheAnnounceIsRetriedIsUploadedAgainFromTheSameKey() async throws {
        let rig = try sequentialRig()
        let source = GeneratedSource(size: SendTestSizes.oneChunkOver)
        rig.channel.setOutcomes([.unavailable, .sent])
        _ = await (try rig.makePipeline()).send(rig.makeRequest(source, id: "gone-before-announce"))
        let first = try FileV2Descriptor.parse(rig.channel.announced[0].body)
        // 31 days later even a completed object is gone.
        rig.clock.advance(ms: 31 * 86_400_000)
        rig.fake.cleanup()
        XCTAssertEqual(rig.fake.objectCount, 0)

        let second = await (try rig.makePipeline()).resume(transferID: "gone-before-announce")
        XCTAssertEqual(second, .sentOk)
        let after = try FileV2Descriptor.parse(rig.channel.announced[1].body)
        XCTAssertEqual(after.fileKey, first.fileKey, "the same K")
        XCTAssertEqual(after.fileID, first.fileID, "the same file id")
        XCTAssertNotEqual(after.source.obj, first.source.obj, "a new object")
        try rig.assertBlobEqualsOneShot(descriptor: after, source: source)
        rig.assertEveryPartWasAlwaysSentWithTheSameBytes()
    }

    func testTelemetryIsCountersOnly() async throws {
        let rig = try sequentialRig()
        _ = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: SendTestSizes.oneChunkOver), id: "telemetry-only"))
        let text = rig.telemetry.events.map { SendStoreFixtures.printed($0) }.joined(separator: "\n")
        for word in ["telemetry-only", "bob", "report.pdf", "generated-", "alice"] {
            XCTAssertFalse(text.contains(word), "telemetry carries no \(word)")
        }
        XCTAssertTrue(rig.telemetry.events.contains(.started(resumed: false)))
        XCTAssertTrue(rig.telemetry.events.contains(.finished(code: "sent")))
        XCTAssertEqual(rig.telemetry.count { if case .partUploaded = $0 { return true } else { return false } }, 2)
    }
}

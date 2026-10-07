import XCTest
@testable import QAudionEngine

/// The send pipeline end to end against the fake server: preflight, a complete transfer, the descriptor, what is stored and what is
/// not, the states.
final class FileV2SendPipelineTests: XCTestCase {

    /// What the chat's hook sees while the transfer's state still exists (the descriptor is being handed over).
    struct AtAnnounce: @unchecked Sendable {
        var key = Data()
        var tokenText = ""
        var tokenRecord: FileV2SendTokenRecord?
        var object = ""
        var header = Data()
        var fileID = Data()
        var expectedBody = ""
        var secretsFoundInFiles: [String] = []
        var journalFiles: [String] = []
    }

    func captureAtAnnounce(_ rig: SendRig, id: String, metadata: FileV2SendMetadata, size: UInt64) -> FileV2Locked<AtAnnounce> {
        let captured = FileV2Locked(AtAnnounce())
        rig.channel.setHook { _ in
            guard let store = rig.store, let recovered = try? store.load(id),
                  let key = try? rig.wrapper.unwrap(recovered.begin.wrappedKey),
                  let record = recovered.token, let tokenData = try? rig.wrapper.unwrap(record.wrappedValue),
                  let object = recovered.object else { return }
            let tokenText = String(decoding: tokenData, as: UTF8.self)
            let source = FileV2Descriptor.Source(via: .srv, obj: object.obj,
                                                 token: FileV2Descriptor.Token(v: tokenText, exp: record.exp, max: Int64(record.max)))
            let input = FileV2FileInput(fileID: recovered.begin.fileID, fileKey: key, header: recovered.begin.header, size: size,
                                        kind: metadata.kind ?? .file, source: source, name: metadata.name, mimeType: metadata.mimeType)
            let expected = (try? FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: input))) ?? "builder failed"
            let found = (try? rig.storeFilesContain(SendRig.forms(of: key) + SendRig.forms(of: tokenData))) ?? ["scan failed"]
            captured.withValue {
                $0 = AtAnnounce(key: key, tokenText: tokenText, tokenRecord: record, object: object.obj, header: recovered.begin.header,
                                fileID: recovered.begin.fileID, expectedBody: expected, secretsFoundInFiles: found,
                                journalFiles: (try? rig.journalNames()) ?? [])
            }
        }
        return captured
    }

    // MARK: A whole transfer

    func testSendsAFileEndToEndAndTheBlobOnTheServerIsAOneShotEncryptionOfIt() async throws {
        let rig = try SendRig(self, realFlush: true)
        let source = GeneratedSource(size: SendTestSizes.threeParts)
        let metadata = FileV2SendMetadata(kind: .file, name: "report.pdf", mimeType: "application/pdf")
        let request = rig.makeRequest(source, id: "end-to-end", metadata: metadata)
        let atAnnounce = captureAtAnnounce(rig, id: "end-to-end", metadata: metadata, size: source.size)
        let collector = StateCollector()

        let result = await (try rig.makePipeline()).send(request, onState: collector.sink)

        XCTAssertEqual(result, .sentOk)
        let states = collector.states
        XCTAssertEqual(states.first, .preparing)
        XCTAssertEqual(states.last, .sentOk)
        let order = states.map { state -> String in
            switch state {
            case .preparing: return "preparing"
            case .sealing: return "sealing"
            case .uploading: return "uploading"
            case .completing: return "completing"
            case .announcing: return "announcing"
            case .sentOk: return "sentOk"
            default: return "other"
            }
        }
        XCTAssertEqual(order.filter { $0 != "uploading" }, ["preparing", "sealing", "completing", "announcing", "sentOk"])
        XCTAssertFalse(order.dropLast().contains("sentOk"), "sent is reported once, last")
        let progress = states.compactMap { state -> FileV2SendProgress? in
            if case .uploading(let value) = state { return value }
            return nil
        }
        XCTAssertEqual(progress.map { $0.partsDone }, [0, 1, 2, 3], "progress counts confirmed parts and ends at the total")
        XCTAssertEqual(progress.last?.bytesDone, progress.last?.bytesTotal)

        // The descriptor is what the library's builder writes from the same inputs, and the library's parser accepts it.
        let seen = atAnnounce.withValue { $0 }
        XCTAssertFalse(seen.expectedBody.isEmpty)
        XCTAssertEqual(rig.channel.announced.count, 1)
        let body = try XCTUnwrap(rig.channel.announced.first?.body)
        XCTAssertEqual(Array(body.utf8), Array(seen.expectedBody.utf8), "the descriptor equals the builder's output, byte for byte")
        XCTAssertTrue(body.hasPrefix(#"{"qa_file":2,"id":"#))
        guard case .descriptor(let descriptor) = FileV2Message.recognize(body) else { return XCTFail("not recognised as a descriptor") }
        XCTAssertEqual(descriptor.size, source.size)
        XCTAssertEqual(descriptor.name, "report.pdf")
        XCTAssertEqual(descriptor.source.via, .srv)
        XCTAssertEqual(descriptor.source.obj, seen.object, "the object as the server returned it")
        XCTAssertEqual(descriptor.source.token?.v, seen.tokenText, "the token as the server returned it")
        XCTAssertEqual(descriptor.source.token?.max, 30, "a 1:1 conversation asks for 30 uses")
        XCTAssertEqual(rig.channel.announced.first?.conversation, .direct(userID: "bob"))
        XCTAssertEqual(rig.channel.announced.first?.key, "end-to-end", "the chat can dedupe on the transfer id")
        XCTAssertEqual(seen.tokenRecord?.scope, "user")

        // The blob is a one-shot encryption of the source.
        try rig.assertBlobEqualsOneShot(descriptor: descriptor, source: source)

        // The server saw exactly: create, three parts, complete. No bulk delete, no listing.
        let ops = rig.fake.calls.map { $0.op }
        XCTAssertEqual(ops.filter { $0 == .create }.count, 1)
        XCTAssertEqual(ops.filter { $0 == .putPart }.count, 3)
        XCTAssertEqual(ops.filter { $0 == .complete }.count, 1)
        XCTAssertFalse(ops.contains(.deleteUnfinished))
        XCTAssertFalse(ops.contains(.listUnfinished))
        let blobLength = FileV2.headerLength + Int(descriptor.header.streamLength) + descriptor.header.totalChunks * FileV2.tagSize
        XCTAssertEqual(rig.telemetry.bytesUploaded, blobLength - FileV2.headerLength, "the counters add up to the blob")

        // While the transfer ran, no file of the store held the key or the token in any form; afterwards nothing is left at all.
        XCTAssertEqual(seen.secretsFoundInFiles, [])
        XCTAssertEqual(seen.journalFiles, ["end-to-end.lock", "end-to-end.qsj"], "the journal, and the (empty) file of the exclusive lock the run holds")
        try rig.assertNothingIsLeftBehind()

        // The nonce rule's ordering, over the whole log.
        XCTAssertEqual(SendEventAnalysis.putsBeforeTheirTagsAreDurable(rig.log.events, totalChunks: descriptor.header.totalChunks), [])
    }

    func testTheDescriptorOfASmallFileOpensTheBlobChunkByChunk() async throws {
        let rig = try SendRig(self)
        let source = GeneratedSource(size: 1_500_000)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source))
        XCTAssertEqual(result, .sentOk)
        let descriptor = try rig.lastDescriptor()
        let decryptor = try FileV2Decryptor(descriptor: descriptor)
        let blob = try XCTUnwrap(rig.storedBlob(obj: try XCTUnwrap(descriptor.source.obj), header: descriptor.header.bytes,
                                                blobLength: Int64(decryptor.blobLength)))
        try decryptor.verifySourceHeader(Data(blob.prefix(FileV2.headerLength)))
        var offset = FileV2.headerLength
        for index in 0..<decryptor.totalChunks {
            let length = decryptor.sealedChunkLength(index)
            let plain = try XCTUnwrap(try decryptor.openChunk(index: index, sealed: blob.subdata(in: offset..<(offset + length))))
            let real = min(FileV2.chunkSize, max(0, Int(source.size) - index * FileV2.chunkSize))
            XCTAssertEqual(plain.prefix(real), source.bytes(offset: UInt64(index * FileV2.chunkSize), length: real), "chunk \(index)")
            XCTAssertTrue(plain.dropFirst(real).allSatisfy { $0 == 0 }, "the padding is zero")
            offset += length
        }
    }

    func testASourceOfOneByteIsASingleChunkAndASinglePart() async throws {
        let rig = try SendRig(self)
        let source = GeneratedSource(size: 1)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source))
        XCTAssertEqual(result, .sentOk)
        XCTAssertEqual(rig.fake.calls.filter { $0.op == .putPart }.count, 1)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: source)
    }

    func testAFileSourceIsReadFromDiskAChunkAtATime() async throws {
        let rig = try SendRig(self)
        let generated = GeneratedSource(size: SendTestSizes.oneChunkOver)
        let url = rig.root.appendingPathComponent("picked.bin")
        try generated.write(to: url)
        let request = FileV2SendRequest(transferID: "from-disk", source: FileV2FileSource(url: url), conversation: .direct(userID: "bob"),
                                        metadata: FileV2SendMetadata(kind: .file, name: "picked.bin"))
        let result = await (try rig.makePipeline()).send(request)
        XCTAssertEqual(result, .sentOk)
        try rig.assertBlobEqualsOneShot(descriptor: try rig.lastDescriptor(), source: generated)
    }

    func testAGroupTransferAsksForTheGroupScopeToken() async throws {
        let rig = try SendRig(self)
        rig.fake.addGroupMember(group: "team-group-1", user: "alice")
        let source = GeneratedSource(size: 600_000)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, conversation: .group(groupID: "team-group-1")))
        XCTAssertEqual(result, .sentOk)
        let descriptor = try rig.lastDescriptor()
        XCTAssertEqual(rig.channel.announced.last?.conversation, .group(groupID: "team-group-1"))
        XCTAssertEqual(descriptor.source.token?.max, 10, "a group token uses the server's default budget per member")
        // The fake serves the group token to a member and refuses it to anyone else.
        rig.fake.addGroupMember(group: "team-group-1", user: "carol")
        let token = try XCTUnwrap(descriptor.source.token)
        let asMember = try await rig.fake.asAccount("carol").fetchRange(
            obj: try XCTUnwrap(descriptor.source.obj), from: 0, toInclusive: 63,
            token: FileV2DownloadAuth(v: token.v, expMs: token.exp, max: Int(token.max)), waitSeconds: 0)
        XCTAssertEqual(asMember.body, descriptor.header.bytes)
        do {
            _ = try await rig.fake.asAccount("mallory").fetchRange(
                obj: try XCTUnwrap(descriptor.source.obj), from: 0, toInclusive: 63,
                token: FileV2DownloadAuth(v: token.v, expMs: token.exp, max: Int(token.max)), waitSeconds: 0)
            XCTFail("a non-member must not read")
        } catch let error as FileV2ServerError {
            XCTAssertEqual(error.status, 403)
        }
    }

    func testMetadataTravelsIntoTheDescriptor() async throws {
        let rig = try SendRig(self)
        let source = GeneratedSource(size: 700_000)
        let metadata = FileV2SendMetadata(kind: .voice, name: "memo.m4a", mimeType: "audio/mp4",
                                          media: FileV2SendMetadata.Media(dur: 5234, wave: [1, 2, 3]), preview: Data([1, 2, 3, 4]),
                                          ex: 60, xp: 0)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(source, metadata: metadata))
        XCTAssertEqual(result, .sentOk)
        let descriptor = try rig.lastDescriptor()
        XCTAssertEqual(descriptor.kind, .voice)
        XCTAssertEqual(descriptor.mimeType, "audio/mp4")
        XCTAssertEqual(descriptor.media, FileV2Descriptor.Media(dur: 5234, wave: [1, 2, 3]))
        XCTAssertEqual(descriptor.preview, Data([1, 2, 3, 4]))
        XCTAssertEqual(descriptor.ex, 60)
        XCTAssertEqual(descriptor.xp, 0)
    }

    // MARK: Preflight: nothing is uploaded, generated or stored

    private func assertNothingHappened(_ rig: SendRig, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(rig.fake.calls.count, 0, "the server was not called", file: file, line: line)
        XCTAssertEqual(rig.fake.objectCount, 0, file: file, line: line)
        try rig.assertNothingIsLeftBehind(file: file, line: line)
        XCTAssertTrue(rig.channel.announced.isEmpty, file: file, line: line)
    }

    func testAnEmptySourceIsRefusedBeforeAnything() async throws {
        let rig = try SendRig(self)
        let collector = StateCollector()
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 0)), onState: collector.sink)
        XCTAssertEqual(result, .failed(FileV2SendFailure(.emptySource)))
        XCTAssertEqual(collector.states.last, result)
        try assertNothingHappened(rig)
    }

    func testASourceOverFiveGiBIsRefusedBeforeAnything() async throws {
        let rig = try SendRig(self)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: FileV2.maxSize + 1)))
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceTooLarge)))
        try assertNothingHappened(rig)
    }

    func testASourceThatCannotBeReadIsRefusedBeforeAnything() async throws {
        let rig = try SendRig(self)
        let missing = FileV2SendRequest(source: FileV2FileSource(url: rig.root.appendingPathComponent("not-there.bin")),
                                        conversation: .direct(userID: "bob"), metadata: FileV2SendMetadata(kind: .file))
        let result = await (try rig.makePipeline()).send(missing)
        XCTAssertEqual(result, .failed(FileV2SendFailure(.sourceUnavailable)))
        try assertNothingHappened(rig)
    }

    func testIfTheChatCannotCarryADescriptorNothingIsSent() async throws {
        let rig = try SendRig(self)
        rig.channel.setCanCarry(false)
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 2_000_000)))
        XCTAssertEqual(result, .failed(FileV2SendFailure(.channelUnavailable)))
        XCTAssertEqual(rig.channel.askedCount, 1)
        try assertNothingHappened(rig)
    }

    func testADescriptorThatCannotFitIn8KiBIsRefusedBeforeTheUpload() async throws {
        let rig = try SendRig(self)
        // Control characters escape to 6 bytes each, so a 255-byte name is 1530 bytes of JSON and a 128-byte media type 768; with a 2 KiB
        // preview and a long waveform the descriptor passes 8 KiB, and the builder drops the waveform, then the preview, until it fits ...
        let long = String(repeating: "\u{1}", count: 255)
        var metadata = FileV2SendMetadata(kind: .file, name: long, mimeType: String(repeating: "\u{2}", count: 128))
        metadata.preview = Data(repeating: 7, count: 2048)
        metadata.media = FileV2SendMetadata.Media(wave: Array(repeating: 123_456_789_012, count: 400))
        let fits = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 500_000), metadata: metadata))
        XCTAssertEqual(fits, .sentOk, "the waveform and the preview were dropped to make it fit")
        XCTAssertLessThan(try XCTUnwrap(rig.channel.announced.last?.body.utf8.count), FileV2.maxDescriptorBytes)
        // ... and a kind this build does not know (a journal of another version) is a bad request before anything happens.
        var unknown = FileV2SendMetadata(kind: .file)
        unknown.kindRawValue = "hologram"
        let rig2 = try SendRig(self)
        let refused = await (try rig2.makePipeline()).send(rig2.makeRequest(GeneratedSource(size: 500_000), metadata: unknown))
        XCTAssertEqual(refused, .failed(FileV2SendFailure(.badRequest)))
        try assertNothingHappened(rig2)
    }

    func testATransferIdIsValidatedAndOneThatIsRunningIsRefused() async throws {
        let rig = try SendRig(self)
        let pipeline = try rig.makePipeline()
        let bad = await pipeline.send(rig.makeRequest(GeneratedSource(size: 1000), id: "../escape"))
        XCTAssertEqual(bad, .failed(FileV2SendFailure(.badRequest)))
        let missing = await pipeline.resume(transferID: "NOT valid")
        XCTAssertEqual(missing, .failed(FileV2SendFailure(.badRequest)))

        // A second send under the id of a running one is refused.
        rig.channel.setHangs(true)
        let source = GeneratedSource(size: 600_000)
        let first = Task { await pipeline.send(rig.makeRequest(source, id: "same-id")) }
        try await pollUntilTrue { !rig.channel.announced.isEmpty }
        let second = await pipeline.send(rig.makeRequest(GeneratedSource(size: 600_000), id: "same-id"))
        XCTAssertEqual(second, .failed(FileV2SendFailure(.alreadyRunning)))
        let resumeWhileRunning = await pipeline.resume(transferID: "same-id")
        XCTAssertEqual(resumeWhileRunning, .failed(FileV2SendFailure(.alreadyRunning)))
        first.cancel()
        _ = await first.value
    }

    func testAnIdThatAlreadyHasStateIsRefusedAndTheStateIsLeftAlone() async throws {
        let rig = try SendRig(self)
        rig.channel.setOutcomes([.unavailable])
        let pipeline = try rig.makePipeline()
        let first = await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000), id: "taken"))
        XCTAssertEqual(first, .failed(FileV2SendFailure(transfer: .announceNotSent)))
        let beforeRefusal = try rig.journalNames()
        let again = await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000), id: "taken"))
        XCTAssertEqual(again, .failed(FileV2SendFailure(.alreadyRunning)))
        XCTAssertEqual(try rig.journalNames(), beforeRefusal)
        XCTAssertEqual(rig.wrapper.count, 2, "only the first transfer's key and token: the refused one wrapped nothing that stayed")
    }

    // MARK: Nothing secret is ever printed

    func testNothingThePipelinePrintsContainsAnIdAKeyATokenAPathOrAName() async throws {
        let rig = try SendRig(self)
        rig.channel.setOutcomes([.unavailable])
        let source = GeneratedSource(size: 700_000, locator: "/private/var/mobile/Containers/Data/holiday.mov")
        let request = rig.makeRequest(source, id: "11111111-2222-3333-4444-555555555555",
                                      conversation: .direct(userID: "user-bob-private"),
                                      metadata: FileV2SendMetadata(kind: .video, name: "holiday.mov", mimeType: "video/quicktime"))
        let pipeline = try rig.makePipeline()
        let collector = StateCollector()
        let result = await pipeline.send(request, onState: collector.sink)
        let list = await pipeline.listResumable()
        var pieces: [Any] = [request, result, pipeline.diagnostics, FileV2SendConfiguration().partIdleTimeoutMs] + collector.states.map { $0 as Any }
        pieces.append(contentsOf: list.map { $0 as Any })
        pieces.append(FileV2FileSource(url: URL(fileURLWithPath: "/private/var/mobile/Containers/Data/holiday.mov")))
        pieces.append(try XCTUnwrap(try rig.makeStore().load(request.transferID)))
        let secrets = (try rig.wrapper.allBlobs()).compactMap { try? rig.wrapper.unwrap($0) }
        XCTAssertEqual(secrets.count, 2, "the key and the token are in the secure store")
        var forbidden = ["11111111-2222-3333", "user-bob-private", "holiday", "/private", "Containers"]
        for secret in secrets { forbidden.append(contentsOf: SendRig.forms(of: secret).map { String(decoding: $0, as: UTF8.self) }) }
        for piece in pieces {
            let text = SendStoreFixtures.printed(piece)
            for word in forbidden where !word.isEmpty {
                XCTAssertFalse(text.contains(word), "\(type(of: piece)) prints \(word.prefix(10))...")
            }
        }
        XCTAssertTrue(SendStoreFixtures.printed(request).contains("11111111"))
    }

    // MARK: A wrapper that cannot wrap

    func testAKeychainThatRefusesTheKeyFailsTheSendBeforeAnyUpload() async throws {
        let rig = try SendRig(self)
        rig.wrapper.failNextWrapCall()
        let result = await (try rig.makePipeline()).send(rig.makeRequest(GeneratedSource(size: 700_000)))
        XCTAssertEqual(result, .failed(FileV2SendFailure(.storage)))
        XCTAssertEqual(rig.fake.calls.count, 0)
        try rig.assertNothingIsLeftBehind()
    }

    func testListResumableShowsATransferThatKeptItsStateAndNothingElse() async throws {
        let rig = try SendRig(self)
        rig.channel.setOutcomes([.unavailable])
        let pipeline = try rig.makePipeline()
        _ = await pipeline.send(rig.makeRequest(GeneratedSource(size: 700_000), id: "pending-announce",
                                                conversation: .direct(userID: "bob")))
        let list = await (try rig.makePipeline()).listResumable()
        XCTAssertEqual(list.map { $0.transferID }, ["pending-announce"])
        XCTAssertEqual(list.first?.phase, .announcePending)
        XCTAssertEqual(list.first?.conversation, .direct(userID: "bob"))
        XCTAssertEqual(list.first?.isRunning, false)
        XCTAssertFalse(SendStoreFixtures.printed(try XCTUnwrap(list.first)).contains("bob"))
    }
}

// MARK: Helpers

extension XCTestCase {
    /// Polls (real time) until `condition` holds.
    func pollUntilTrue(timeout: TimeInterval = 20, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

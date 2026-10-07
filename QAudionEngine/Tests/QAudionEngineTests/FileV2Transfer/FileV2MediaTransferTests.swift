import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux (the scratch harness)
#endif
@testable import QAudionEngine

/// Images, voice notes, videos and avatars through the sender and the receiver, against the in-memory server that the
/// conformance transcript holds to the real one: the kind, the display hints, the tiny preview and the thumbnail of the
/// descriptor, the group token, and what a failure leaves on the server.
final class FileV2MediaTransferTests: XCTestCase {

    private var directory: URL!
    private let noSleep: @Sendable (Int64) async throws -> Void = { _ in }
    private let group = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    override func setUpWithError() throws {
        directory = try FileV2TestSupport.makeTempDirectory(for: self)
    }

    private func makeSource(size: UInt64, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileV2TestSupport.writePlaintextFile(size: size, to: url)
        return url
    }

    private func sender(_ server: FileV2Server) -> FileV2Sender { FileV2Sender(server: server, sleep: noSleep) }

    private func receiver(_ server: FileV2Server) -> FileV2Receiver {
        FileV2Receiver(server: server, sleep: noSleep, freeSpace: { _ in nil })
    }

    private final class BodyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var body: String?
        func set(_ text: String) { lock.lock(); body = text; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return body }
    }

    /// The body the sender handed to the chat, and the descriptor the receiver's side of the chat reads from it.
    private func sendBody(_ request: FileV2Sender.Request, from server: FileV2Server) async throws -> (body: String, descriptor: FileV2Descriptor) {
        let box = BodyBox()
        try await sender(server).send(request) { body in box.set(body) }
        let body = try XCTUnwrap(box.value)
        return (body, try XCTUnwrap(FileV2ChatBody.descriptor(ofBody: body)))
    }

    private func send(_ request: FileV2Sender.Request, from server: FileV2Server) async throws -> FileV2Descriptor {
        try await sendBody(request, from: server).descriptor
    }

    private func download(_ descriptor: FileV2Descriptor, as server: FileV2Server, to name: String) async throws -> URL {
        let destination = directory.appendingPathComponent(name)
        try await receiver(server).download(descriptor, to: destination)
        return destination
    }

    // MARK: An image with its thumbnail

    func test_anImageWithAThumbnail_arrivesWithItsHintsItsPreviewAndItsThumbnail() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let image = try makeSource(size: 700_000, name: "image.jpg")
        let thumb = try makeSource(size: 9_000, name: "thumb.jpg")
        let preview = Data((0..<300).map { UInt8($0 % 251) })
        let request = FileV2Sender.Request(
            sourceURL: image, kind: .image, name: "IMG-1.jpg", mimeType: "image/jpeg", audience: .recipient("bob"),
            media: FileV2MediaHints.media(width: 2048, height: 1536), preview: preview,
            thumbnail: FileV2Sender.Thumbnail(sourceURL: thumb))
        let (body, descriptor) = try await sendBody(request, from: alice)

        XCTAssertEqual(descriptor.kind, .image)
        XCTAssertEqual(descriptor.mimeType, "image/jpeg")
        XCTAssertEqual(descriptor.media, FileV2Descriptor.Media(w: 2048, h: 1536))
        XCTAssertEqual(descriptor.preview, preview)
        XCTAssertEqual(descriptor.thumbnailStatus, .valid)
        let thumbnail = try XCTUnwrap(descriptor.thumbnail)
        XCTAssertEqual(thumbnail.kind, .thumb)
        XCTAssertNotEqual(thumbnail.fileID, descriptor.fileID, "a thumbnail is another file")
        XCTAssertNotEqual(thumbnail.source.obj, descriptor.source.obj)
        XCTAssertEqual(alice.objectCount, 2)

        let bob = alice.asAccount("bob")
        let receivedThumb = try await download(thumbnail, as: bob, to: "thumb.out")
        let receivedImage = try await download(descriptor, as: bob, to: "image.out")
        XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: receivedThumb), try FileV2TestSupport.sha256Hex(ofFile: thumb))
        XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: receivedImage), try FileV2TestSupport.sha256Hex(ofFile: image))

        // the chat sees one image and a label, never the body
        let chat = try XCTUnwrap(FileV2ChatBody.bubbleInfo(for: Self.row(body: body)))
        XCTAssertEqual(chat.kind, "image")
        XCTAssertTrue(chat.hasThumbnail)
        XCTAssertEqual(chat.hints, FileV2MediaHints(width: 2048, height: 1536))
        XCTAssertEqual(chat.preview, preview)
        XCTAssertEqual(chat.previewText, FileV2ChatBody.kindLabelText(.image))
    }

    private static func row(body: String) -> Message {
        Message(id: UUID(), conversationId: UUID(), direction: .incoming, plaintext: body, sentAt: Date(), deliveredAt: nil,
                readAt: nil, status: .delivered)
    }

    func test_aThumbnailThatIsEmptyOrTooLargeIsLeftOut_andTheFileStillGoes() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let image = try makeSource(size: 50_000, name: "image.jpg")
        let empty = try makeSource(size: 0, name: "empty.jpg")
        let big = try makeSource(size: UInt64(FileV2Sender.maxThumbnailBytes) + 1, name: "big.jpg")
        for thumbnail in [empty, big, directory.appendingPathComponent("missing.jpg")] {
            let request = FileV2Sender.Request(
                sourceURL: image, kind: .image, name: "a.jpg", mimeType: "image/jpeg", audience: .recipient("bob"),
                thumbnail: FileV2Sender.Thumbnail(sourceURL: thumbnail))
            let descriptor = try await send(request, from: alice)
            XCTAssertEqual(descriptor.thumbnailStatus, .absent)
            XCTAssertNil(descriptor.thumbnail)
        }
        XCTAssertEqual(alice.objectCount, 3, "one object per image, none for a thumbnail that was not sent")
    }

    func test_aThumbnailThatFailsToUpload_costsNothing_andTheFileGoesWithoutIt() async throws {
        let alice = FakeFileV2Server(account: "alice")
        // the thumbnail is created first: five failed tries of that create spend the retries of the thumbnail only
        alice.injectFailure(.create, error: URLError(.notConnectedToInternet), times: 5)
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: 50_000, name: "image.jpg"), kind: .image, name: "a.jpg", mimeType: "image/jpeg",
            audience: .recipient("bob"), thumbnail: FileV2Sender.Thumbnail(sourceURL: try makeSource(size: 5_000, name: "t.jpg")))
        let descriptor = try await send(request, from: alice)
        XCTAssertEqual(descriptor.thumbnailStatus, .absent)
        XCTAssertEqual(alice.objectCount, 1)
        let received = try await download(descriptor, as: alice.asAccount("bob"), to: "image.out")
        XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: received), try FileV2TestSupport.sha256Hex(ofFile: request.sourceURL))
    }

    func test_ifTheChatRefusesTheDescriptor_theFileAndItsThumbnailAreBothDeleted() async throws {
        struct Refused: Error {}
        let alice = FakeFileV2Server(account: "alice")
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: 50_000, name: "image.jpg"), kind: .image, name: "a.jpg", mimeType: "image/jpeg",
            audience: .recipient("bob"), thumbnail: FileV2Sender.Thumbnail(sourceURL: try makeSource(size: 5_000, name: "t.jpg")))
        do {
            try await sender(alice).send(request) { _ in throw Refused() }
            XCTFail("a refused descriptor must fail the send")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .transfer(.announceNotSent))
        }
        XCTAssertEqual(alice.objectCount, 0)
    }

    func test_ifTheFileFailsAfterTheThumbnailWasUploaded_theThumbnailIsDeletedToo() async throws {
        // the file has two parts, the thumbnail one: only part 1 can fail, so the thumbnail is complete when the file gives up
        let alice = FakeFileV2Server(account: "alice")
        alice.injectFailure(.putPart, error: URLError(.networkConnectionLost), times: 100, part: 1)
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: UInt64(FileV2.chunkSize) * 9, name: "big.jpg"), kind: .image, name: "a.jpg",
            mimeType: "image/jpeg", audience: .recipient("carol"),
            thumbnail: FileV2Sender.Thumbnail(sourceURL: try makeSource(size: 5_000, name: "t.jpg")))
        do {
            try await sender(alice).send(request) { _ in XCTFail("no descriptor without an upload") }
            XCTFail("the part cannot be uploaded")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .transfer(.network))
        }
        XCTAssertTrue(alice.calls.contains { $0.op == .complete }, "the thumbnail had been completed")
        XCTAssertEqual(alice.objectCount, 0, "neither the file nor its thumbnail stays on the server")
    }

    // MARK: A voice note, a video, an avatar

    func test_aVoiceNoteCarriesItsDuration() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: 40_000, name: "voice.m4a"), kind: .voice, name: "nota.m4a", mimeType: "audio/mp4",
            audience: .recipient("bob"), media: FileV2MediaHints.media(durationMs: 4200, wave: [3, 9, 200, 40]))
        let descriptor = try await send(request, from: alice)
        XCTAssertEqual(descriptor.kind, .voice)
        XCTAssertEqual(descriptor.media?.dur, 4200)
        XCTAssertEqual(descriptor.media?.wave, [3, 9, 200, 40])
        XCTAssertEqual(FileV2MediaHints(media: descriptor.media).durationMs, 4200)
        XCTAssertEqual(alice.objectCount, 1, "a voice note has no thumbnail")
    }

    func test_aVideoWithAThumbnail_isAFileOfItsOwnKindAndItsThumbnailAnotherOne() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let video = try makeSource(size: UInt64(FileV2.chunkSize) * 3 + 99, name: "clip.mp4")
        let request = FileV2Sender.Request(
            sourceURL: video, kind: .video, name: "clip.mp4", mimeType: "video/mp4", audience: .recipient("bob"),
            media: FileV2MediaHints.media(width: 1920, height: 1080, durationMs: 12_000),
            thumbnail: FileV2Sender.Thumbnail(sourceURL: try makeSource(size: 20_000, name: "frame.jpg")))
        let descriptor = try await send(request, from: alice)
        XCTAssertEqual(descriptor.kind, .video)
        XCTAssertEqual(descriptor.media, FileV2Descriptor.Media(w: 1920, h: 1080, dur: 12_000))
        XCTAssertEqual(descriptor.thumbnail?.kind, .thumb)
        XCTAssertFalse(FileV2AutoDownloadPolicy.isAutomatic(kind: descriptor.kind, size: descriptor.size))
        let received = try await download(descriptor, as: alice.asAccount("bob"), to: "clip.out")
        XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: received), try FileV2TestSupport.sha256Hex(ofFile: video))
    }

    func test_anAvatarIsAFileOfKindAvatar() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: 60_000, name: "self.jpg"), kind: .avatar, name: nil, mimeType: "image/jpeg",
            audience: .recipient("bob"))
        let descriptor = try await send(request, from: alice)
        XCTAssertEqual(descriptor.kind, .avatar)
        XCTAssertNil(descriptor.name)
        XCTAssertTrue(FileV2AutoDownloadPolicy.isAutomatic(kind: descriptor.kind, size: descriptor.size))
    }

    // MARK: A group

    func test_oneGroupTokenServesEveryMember_andNobodyElse() async throws {
        let alice = FakeFileV2Server(account: "alice")
        for member in ["alice", "bob", "carol"] { alice.addGroupMember(group: group, user: member) }
        let source = try makeSource(size: 100_000, name: "doc.pdf")
        let audience = try XCTUnwrap(FileV2Audience.forGroup(group))
        let request = FileV2Sender.Request(sourceURL: source, kind: .file, name: "doc.pdf", mimeType: "application/pdf",
                                           audience: audience)
        let descriptor = try await send(request, from: alice)
        XCTAssertEqual(alice.objectCount, 1)

        for member in ["bob", "carol"] {
            let received = try await download(descriptor, as: alice.asAccount(member), to: "\(member).out")
            XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: received), try FileV2TestSupport.sha256Hex(ofFile: source))
        }
        do {
            _ = try await download(descriptor, as: alice.asAccount("mallory"), to: "mallory.out")
            XCTFail("an account that is not in the group must not download")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .unavailable)
        }
    }

    func test_aMemberRemovedFromTheGroupLosesTheFileAtOnce() async throws {
        let alice = FakeFileV2Server(account: "alice")
        for member in ["alice", "bob"] { alice.addGroupMember(group: group, user: member) }
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: 30_000, name: "doc.pdf"), kind: .file, name: "doc.pdf", mimeType: nil,
            audience: try XCTUnwrap(FileV2Audience.forGroup(group)))
        let descriptor = try await send(request, from: alice)
        alice.removeGroupMember(group: group, user: "bob")
        do {
            _ = try await download(descriptor, as: alice.asAccount("bob"), to: "bob.out")
            XCTFail("a removed member must not download")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .unavailable)
        }
    }

    func test_aGroupTheSenderIsNotAMemberOfCannotBeSentTo() async throws {
        let alice = FakeFileV2Server(account: "alice")
        alice.addGroupMember(group: group, user: "bob")
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: 30_000, name: "doc.pdf"), kind: .file, name: "doc.pdf", mimeType: nil,
            audience: try XCTUnwrap(FileV2Audience.forGroup(group)))
        do {
            try await sender(alice).send(request) { _ in XCTFail("no descriptor without an upload") }
            XCTFail("the server refuses a group token to a non-member")
        } catch is FileV2Failure {
        }
        XCTAssertEqual(alice.objectCount, 0)
    }

    // MARK: Refused before anything is created

    func test_aRequestThatCannotBeRight_failsBeforeAnyRequest() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let source = try makeSource(size: 1_000, name: "a.bin")
        let thumbKind = FileV2Sender.Request(sourceURL: source, kind: .thumb, name: nil, mimeType: nil, audience: .recipient("bob"))
        let badGroup = FileV2Sender.Request(sourceURL: source, kind: .file, name: nil, mimeType: nil,
                                            audience: .group("not-a-group"))
        let noRecipient = FileV2Sender.Request(sourceURL: source, kind: .file, name: nil, mimeType: nil, audience: .recipient(""))
        for request in [thumbKind, badGroup, noRecipient] {
            do {
                try await sender(alice).send(request) { _ in XCTFail("nothing may be announced") }
                XCTFail("the request is refused")
            } catch let failure as FileV2Failure {
                XCTAssertEqual(failure.reason, .transfer(.badRequest))
            }
        }
        XCTAssertTrue(alice.calls.isEmpty)
    }

    func test_aPreviewOverTheLimitIsNotSent_andDoesNotFailTheSend() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let request = FileV2Sender.Request(
            sourceURL: try makeSource(size: 10_000, name: "a.jpg"), kind: .image, name: "a.jpg", mimeType: "image/jpeg",
            audience: .recipient("bob"), preview: Data(repeating: 7, count: FileV2.maxPreviewBytes + 1))
        let descriptor = try await send(request, from: alice)
        XCTAssertNil(descriptor.preview)
    }
}

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLError lives here on Linux (the scratch harness)
#endif
@testable import QAudionEngine

/// The minimal document transfer of the chat, end to end on the pure pieces: the sender (`FileV2Sender`) uploads to the
/// in-memory server that the conformance transcript holds to the real one, the descriptor it hands to the chat is read back
/// by the receiver's side of the chat (`FileV2ChatBody`) and the receiver (`FileV2Receiver`) downloads, verifies and decrypts it.
final class FileV2DocumentTransferTests: XCTestCase {

    private var directory: URL!
    private let noSleep: @Sendable (Int64) async throws -> Void = { _ in }

    override func setUpWithError() throws {
        directory = try FileV2TestSupport.makeTempDirectory(for: self)
    }

    private func makeSource(size: UInt64, name: String = "source.bin") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileV2TestSupport.writePlaintextFile(size: size, to: url)
        return url
    }

    private func sender(_ server: FileV2Server) -> FileV2Sender {
        FileV2Sender(server: server, sleep: noSleep)
    }

    private func receiver(_ server: FileV2Server, freeSpace: @escaping @Sendable (URL) -> Int64? = { _ in nil }) -> FileV2Receiver {
        FileV2Receiver(server: server, sleep: noSleep, freeSpace: freeSpace)
    }

    /// Sends `source` as alice to bob and returns the body the sender handed to the chat.
    @discardableResult
    private func send(_ source: URL, name: String? = "relazione.pdf", from server: FakeFileV2Server,
                      progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws -> String {
        let box = BodyBox()
        let request = FileV2Sender.Request(sourceURL: source, name: name, mimeType: "application/pdf", recipientUserID: "bob")
        try await sender(server).send(request, progress: progress) { body in box.set(body) }
        return try XCTUnwrap(box.value)
    }

    private final class BodyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var body: String?
        func set(_ text: String) { lock.lock(); body = text; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return body }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func add(_ value: Int64) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func descriptor(of body: String) throws -> FileV2Descriptor {
        try XCTUnwrap(FileV2ChatBody.descriptor(ofBody: body))
    }

    // MARK: The round trip

    func test_aFileGoesFromAliceToBob_andIsTheSameFile() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let source = try makeSource(size: 3 * 1024 * 1024 + 5)
        let body = try await send(source, from: alice)

        // the chat sees a file, never the body, and the descriptor says what was sent
        let info = try XCTUnwrap(FileV2ChatBody.classify(text: body).displayText)
        XCTAssertEqual(info, "📎 relazione.pdf")
        let descriptor = try descriptor(of: body)
        XCTAssertEqual(descriptor.size, 3 * 1024 * 1024 + 5)
        XCTAssertEqual(descriptor.source.via, .srv)
        XCTAssertEqual(alice.objectCount, 1)

        let destination = directory.appendingPathComponent("received.bin")
        try await receiver(alice.asAccount("bob")).download(descriptor, to: destination)
        XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: destination), try FileV2TestSupport.sha256Hex(ofFile: source))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? UInt64,
                       3 * 1024 * 1024 + 5)
    }

    func test_aFileOfSeveralParts_goesThroughAndReportsMonotonicProgress() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let size = UInt64(8 * FileV2.chunkSize) + 1234             // two parts
        let source = try makeSource(size: size)
        let up = ProgressLog()
        let body = try await send(source, from: alice) { done, total in up.add(done); XCTAssertGreaterThan(total, 0) }
        XCTAssertEqual(up.all, up.all.sorted())
        let blobLength = Int64(try FileV2Encryptor.makeNew(plaintextSize: size).blobLength)
        XCTAssertEqual(up.all.last, blobLength)

        let down = ProgressLog()
        let destination = directory.appendingPathComponent("received.bin")
        try await receiver(alice.asAccount("bob")).download(try descriptor(of: body), to: destination) { done, _ in down.add(done) }
        XCTAssertEqual(down.all, down.all.sorted())
        XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: destination), try FileV2TestSupport.sha256Hex(ofFile: source))
    }

    func test_theDescriptorOnlyOpensForItsRecipient() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let body = try await send(try makeSource(size: 100_000), from: alice)
        let destination = directory.appendingPathComponent("stolen.bin")
        do {
            try await receiver(alice.asAccount("mallory")).download(try descriptor(of: body), to: destination)
            XCTFail("another account must not be able to download")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .unavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: The sender's failures

    func test_ifTheChatRefusesTheDescriptor_theUploadIsDeletedAndNothingWasAnnounced() async throws {
        struct Refused: Error {}
        let alice = FakeFileV2Server(account: "alice")
        let request = FileV2Sender.Request(sourceURL: try makeSource(size: 50_000), name: "x.pdf", mimeType: nil, recipientUserID: "bob")
        do {
            try await sender(alice).send(request) { _ in throw Refused() }
            XCTFail("a refused descriptor must fail the send")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .transfer(.announceNotSent))
        }
        XCTAssertEqual(alice.objectCount, 0)
    }

    func test_withoutTheFilesEntitlement_nothingIsCreated() async throws {
        let alice = FakeFileV2Server(account: "alice")
        alice.revokeEntitlement("alice")
        let request = FileV2Sender.Request(sourceURL: try makeSource(size: 50_000), name: "x.pdf", mimeType: nil, recipientUserID: "bob")
        do {
            try await sender(alice).send(request) { _ in XCTFail("no descriptor without an upload") }
            XCTFail("402 must fail the send")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .transfer(.entitlement))
            XCTAssertEqual(failure.server?.status, 402)
        }
        XCTAssertEqual(alice.objectCount, 0)
    }

    func test_anEmptyOrMissingFile_failsBeforeAnyRequest() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let empty = try makeSource(size: 0, name: "empty.bin")
        let request = FileV2Sender.Request(sourceURL: empty, name: "empty.bin", mimeType: nil, recipientUserID: "bob")
        do {
            try await sender(alice).send(request) { _ in }
            XCTFail("an empty file cannot be sent")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .emptyFile)
        }
        let missing = FileV2Sender.Request(sourceURL: directory.appendingPathComponent("nope.bin"), name: "nope.bin",
                                           mimeType: nil, recipientUserID: "bob")
        do {
            try await sender(alice).send(missing) { _ in }
            XCTFail("a missing file cannot be sent")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .unreadable)
        }
        XCTAssertTrue(alice.calls.isEmpty)
    }

    func test_aPartThatFailsOnceIsSentAgainWithTheSameBytes() async throws {
        let alice = FakeFileV2Server(account: "alice")
        alice.injectFailure(.putPart, error: URLError(.networkConnectionLost), times: 2, part: 0, when: .afterEffect)
        let source = try makeSource(size: 200_000)
        let body = try await send(source, from: alice)
        let destination = directory.appendingPathComponent("received.bin")
        try await receiver(alice.asAccount("bob")).download(try descriptor(of: body), to: destination)
        XCTAssertEqual(try FileV2TestSupport.sha256Hex(ofFile: destination), try FileV2TestSupport.sha256Hex(ofFile: source))
        XCTAssertEqual(alice.calls.filter { $0.op == .putPart }.count, 3)
    }

    // MARK: The receiver's failures

    func test_aTamperedChunk_isRequestedAgainThreeTimes_thenFails_andLeavesNothingOnDisk() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let body = try await send(try makeSource(size: 100_000), from: alice)
        let tampering = TamperingServer(base: alice.asAccount("bob"))
        let destination = directory.appendingPathComponent("tampered.bin")
        do {
            try await receiver(tampering).download(try descriptor(of: body), to: destination)
            XCTFail("a chunk that does not verify must fail the download")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .format("chunk_auth"))
        }
        XCTAssertEqual(tampering.partFetches, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_aDescriptorWithoutAToken_cannotBeDownloaded() async throws {
        let encryptor = try FileV2Encryptor.makeNew(plaintextSize: 10)
        let source = FileV2Descriptor.Source(via: .srv, obj: "0a1b2c3d-0000-4000-8000-123456789abc", token: nil)
        let body = try FileV2DescriptorBuilder.build(FileV2DescriptorInput(
            file: FileV2FileInput(encryptor: encryptor, kind: .file, source: source, name: "x")))
        let bob = FakeFileV2Server(account: "bob")
        let destination = directory.appendingPathComponent("x.bin")
        do {
            try await receiver(bob).download(try descriptor(of: body), to: destination)
            XCTFail("no token, no download")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .unavailable)
        }
        XCTAssertTrue(bob.calls.isEmpty)
    }

    func test_withoutRoomOnTheDevice_nothingIsRequested() async throws {
        let alice = FakeFileV2Server(account: "alice")
        let body = try await send(try makeSource(size: 100_000), from: alice)
        let bob = alice.asAccount("bob")
        let destination = directory.appendingPathComponent("full.bin")
        do {
            try await receiver(bob, freeSpace: { _ in 0 }).download(try descriptor(of: body), to: destination)
            XCTFail("a full device must fail the download")
        } catch let failure as FileV2Failure {
            XCTAssertEqual(failure.reason, .transfer(.noSpace))
        }
        XCTAssertFalse(bob.calls.contains { $0.op == .fetchRange })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

/// A server that flips one bit of every part it serves (the header range is left alone), to prove that a chunk that does not
/// verify is never written and is asked for at most three times.
private final class TamperingServer: FileV2Server, @unchecked Sendable {
    private let base: FileV2Server
    private let lock = NSLock()
    private var fetches = 0

    init(base: FileV2Server) { self.base = base }

    var partFetches: Int { lock.lock(); defer { lock.unlock() }; return fetches }

    func fetchRange(obj: String, from: Int64, toInclusive: Int64, token: FileV2DownloadAuth?,
                    waitSeconds: Int) async throws -> FileV2RangeResult {
        let result = try await base.fetchRange(obj: obj, from: from, toInclusive: toInclusive, token: token, waitSeconds: waitSeconds)
        guard from >= Int64(FileV2.headerLength), !result.body.isEmpty else { return result }
        lock.lock(); fetches += 1; lock.unlock()
        var bytes = result.body
        bytes[bytes.startIndex] ^= 0x01
        return FileV2RangeResult(body: bytes, totalLength: result.totalLength)
    }

    func create(_ request: FileV2CreateRequest) async throws -> FileV2Created { try await base.create(request) }
    func putPart(obj: String, part: Int, body: Data, sha256: Data) async throws -> FileV2PutResult {
        try await base.putPart(obj: obj, part: part, body: body, sha256: sha256)
    }
    func partsMap(obj: String) async throws -> FileV2PartsMap { try await base.partsMap(obj: obj) }
    func complete(obj: String) async throws { try await base.complete(obj: obj) }
    func delete(obj: String) async throws { try await base.delete(obj: obj) }
    func issueToken(obj: String, scope: FileV2TokenRequest) async throws -> FileV2IssuedToken {
        try await base.issueToken(obj: obj, scope: scope)
    }
    func listUnfinished(limit: Int?, after: String?) async throws -> FileV2UnfinishedPage {
        try await base.listUnfinished(limit: limit, after: after)
    }
    func deleteUnfinished() async throws -> FileV2BulkDeleteResult { try await base.deleteUnfinished() }
}

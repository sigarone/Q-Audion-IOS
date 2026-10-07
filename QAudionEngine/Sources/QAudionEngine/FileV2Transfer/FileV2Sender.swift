import Foundation
import CryptoKit

/// The send pipeline of a v2 file, in one run, with no state that survives it (WIRE_SPEC section 12, server parts protocol).
///
/// ```
/// preflight (1 byte ... 5 GiB)  ->  fresh K and file_id  ->  create (+ download token)
///   -> seal the parts and upload them, FOUR at a time  ->  complete  ->  build the descriptor  ->  hand it to the chat
/// ```
///
/// What a run does and does not do, on purpose, for this first end-to-end step:
///
/// - It streams the source with a `FileHandle` per worker and never holds more than the parts being uploaded (at most
///   `parallelism` sealed parts of 8 MiB, plus one 1 MiB chunk each while it is being read): the memory does not depend on
///   the size of the file.
/// - A part is sealed ONCE and kept sealed while it is uploaded: a retry of the same part sends the SAME bytes (the digest is
///   computed once), never a second encryption. A retry follows the transfer base (`FileV2Retry`: 5 attempts, backoff or
///   `Retry-After`, 429 and 5xx retried, 4xx final).
/// - It keeps nothing on disk: no journal, no resume after a restart, no record of the source. The sender's `K` exists
///   only inside this run and goes out only inside the descriptor.
/// - The descriptor is built only after `complete`, from the object id and the token exactly as the server returned them,
///   and handed to `deliver`, which is the chat layer: the run is `sent` only when `deliver` returns, so a chat that refused
///   the message is a failed send (`announceNotSent`), never a file nobody was told about.
/// - On ANY failure after the object was created, the object is deleted (best effort, bounded in time, and also when the
///   run was cancelled): it counts against the account's quota and slots until it is.
public final class FileV2Sender: @unchecked Sendable {

    /// One file to send. `name` and `mimeType` are cut by the descriptor builder; `ex` and `xp` are written only when set
    /// (`ex`: -1 view once, 0 none, N seconds; `xp`: 0 export blocked).
    public struct Request: Sendable {
        public var sourceURL: URL
        public var name: String?
        public var mimeType: String?
        public var recipientUserID: String
        /// Downloads of the token: one per attempt of the recipient, so there is room for retries.
        public var maxDownloads: Int
        public var ex: Int64?
        public var xp: Int64?

        public init(sourceURL: URL, name: String?, mimeType: String?, recipientUserID: String,
                    maxDownloads: Int = FileV2Sender.defaultMaxDownloads, ex: Int64? = nil, xp: Int64? = nil) {
            self.sourceURL = sourceURL
            self.name = name
            self.mimeType = mimeType
            self.recipientUserID = recipientUserID
            self.maxDownloads = maxDownloads
            self.ex = ex
            self.xp = xp
        }
    }

    /// Parts in flight: fixed (the server's `parallelism` is 6 and its limit per account 16; this step does not adapt).
    public static let defaultParallelism = 4
    public static let defaultMaxDownloads = 30
    /// The longest a best-effort delete after a failure holds the failure back.
    static let cleanupLimitNanos: UInt64 = 10_000_000_000

    private let server: FileV2Server
    private let policy: FileV2RetryPolicy
    private let parallelism: Int
    private let sleep: @Sendable (Int64) async throws -> Void

    public init(server: FileV2Server, retryPolicy: FileV2RetryPolicy = FileV2RetryPolicy(),
                parallelism: Int = FileV2Sender.defaultParallelism,
                sleep: @escaping @Sendable (Int64) async throws -> Void = FileV2Retry.realSleep) {
        self.server = server
        self.policy = retryPolicy
        self.parallelism = max(1, parallelism)
        self.sleep = sleep
    }

    /// Sends `request`. `progress(done, total)` counts blob bytes uploaded; `deliver(body)` hands the descriptor, the text of a
    /// 1:1 chat message, to the chat layer and returns only when the layer confirms it queued or sent it (it throws
    /// otherwise). Throws `FileV2Failure`, or `CancellationError` when the task was cancelled.
    public func send(_ request: Request,
                     progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in },
                     deliver: (String) async throws -> Void) async throws {
        // 1. Preflight: nothing is created before the file is known to be sendable.
        let size = try Self.sourceSize(request.sourceURL)
        guard size >= 1 else { throw FileV2Failure(.emptyFile) }
        guard size <= FileV2.maxSize else { throw FileV2Failure(.fileTooLarge) }

        // 2. A new content: fresh K and file_id (never reused for a second content).
        let encryptor: FileV2Encryptor
        let plan: FileV2PartPlan
        do {
            encryptor = try FileV2Encryptor.makeNew(plaintextSize: size)
            guard let made = FileV2PartPlan.make(blobLength: Int64(encryptor.blobLength), totalChunks: encryptor.totalChunks) else {
                throw FileV2Failure.transfer(.badRequest)
            }
            plan = made
        } catch {
            throw Self.failure(from: error)
        }
        defer { encryptor.close() }

        // 3. Create the object, asking for the download token of the recipient in the same call.
        let createRequest = FileV2CreateRequest(
            blobLength: plan.blobLength, head: encryptor.header.bytes, partSize: FileV2Wire.partSize,
            token: .forRecipient(request.recipientUserID, maxUses: request.maxDownloads))
        let created = try await retried(.create) { try await self.server.create(createRequest) }
        let obj = created.obj

        // From here on an object exists on the server: any failure deletes it.
        do {
            // `existing` is not a problem: K and the file id are fresh for this run, so the only object that can already carry
            // this header is the one of an earlier try of THIS create whose answer was lost (the server's create is idempotent
            // on the header and answers 200 with a new token). Its parts are still empty, and a part is idempotent.
            guard created.partSize == FileV2Wire.partSize, created.parts == plan.parts.count,
                  let issued = created.token else {
                throw FileV2Failure.transfer(.badRequest)
            }

            // 4. Seal and upload the parts.
            try await uploadParts(plan, obj: obj, encryptor: encryptor, source: request.sourceURL, progress: progress)

            // 5. Close the object.
            try await retried(.complete) { try await self.server.complete(obj: obj) }

            // The source must be the file that was sealed (12.8 rule 1): a file that changed size under the transfer is
            // not the file the receiver will verify.
            guard try Self.sourceSize(request.sourceURL) == size, !encryptor.isCancelled else {
                throw FileV2Failure.transfer(.sourceChanged)
            }

            // 6. The descriptor, from the object and the token exactly as the server returned them.
            let source = FileV2Descriptor.Source(
                via: .srv, obj: obj, token: FileV2Descriptor.Token(v: issued.v, exp: issued.exp, max: Int64(issued.max)))
            let input = FileV2FileInput(encryptor: encryptor, kind: .file, source: source, name: request.name,
                                        mimeType: request.mimeType, ex: request.ex, xp: request.xp)
            let body: String
            do {
                body = try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: input))
            } catch {
                throw FileV2Failure.transfer(.descriptorTooLarge)
            }

            // 7. The chat layer: sent only when it says so.
            do {
                try await deliver(body)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FileV2Failure.transfer(.announceNotSent)
            }
        } catch {
            await discard(obj: obj)
            throw Self.failure(from: error)
        }
    }

    // MARK: Parts

    /// Uploads every part, `parallelism` at a time. The first failure cancels the others and is thrown.
    private func uploadParts(_ plan: FileV2PartPlan, obj: String, encryptor: FileV2Encryptor, source: URL,
                             progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = plan.blobLength
        try await withThrowingTaskGroup(of: Int.self) { group in
            var next = 0
            var sent: Int64 = Int64(FileV2.headerLength)    // the header went with the create
            func launch() {
                guard next < plan.parts.count else { return }
                let part = plan.parts[next]
                next += 1
                group.addTask { [self] in
                    try await uploadPart(part, obj: obj, encryptor: encryptor, source: source)
                    return part.byteLength
                }
            }
            for _ in 0..<min(parallelism, plan.parts.count) { launch() }
            while let bytes = try await group.next() {
                sent += Int64(bytes)
                progress(sent, total)
                launch()
            }
        }
    }

    /// Seals part `part` once and uploads it; a retry sends the same bytes with the same digest.
    private func uploadPart(_ part: FileV2PartPlan.Part, obj: String, encryptor: FileV2Encryptor, source: URL) async throws {
        let body = try Self.sealPart(part, encryptor: encryptor, source: source)
        let digest = Data(SHA256.hash(data: body))
        let index = part.index
        _ = try await retried(.putPart) { try await self.server.putPart(obj: obj, part: index, body: body, sha256: digest) }
    }

    /// The sealed chunks of `part`, concatenated: exactly the bytes the part has in the blob.
    static func sealPart(_ part: FileV2PartPlan.Part, encryptor: FileV2Encryptor, source: URL) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var body = Data()
            body.reserveCapacity(part.byteLength)
            for chunk in part.firstChunk..<(part.firstChunk + part.chunkCount) {
                try Task.checkCancellation()
                let sealed = try autoreleasepool { try encryptor.sealChunk(index: chunk, from: handle) }
                body.append(sealed)
            }
            guard body.count == part.byteLength else { throw FileV2Failure.transfer(.badRequest) }
            return body
        } catch {
            throw failure(from: error)
        }
    }

    // MARK: Helpers

    private func retried<T>(_ op: FileV2Op, _ attempt: () async throws -> T) async throws -> T {
        try await FileV2Retry.run(op: op, policy: policy, sleep: sleep, attempt)
    }

    /// Best-effort delete of an object after a failure: it runs even when the send was cancelled (an unstructured task does
    /// not inherit the cancellation) and holds the failure back for `cleanupLimitNanos` at most. A 404 or any other error is
    /// ignored: the 6-hour and 24-hour rules of the server and the next start of the app remove what is left.
    private func discard(obj: String) async {
        let server = self.server
        await Task.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? await server.delete(obj: obj) }
                group.addTask { try? await Task.sleep(nanoseconds: FileV2Sender.cleanupLimitNanos) }
                await group.next()
                group.cancelAll()
            }
        }.value
    }

    static func sourceSize(_ url: URL) throws -> UInt64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let number = attributes[.size] as? NSNumber, number.int64Value >= 0 else {
                throw FileV2Failure(.unreadable)
            }
            return UInt64(number.int64Value)
        } catch {
            throw failure(from: error)
        }
    }

    /// Everything that leaves the pipeline is a `FileV2Failure` or a `CancellationError`.
    static func failure(from error: Error) -> Error {
        if error is CancellationError { return error }
        if error is FileV2Failure { return error }
        if let format = error as? FileV2Error {
            if case .contentChanged = format { return FileV2Failure.transfer(.sourceChanged) }
            return FileV2Failure.transfer(.badRequest)
        }
        return FileV2Failure(.unreadable)
    }
}

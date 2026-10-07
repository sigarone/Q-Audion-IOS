import Foundation

/// The receive pipeline of a v2 file from the server, in one run, with no state that survives it.
///
/// ```
/// descriptor -> decryptor (key, header and commitment checked) -> fetch the header (bytes 0-63, the one use of the token)
///   -> fetch the parts, FOUR at a time, with ranged GETs -> every chunk verified by the library, then written
///   -> padding checked and the file cut to its real size (finalize)
/// ```
///
/// - The plaintext is written into `destination` as it is verified, one chunk at a time, at its place; no byte is written
///   before its chunk has passed GCM, and a part held in memory at once is 8 MiB (at most `parallelism` of them).
/// - Any failure removes `destination`: nothing partial stays on disk, and nothing resumes (a new run starts from the
///   descriptor again). A chunk that does not verify is requested again, up to 3 tries in all, then it fails the run.
/// - The token of the descriptor is presented as the descriptor holds it, never printed, never stored anywhere else.
/// - A part is requested with its exact range, and an answer of any other length is a failure.
public final class FileV2Receiver: @unchecked Sendable {

    public static let defaultParallelism = 4
    /// Times a part is asked for in all when one of its chunks does not verify (WIRE_SPEC 12.9 step 4: at most 3).
    static let maxChunkAttempts = 3
    /// Room kept free on the volume besides the file itself.
    static let spareBytes: Int64 = 16 * 1024 * 1024

    private let server: FileV2Server
    private let policy: FileV2RetryPolicy
    private let parallelism: Int
    private let sleep: @Sendable (Int64) async throws -> Void
    /// Free bytes on the volume of a directory, `nil` when unknown (then the check is skipped).
    private let freeSpace: @Sendable (URL) -> Int64?

    public init(server: FileV2Server, retryPolicy: FileV2RetryPolicy = FileV2RetryPolicy(),
                parallelism: Int = FileV2Receiver.defaultParallelism,
                sleep: @escaping @Sendable (Int64) async throws -> Void = FileV2Retry.realSleep,
                freeSpace: @escaping @Sendable (URL) -> Int64? = FileV2Receiver.volumeFreeBytes) {
        self.server = server
        self.policy = retryPolicy
        self.parallelism = max(1, parallelism)
        self.sleep = sleep
        self.freeSpace = freeSpace
    }

    /// Downloads, verifies and decrypts the file of `descriptor` into `destination` (an existing file there is replaced).
    /// `progress(done, total)` counts blob bytes fetched. Throws `FileV2Failure` or `CancellationError`; on any failure
    /// `destination` does not exist.
    public func download(_ descriptor: FileV2Descriptor, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        guard descriptor.source.via == .srv, let obj = descriptor.source.obj, let token = descriptor.source.token else {
            throw FileV2Failure(.unavailable)
        }
        let auth = FileV2DownloadAuth(v: token.v, expMs: token.exp, max: Int(clamping: token.max))

        let decryptor: FileV2Decryptor
        let plan: FileV2PartPlan
        do {
            decryptor = try FileV2Decryptor(descriptor: descriptor)
            guard let made = FileV2PartPlan.make(blobLength: Int64(decryptor.blobLength), totalChunks: decryptor.totalChunks) else {
                throw FileV2Error.sizeMismatch
            }
            plan = made
        } catch {
            throw Self.failure(from: error)
        }
        defer { decryptor.close() }

        // The output is as long as the padded stream until `finalize` cuts it to `sz`.
        let directory = destination.deletingLastPathComponent()
        if let free = freeSpace(directory), free < Int64(clamping: descriptor.header.streamLength) + Self.spareBytes {
            throw FileV2Failure.transfer(.noSpace)
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw FileV2Failure.transfer(.noSpace)
        }
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: destination) } }
        let output: FileHandle
        do {
            output = try FileHandle(forUpdating: destination)
        } catch {
            throw FileV2Failure.transfer(.noSpace)
        }
        var outputClosed = false
        defer { if !outputClosed { try? output.close() } }

        do {
            // Step 3 of 12.9: the header of the source is the header of the descriptor. This request starts at offset 0, so
            // it is the one that spends a use of the token.
            let head = try await retried { try await self.server.fetchRange(obj: obj, from: 0, toInclusive: 63, token: auth, waitSeconds: 0) }
            guard head.body.count == FileV2.headerLength, head.totalLength == plan.blobLength else {
                throw FileV2Error.sizeMismatch
            }
            try decryptor.verifySourceHeader(head.body)
            progress(Int64(FileV2.headerLength), plan.blobLength)

            try await fetchParts(plan, obj: obj, auth: auth, decryptor: decryptor, output: output, progress: progress)

            // Steps 4 and 5: every chunk verified, the padding all zero, the file cut to its size.
            try decryptor.endOfStream()
            try decryptor.finalize(output: output)
            outputClosed = true
            try output.close()
            finished = true
        } catch {
            throw Self.failure(from: error)
        }
    }

    // MARK: Parts

    private func fetchParts(_ plan: FileV2PartPlan, obj: String, auth: FileV2DownloadAuth, decryptor: FileV2Decryptor,
                            output: FileHandle, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let total = plan.blobLength
        try await withThrowingTaskGroup(of: Int.self) { group in
            var next = 0
            var fetched: Int64 = Int64(FileV2.headerLength)
            func launch() {
                guard next < plan.parts.count else { return }
                let part = plan.parts[next]
                next += 1
                group.addTask { [self] in
                    try await fetchPart(part, obj: obj, auth: auth, decryptor: decryptor, output: output)
                    return part.byteLength
                }
            }
            for _ in 0..<min(parallelism, plan.parts.count) { launch() }
            while let bytes = try await group.next() {
                fetched += Int64(bytes)
                progress(fetched, total)
                launch()
            }
        }
    }

    /// One part: its exact range, then every chunk of it through the decryptor. A chunk that does not verify is requested again
    /// (the whole part, from the same source), at most `maxChunkAttempts` times in all, then the run fails (WIRE_SPEC 12.9
    /// step 4); the chunks of the part that did verify are ignored when they come again.
    private func fetchPart(_ part: FileV2PartPlan.Part, obj: String, auth: FileV2DownloadAuth, decryptor: FileV2Decryptor,
                           output: FileHandle) async throws {
        let range = part.range
        var attempt = 0
        while true {
            attempt += 1
            let result = try await retried {
                try await self.server.fetchRange(obj: obj, from: range.from, toInclusive: range.toInclusive, token: auth, waitSeconds: 0)
            }
            guard result.body.count == part.byteLength else { throw FileV2Error.sizeMismatch }
            do {
                try Self.openChunks(of: part, in: result.body, decryptor: decryptor, output: output)
                return
            } catch FileV2Error.chunkAuth where attempt < FileV2Receiver.maxChunkAttempts {
                try Task.checkCancellation()
            }
        }
    }

    private static func openChunks(of part: FileV2PartPlan.Part, in body: Data, decryptor: FileV2Decryptor,
                                   output: FileHandle) throws {
        var offset = 0
        for chunk in part.firstChunk..<(part.firstChunk + part.chunkCount) {
            try Task.checkCancellation()
            let length = decryptor.sealedChunkLength(chunk)
            guard length > 0, offset + length <= body.count else { throw FileV2Error.sizeMismatch }
            let sealed = Data(body[(body.startIndex + offset)..<(body.startIndex + offset + length)])
            offset += length
            _ = try autoreleasepool { try decryptor.receive(index: chunk, sealed: sealed, writingTo: output) }
        }
        guard offset == body.count else { throw FileV2Error.sizeMismatch }
    }

    // MARK: Helpers

    private func retried<T>(_ attempt: () async throws -> T) async throws -> T {
        try await FileV2Retry.run(op: .fetchRange, policy: policy, sleep: sleep, attempt)
    }

    /// Everything that leaves the pipeline is a `FileV2Failure` or a `CancellationError`.
    static func failure(from error: Error) -> Error {
        if error is CancellationError { return error }
        if error is FileV2Failure { return error }
        if let format = error as? FileV2Error { return FileV2Failure(.format(format.code)) }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return FileV2Failure.transfer(.noSpace) }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return FileV2Failure.transfer(.noSpace) }
        // what is left is a local I/O failure (the transport's errors were turned into failures by the retry loop)
        return FileV2Failure(.format("io_error"))
    }

    /// `volumeAvailableCapacityForImportantUsage` of the volume of `directory`.
    public static let volumeFreeBytes: @Sendable (URL) -> Int64? = { directory in
        #if canImport(Darwin)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }
}

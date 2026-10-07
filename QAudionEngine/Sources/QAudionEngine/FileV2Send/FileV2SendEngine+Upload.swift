import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The parts: sealing, the journal write that must come BEFORE the PUT, the PUT with its retries and its progress-based timeout, and
// the pool that keeps as many parts in flight as the adaptive parallelism and the memory budget allow.

extension FileV2SendEngine {

    enum PoolResult: Sendable {
        case allDone
        /// A part answered 404 (or was told its object was replaced): the object is gone and a new one is needed.
        case objectGone
        case failed(FileV2SendFailure)
        case interrupted
    }

    enum PartOutcome: Sendable {
        case uploaded(part: Int, bytes: Int, duplicate: Bool, startedMs: Int64)
        case objectGone
        case failed(FileV2SendFailure)
        case interrupted
    }

    // MARK: The pool

    /// Uploads `parts`, at most `parallelism.current` at a time. Each part is assigned to one task (WIRE_SPEC 12.8 rule 3). The first
    /// failure that ends the transfer cancels the others and is the result: workers are cooperative, and the pool does not return
    /// before every task has stopped, so nothing is in flight when the caller cleans up.
    func uploadParts(_ parts: [Int]) async -> PoolResult {
        return await withTaskGroup(of: PartOutcome.self) { group -> PoolResult in
            var next = 0
            var inFlight = 0
            var result: PoolResult?

            func fill() {
                while result == nil, next < parts.count, inFlight < self.currentParallelism() {
                    let part = parts[next]
                    next += 1
                    inFlight += 1
                    group.addTask { await self.uploadPart(part) }
                }
            }

            fill()
            while inFlight > 0, let outcome = await group.next() {
                inFlight -= 1
                switch outcome {
                case .uploaded(let part, let bytes, let duplicate, let startedMs):
                    self.partDone(part: part, bytes: bytes, duplicate: duplicate, startedMs: startedMs)
                    self.emit(.uploading(self.progress()))
                case .objectGone:
                    if result == nil {
                        result = .objectGone
                        group.cancelAll()
                    }
                case .failed(let failure):
                    if result == nil {
                        result = .failed(failure)
                        group.cancelAll()
                    }
                case .interrupted:
                    if result == nil {
                        result = .interrupted
                        group.cancelAll()
                    }
                }
                if Task.isCancelled, result == nil { result = .interrupted }
                fill()
            }
            return result ?? .allDone
        }
    }

    func currentParallelism() -> Int { state.withValue { $0.parallelism?.current ?? 1 } }

    private func partDone(part: Int, bytes: Int, duplicate: Bool, startedMs: Int64) {
        markDone(part, journal: true)
        feedParallelism { $0.onPartDone(bytes: Int64(bytes), nowMs: self.ctx.clock.monotonicMs(), startedMs: startedMs) }
        ctx.record(.partUploaded(bytes: bytes, duplicate: duplicate))
    }

    /// A part failed (timeout, 5xx, 429, a reset): the adaptive rule halves once per window.
    private func partFailed(startedMs: Int64) {
        feedParallelism { $0.onPartFailed(nowMs: self.ctx.clock.monotonicMs(), startedMs: startedMs) }
    }

    private func feedParallelism(_ update: (inout FileV2AdaptiveParallelism) -> Void) {
        let change = state.withValue { current -> (Int, Int)? in
            guard var rule = current.parallelism else { return nil }
            let before = rule.current
            update(&rule)
            current.parallelism = rule
            return rule.current == before ? nil : (before, rule.current)
        }
        if let (before, after) = change { ctx.record(.parallelismChanged(from: before, to: after)) }
    }

    // MARK: One part

    /// Seals part `part`, journals its tags, PUTs it. The sealed bytes stay in memory until the part is confirmed, so a retry sends the
    /// same bytes without reading the source again.
    func uploadPart(_ part: Int) async -> PartOutcome {
        let startedMs = ctx.clock.monotonicMs()
        let partLength = FileV2Wire.partLength(blobLength: blobLength, part: part)
        guard partLength > 0, let obj = state.withValue({ $0.object?.obj }) else { return .failed(FileV2SendFailure(.badRequest)) }
        if Task.isCancelled { return .interrupted }

        ctx.gauge.addPart(bytes: partLength)
        defer { ctx.gauge.releasePart(bytes: partLength) }

        // Rule 1 of 12.8, for the whole run: the source is still what the transfer started with.
        guard sourceIsUnchanged() else { return .failed(FileV2SendFailure(.sourceChanged)) }

        // Seal. A tag that differs from a recorded one (rule 2) throws `contentChanged` BEFORE anything is transmitted.
        let sealed: SealedPart
        do {
            sealed = try await sealPart(part, length: partLength)
        } catch is CancellationError {
            return .interrupted
        } catch FileV2Error.contentChanged {
            return .failed(FileV2SendFailure(.sourceChanged))
        } catch FileV2Error.closed {
            return .interrupted
        } catch is FileV2SendSourceError {
            return .failed(FileV2SendFailure(.sourceChanged))
        } catch {
            return .failed(FileV2SendFailure(.badRequest))
        }

        // THE JOURNAL BEFORE THE PUT: the tags of this part are durable when this returns, and not before the PUT below.
        do { try journalTags(part: part, tags: sealed.tags) } catch { return .failed(FileV2SendFailure(.storage)) }
        if Task.isCancelled { return .interrupted }

        let digest = Data(SHA256.hash(data: sealed.data))
        let result: FileV2RequestResult<FileV2PutResult> = await ctx.request(.putPart, onRetryableFailure: { self.partFailed(startedMs: startedMs) }) {
            try await self.putOnce(obj: obj, part: part, body: sealed.data, digest: digest)
        }
        switch result {
        case .value(let put):
            guard put.part == part else { return .failed(FileV2SendFailure(.badRequest)) }
            // A duplicate (the same part with the same digest was already there) is a success, as the conformance transcript has it.
            return .uploaded(part: part, bytes: partLength, duplicate: put.duplicate, startedMs: startedMs)
        case .recreate:
            return .objectGone
        case .interrupted:
            return .interrupted
        case .failure(let failure):
            return .failed(failure)
        case .done, .sendMissing, .userRemedy:
            return .failed(FileV2SendFailure(.badRequest))
        }
    }

    struct SealedPart: Sendable {
        let data: Data
        let tags: [FileV2SendTag]
    }

    /// Reads the chunks of a part from the source and seals them, one chunk at a time. Holds the sealed part, and for the chunk at hand
    /// its plaintext and its sealed form: that is what `FileV2SendContext.perWorkerExtraBytes` accounts for.
    func sealPart(_ part: Int, length: Int) async throws -> SealedPart {
        let reader = try source.makeReader()
        defer { reader.close() }
        var data = Data()
        data.reserveCapacity(length)
        var tags: [FileV2SendTag] = []
        for index in chunkRange(ofPart: part) {
            try Task.checkCancellation()
            let plainLength = encryptor.chunkFileLength(index)
            let sealedLength = encryptor.sealedChunkLength(index)
            ctx.gauge.add(bytes: plainLength + sealedLength)
            defer { ctx.gauge.release(bytes: plainLength + sealedLength) }
            let plain = plainLength > 0
                ? try reader.read(offset: UInt64(index) * UInt64(FileV2.chunkSize), length: plainLength)
                : Data()
            let sealed = try encryptor.sealChunk(index: index, fileBytes: plain)
            tags.append(FileV2SendTag(index: index, tag: Data(sealed.suffix(FileV2.tagSize))))
            data.append(sealed)
            await Task.yield()
        }
        guard data.count == length else { throw FileV2Error.invalidArgument("part length") }
        return SealedPart(data: data, tags: tags)
    }

    /// Appends the tags of the chunks that are not in the journal yet. When this returns they are durable (the store flushes before
    /// it returns): only then may the part be PUT.
    func journalTags(part: Int, tags: [FileV2SendTag]) throws {
        let fresh = state.withValue { current in tags.filter { !current.journaledChunks.contains($0.index) } }
        guard !fresh.isEmpty else { return }
        try ctx.store.append(.tags(part: part, entries: fresh), to: id)
        state.withValue { current in
            for tag in fresh { current.journaledChunks.insert(tag.index) }
        }
    }

    // MARK: One attempt of a PUT, with a progress-based timeout

    /// One PUT of a part. The timeout slides while bytes move (`FileV2ProgressDeadline`): the slowest legitimate part, 8 MiB at the
    /// server's floor of 8000 bytes per second, takes about 17.5 minutes, so a fixed total timeout would cut a legitimate upload on a
    /// slow link. A server that cannot report progress gets one total deadline of that time plus a margin.
    func putOnce(obj: String, part: Int, body: Data, digest: Data) async throws -> FileV2PutResult {
        let server = ctx.server
        let reporting = server as? FileV2PartProgressReporting
        let limit = reporting != nil ? ctx.config.partIdleTimeoutMs : ctx.config.partTotalTimeoutMs
        let clock = ctx.clock
        let deadline = FileV2Locked(FileV2ProgressDeadline(idleLimitMs: limit, startMs: clock.monotonicMs()))
        let pollNanoseconds = UInt64(max(1, ctx.config.watchdogPollMs)) * 1_000_000
        return try await withThrowingTaskGroup(of: FileV2PutResult?.self) { group -> FileV2PutResult in
            group.addTask {
                if let reporting = reporting {
                    return try await reporting.putPart(obj: obj, part: part, body: body, sha256: digest) { moved in
                        deadline.withValue { $0.progress(bytes: moved, nowMs: clock.monotonicMs()) }
                    }
                }
                return try await server.putPart(obj: obj, part: part, body: body, sha256: digest)
            }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                    if deadline.withValue({ $0.isExpired(nowMs: clock.monotonicMs()) }) { throw URLError(.timedOut) }
                }
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else { throw URLError(.timedOut) }
            return result
        }
    }
}

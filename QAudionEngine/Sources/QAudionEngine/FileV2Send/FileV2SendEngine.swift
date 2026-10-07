import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One transfer being run: the object on the server, the parts, the complete, the descriptor. It is built by
/// `FileV2SendPipeline` after the preflight and the begin record (a new transfer) or after the journal has been read and the source
/// checked (a resume), and it owns the encryptor, and with it the nonce ledger of WIRE_SPEC 12.8.
///
/// THE NONCE RULE, as this class keeps it:
///
///  1. A chunk is sealed by the encryptor, which records `T[i]` in its ledger the first time and refuses a different tag later.
///  2. The tags of a part are appended to the journal (`FileV2SendStore.append`, durable when it returns) BEFORE the part is
///     PUT. There is no code path that PUTs a part whose chunks are not all in the journal.
///  3. A resume builds the encryptor with the journal's tags (`FileV2Encryptor.resume`), so a re-sealed chunk is compared with what
///     was sealed before. A mismatch means the content changed: the chunk is never transmitted, the transfer is cancelled
///     (the object deleted, `qa_file_cancel` sent if a descriptor may have gone out, the state wiped), and the caller starts a new
///     transfer with a new `K` and `file_id`.
///  4. A part that fails is sent again with the same bytes: they are held in memory until the part is confirmed.
///  5. After a resume, a part the server holds whose chunks are not all in the journal cancels the transfer: the journal lost
///     something, and the tags that would prove the bytes are the same are gone.
///  6. Before every part and before `complete`, the source's size and modification time are compared with the transfer's.
///
/// Memory: a worker holds its sealed part (at most 8 388 736 bytes) and, while it seals, the plaintext chunk and the sealed chunk
/// (1 MiB each). The number of workers is the adaptive parallelism, capped by the memory budget that counts exactly that.
final class FileV2SendEngine: @unchecked Sendable {

    struct Mutable {
        var object: FileV2SendObjectRecord?
        var tokenRecord: FileV2SendTokenRecord?
        /// The chunks whose tags are in the journal.
        var journaledChunks: Set<Int>
        var doneParts: Set<Int> = []
        var bytesDone: Int64 = 0
        var phase: FileV2SendPhase
        var maybeAnnounced: Bool
        /// Counts the objects of this run: a worker started under an older generation knows its object is gone.
        var generation = 0
        var parallelism: FileV2AdaptiveParallelism?
        /// An object has been created or found on the server for this transfer.
        var objectAcknowledged: Bool
        var sealingAnnounced = false
    }

    let ctx: FileV2SendContext
    let id: String
    let begin: FileV2SendBeginRecord
    let encryptor: FileV2Encryptor
    let source: FileV2SendSource
    let isNew: Bool
    let onState: FileV2SendStateSink?
    let isUserCancelled: @Sendable () -> Bool

    let blobLength: Int64
    let totalParts: Int
    let state: FileV2Locked<Mutable>

    init(context: FileV2SendContext, begin: FileV2SendBeginRecord, encryptor: FileV2Encryptor, source: FileV2SendSource,
         recovered: FileV2SendRecovered?, onState: FileV2SendStateSink?, isUserCancelled: @escaping @Sendable () -> Bool) {
        self.ctx = context
        self.id = begin.transferID
        self.begin = begin
        self.encryptor = encryptor
        self.source = source
        self.isNew = recovered == nil
        self.onState = onState
        self.isUserCancelled = isUserCancelled
        self.blobLength = Int64(encryptor.blobLength)
        self.totalParts = FileV2Wire.partCount(blobLength: Int64(encryptor.blobLength))
        let journaled: Set<Int> = recovered.map { Set($0.tags.keys) } ?? []
        self.state = FileV2Locked(Mutable(object: recovered?.object, tokenRecord: recovered?.token,
                                          journaledChunks: journaled,
                                          phase: recovered?.phase ?? .uploading,
                                          maybeAnnounced: recovered?.descriptorMayHaveBeenSent ?? false,
                                          objectAcknowledged: recovered?.object != nil))
    }

    // MARK: Emission and endings

    func emit(_ next: FileV2SendState) { onState?(next) }

    func interrupted() -> FileV2SendState {
        emit(.interrupted)
        ctx.record(.finished(code: "interrupted"))
        return .interrupted
    }

    /// The end of a transfer that failed. The state is kept for a failure that can be resumed, and wiped (object deleted, secrets
    /// destroyed, journal removed) for one that cannot. A transfer the user is cancelling is left to the canceller.
    ///
    /// A cancelled TASK (the app is going away) is not an end: whatever failed is judged again on the next resume (a changed source is
    /// found again, a pause is resumed), and a clean-up is never started from a task that is being torn down, where its requests would
    /// not complete. The state stays, and the result is `interrupted`.
    func end(_ failure: FileV2SendFailure) async -> FileV2SendState {
        if isUserCancelled() || Task.isCancelled { return interrupted() }
        let acknowledged = state.withValue { $0.objectAcknowledged }
        // A new transfer that never got an object and was refused for an account reason has nothing worth keeping: the user retries
        // with a new send, with a new key.
        let refusedBeforeAnything = isNew && !acknowledged
            && [.auth, .entitlement, .serverFull, .userRemedy, .quota].contains(failure.reason)
        if !failure.keepsState || refusedBeforeAnything {
            await ctx.cleanup(transferID: id)
        }
        if failure.reason == .sourceChanged { ctx.record(.contentChanged) }
        emit(.failed(failure))
        ctx.record(.finished(code: failure.reason.rawValue))
        return .failed(failure)
    }

    // MARK: The run

    /// Runs the transfer to its end: object, parts, complete, descriptor. Zeroes the key material when it returns.
    func run() async -> FileV2SendState {
        defer { encryptor.close() }
        ctx.encryptorObserver?(encryptor)
        var recreations = 0
        var completeRounds = 0
        var forceMap = false

        while true {
            if Task.isCancelled || isUserCancelled() { return interrupted() }

            // 1. The object on the server (idempotent on the header: a resume finds the object it left).
            let created: FileV2Created
            switch await ensureObject() {
            case .ready(let value): created = value
            case .terminal(let terminal): return terminal
            }

            // 2. What the server already has, and a check that the journal can vouch for it.
            let toSend: [Int]
            if created.complete {
                guard crossCheck(received: { _ in true }) else { return await end(FileV2SendFailure(.stateLost)) }
                noteReceived(Array(0..<totalParts))
                toSend = []
            } else if created.existing && (created.received > 0 || forceMap) {
                switch await fetchPartsMap() {
                case .map(let map):
                    guard crossCheck(received: { map.isReceived($0) }) else { return await end(FileV2SendFailure(.stateLost)) }
                    noteReceived((0..<totalParts).filter { map.isReceived($0) })
                    toSend = map.missing
                case .recreate:
                    recreations += 1
                    guard recreations <= ctx.config.maxObjectRecreations else { return await end(FileV2SendFailure(.network)) }
                    ctx.record(.objectRecreated)
                    continue
                case .terminal(let terminal): return terminal
                }
            } else {
                toSend = Array(0..<totalParts)
            }
            forceMap = false

            // 3. The parts.
            if !toSend.isEmpty {
                announceSealingOnce()
                emit(.uploading(progress()))
                switch await uploadParts(toSend) {
                case .allDone: break
                case .objectGone:
                    recreations += 1
                    guard recreations <= ctx.config.maxObjectRecreations else { return await end(FileV2SendFailure(.network)) }
                    ctx.record(.objectRecreated)
                    continue
                case .failed(let failure): return await end(failure)
                case .interrupted: return interrupted()
                }
            }

            // 4. Close the object.
            if !(created.complete && state.withValue { $0.phase != .uploading }) {
                switch await completeObject(alreadyComplete: created.complete) {
                case .done: break
                case .recreate:
                    recreations += 1
                    guard recreations <= ctx.config.maxObjectRecreations else { return await end(FileV2SendFailure(.network)) }
                    ctx.record(.objectRecreated)
                    continue
                case .incomplete:
                    completeRounds += 1
                    guard completeRounds <= ctx.config.maxCompleteRounds else { return await end(FileV2SendFailure(.badRequest)) }
                    forceMap = true
                    continue
                case .terminal(let terminal): return terminal
                }
            }

            // 5. The descriptor.
            switch await announce() {
            case .finished(let terminal): return terminal
            case .recreate:
                recreations += 1
                guard recreations <= ctx.config.maxObjectRecreations else { return await end(FileV2SendFailure(.network)) }
                ctx.record(.objectRecreated)
                continue
            }
        }
    }

    // MARK: Progress

    func progress() -> FileV2SendProgress {
        state.withValue {
            FileV2SendProgress(partsDone: $0.doneParts.count, partsTotal: totalParts, bytesDone: $0.bytesDone,
                               bytesTotal: blobLength - Int64(FileV2.headerLength))
        }
    }

    private func announceSealingOnce() {
        let first = state.withValue { current -> Bool in
            let was = current.sealingAnnounced
            current.sealingAnnounced = true
            return !was
        }
        if first { emit(.sealing) }
    }

    /// Records parts the server has (the map of a resume, a duplicate): progress, and a hint in the journal.
    func noteReceived(_ parts: [Int]) {
        for part in parts { markDone(part, journal: false) }
    }

    func markDone(_ part: Int, journal: Bool) {
        let isNewPart = state.withValue { current -> Bool in
            guard current.doneParts.insert(part).inserted else { return false }
            current.bytesDone += Int64(FileV2Wire.partLength(blobLength: blobLength, part: part))
            return true
        }
        if isNewPart && journal { try? ctx.store.append(.partDone(part), to: id) }
    }

    // MARK: The journal can vouch for what the server has

    /// Section 12.8 and the journal: every part the server holds must have ALL its chunk tags in the journal. If one does not, the
    /// journal lost a record (a corrupt tail) and the tags that would prove a re-seal produces the same bytes are gone.
    func crossCheck(received: (Int) -> Bool) -> Bool {
        let journaled = state.withValue { $0.journaledChunks }
        for part in 0..<totalParts where received(part) {
            for chunk in chunkRange(ofPart: part) where !journaled.contains(chunk) { return false }
        }
        return true
    }

    func chunkRange(ofPart part: Int) -> Range<Int> {
        let first = part * FileV2Wire.chunksPerPart
        return first..<min(first + FileV2Wire.chunksPerPart, encryptor.totalChunks)
    }

    // MARK: Source

    /// Rule 1 of WIRE_SPEC 12.8, kept for the whole run: the source must still be what the transfer started with.
    func sourceIsUnchanged() -> Bool {
        guard let now = try? source.currentIdentity() else { return false }
        return now.isUnchanged(comparedTo: begin.source)
    }
}

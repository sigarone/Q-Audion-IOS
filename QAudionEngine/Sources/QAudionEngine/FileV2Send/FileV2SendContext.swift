import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The outcome of one request to the server, after the retries the disposition table asks for.
enum FileV2RequestResult<Value: Sendable>: Sendable {
    case value(Value)
    /// The request had its effect already (a delete of an object that is gone).
    case done
    /// 404 on a sender operation: the object is gone; make it again from the same header.
    case recreate
    /// 429 `too_many_uploads` or `too_many_objects`: waiting does not help; the user (or an orphan sweep) must free something.
    case userRemedy(FileV2ServerError)
    /// 409 `incomplete`.
    case sendMissing(FileV2ServerError)
    case failure(FileV2SendFailure)
    /// The task was cancelled.
    case interrupted
}

/// What every transfer of one pipeline shares: the dependencies, the configuration, the gate, the gauge, and the operations that
/// do not belong to one transfer (the retry loop around a request, the clean-up of a transfer, the sweep of orphaned uploads).
final class FileV2SendContext: @unchecked Sendable {
    let deps: FileV2SendDependencies
    let config: FileV2SendConfiguration
    let budget: FileV2MemBudget
    let gate = FileV2AsyncGate()
    let gauge = FileV2SendGauge()
    /// Test seam: told of the encryptor of every transfer that runs, so a test can check that its key material is zeroed when the run ends.
    var encryptorObserver: (@Sendable (FileV2Encryptor) -> Void)?

    /// What a worker holds beyond its sealed part while it seals: the plaintext chunk and the sealed chunk, 1 MiB each.
    static let perWorkerExtraBytes = Int64(2 * FileV2.chunkSize)

    init(dependencies: FileV2SendDependencies, configuration: FileV2SendConfiguration) {
        self.deps = dependencies
        self.config = configuration
        // `FileV2MemBudget` throws only for a negative number, which is clamped here.
        self.budget = (try? FileV2MemBudget(memoryMiB: max(0, configuration.availableMemoryMiB),
                                            perWorkerExtraBytes: FileV2SendContext.perWorkerExtraBytes))
            ?? (try! FileV2MemBudget(memoryMiB: 0)) // swiftlint:disable:this force_try
    }

    var server: FileV2Server { deps.server }
    var store: FileV2SendStore { deps.store }
    var secrets: FileV2SecretWrapper { deps.secrets }
    var clock: FileV2Clock { deps.clock }

    func record(_ event: FileV2SendTelemetryEvent) { deps.telemetry?.record(event) }

    // MARK: A request and its retries

    /// Runs `body` until it succeeds or the disposition table says what else to do (WIRE_SPEC 12.10 and the server's error table):
    ///
    /// - `retry`: the backoff 1, 2, 4, 8 s with jitter, or `Retry-After` up to 300 s; the failure when the attempts are spent;
    /// - `wait` (425): `Retry-After`, not counted as an attempt, bounded;
    /// - `refreshAuth` (401): the dependency refreshes the token and the request is repeated, a few times at most;
    /// - `recreate`, `sendMissing`, `userRemedy`: returned to the caller, which knows what to do;
    /// - `done`: the request had its effect already.
    ///
    /// `onRetryableFailure` is told of every failure that counts against the parallelism (a timeout, a 5xx, a 429, a reset).
    func request<Value: Sendable>(_ op: FileV2Op, onRetryableFailure: (@Sendable () -> Void)? = nil,
                                  _ body: @Sendable () async throws -> Value) async -> FileV2RequestResult<Value> {
        var failures = 0
        var waits = 0
        var refreshes = 0
        while true {
            if Task.isCancelled { return .interrupted }
            do {
                return .value(try await body())
            } catch is CancellationError {
                return .interrupted
            } catch is FileV2SendStoreError {
                return .failure(FileV2SendFailure(.storage))
            } catch is FileV2WireFormatError {
                // An answer that does not say what the protocol says: a server this client does not speak to.
                return .failure(FileV2SendFailure(transfer: .badRequest))
            } catch {
                let disposition: FileV2Disposition
                do { disposition = try fileV2TransportDisposition(error, op: op) } catch { return .interrupted }
                let serverError = error as? FileV2ServerError
                switch disposition {
                case .retry(let exhausted):
                    failures += 1
                    onRetryableFailure?()
                    record(.retried)
                    guard let delay = config.retryPolicy.nextDelayMs(failedAttempts: failures, retryAfterSeconds: serverError?.retryAfter) else {
                        // The attempts are spent, or the server asked for more than 300 s (not waited for): the transfer pauses or fails.
                        return .failure(FileV2SendFailure(transfer: exhausted, details: serverError?.details, code: serverError?.code))
                    }
                    do { try await deps.sleeper.sleep(milliseconds: delay) } catch { return .interrupted }
                case .wait:
                    waits += 1
                    guard waits <= 100 else { return .failure(FileV2SendFailure(transfer: .network)) }
                    let seconds = min(max(serverError?.retryAfter ?? 1, 0), FileV2Wire.maxRetryAfterSeconds)
                    do { try await deps.sleeper.sleep(milliseconds: Int64(seconds) * 1000) } catch { return .interrupted }
                case .refreshAuth:
                    guard let refresh = deps.refreshAuth, refreshes < config.maxAuthRefreshes, await refresh() else {
                        return .failure(FileV2SendFailure(transfer: .auth))
                    }
                    refreshes += 1
                case .recreate:
                    return .recreate
                case .sendMissing:
                    guard let serverError = serverError else { return .failure(FileV2SendFailure(transfer: .badRequest)) }
                    return .sendMissing(serverError)
                case .done:
                    return .done
                case .unavailable:
                    return .failure(FileV2SendFailure(transfer: .badRequest))
                case .userRemedy:
                    guard let serverError = serverError else { return .failure(FileV2SendFailure(transfer: .badRequest)) }
                    return .userRemedy(serverError)
                case .fail(let reason):
                    return .failure(FileV2SendFailure(transfer: reason, details: serverError?.details, code: serverError?.code))
                }
            }
        }
    }

    // MARK: Clean-up of a transfer (cancel, source changed, state lost)

    /// Ends a transfer for good (WIRE_SPEC 12.8 rule 2, and a cancel): marks the journal `cancelled` (so a crash in the middle is finished
    /// by the next launch), deletes the object on the server (404 is success), sends `qa_file_cancel` through the chat when a
    /// descriptor may have gone out, destroys the secrets (the key, the token) and removes the journal. Returns whether there was a
    /// transfer. Never throws: a clean-up does not stop half way, and what it cannot do (the server is unreachable) is left to the
    /// server's own clean-up (an unfinished object goes after 6 hours of idleness, 24 hours at the latest).
    @discardableResult
    func cleanup(transferID id: String) async -> Bool {
        let recovered: FileV2SendRecovered
        do {
            recovered = try store.load(id)
        } catch FileV2SendStoreError.notFound {
            return false
        } catch {
            // A journal that cannot be read tells nothing about secrets or objects: remove it.
            try? store.remove(id)
            return true
        }
        try? store.append(.phase(.cancelled), to: id)
        if let obj = recovered.object?.obj {
            await deleteObject(obj)
        }
        if recovered.descriptorMayHaveBeenSent, let body = try? FileV2DescriptorBuilder.buildCancel(fileID: recovered.begin.fileID) {
            _ = await deps.channel.sendControl(body, to: recovered.begin.conversation)
        }
        secrets.destroy(recovered.begin.wrappedKey)
        if let token = recovered.token { secrets.destroy(token.wrappedValue) }
        try? store.remove(id)
        return true
    }

    /// `DELETE` of an object, a few tries. 404 is success. Anything it cannot do is left to the server's own clean-up.
    func deleteObject(_ obj: String) async {
        var attempts = 0
        while attempts < 3 {
            attempts += 1
            let result: FileV2RequestResult<Bool> = await requestOnce(.delete) {
                try await self.server.delete(obj: obj)
                return true
            }
            switch result {
            case .value, .done, .recreate: return
            case .interrupted: return
            case .failure(let failure):
                // An answer that will not change (the account may not delete this object) ends it; the network gets another try.
                if failure.reason != .network { return }
            case .userRemedy, .sendMissing: return
            }
            try? await deps.sleeper.sleep(milliseconds: Int64(attempts) * 1000)
        }
    }

    /// A single request with the disposition applied but no retry loop: the caller decides.
    func requestOnce<Value: Sendable>(_ op: FileV2Op, _ body: @Sendable () async throws -> Value) async -> FileV2RequestResult<Value> {
        do {
            return .value(try await body())
        } catch is CancellationError {
            return .interrupted
        } catch {
            guard let disposition = try? fileV2TransportDisposition(error, op: op) else { return .interrupted }
            switch disposition {
            case .done: return .done
            case .recreate: return .recreate
            case .retry, .wait, .refreshAuth: return .failure(FileV2SendFailure(transfer: .network))
            default: return .failure(FileV2SendFailure(transfer: .badRequest))
            }
        }
    }

    // MARK: Orphaned uploads (user remedy)

    /// Deletes the unfinished objects of the account that no local journal knows (the orphans of lost state: a reinstall, a wiped
    /// app, a crash between a create and its journal record) and that have been idle for `minIdleMs`; returns how many it deleted.
    ///
    /// It NEVER calls `deleteUnfinished`, which would also delete the transfers that are running on this device, the ones paused in
    /// a journal, and the live uploads of the account's other devices. The idle guard is what tells a live upload of another
    /// device from an abandoned one: a part takes up to 17.5 minutes on the slowest link the server accepts, and the default guard is
    /// 10 minutes after the last part, so it is a heuristic (a wrongly deleted upload of another device finds its object gone (404)
    /// and makes it again from the same header, which is safe under the nonce rule).
    ///
    /// It runs inside the gate, so it cannot see an object whose create has answered and whose record is not yet in a journal.
    func sweepOrphans(minIdleMs: Int64) async throws -> Int {
        try await gate.withGate {
            var items: [FileV2UnfinishedItem] = []
            var after: String?
            for _ in 0..<20 {                       // an account holds at most 10 unfinished objects: 20 pages is a hard stop
                let page = try await self.server.listUnfinished(limit: 100, after: after)
                items.append(contentsOf: page.objects)
                guard let next = page.next else { break }
                after = next
            }
            let known = self.knownObjectIDs()
            let now = self.clock.nowMs()
            var deleted = 0
            for item in items {
                if known.contains(Array(item.obj.utf8)) { continue }
                let (idle, overflow) = now.subtractingReportingOverflow(item.activityMs)
                guard !overflow, idle >= minIdleMs else { continue }
                do {
                    try await self.server.delete(obj: item.obj)
                    deleted += 1
                } catch let error as FileV2ServerError where error.status == 404 {
                    continue
                }
            }
            if deleted > 0 { self.record(.orphansDeleted(count: deleted)) }
            return deleted
        }
    }

    /// The objects of every journal on the device, as bytes (object ids are compared as bytes, never as `String`s).
    func knownObjectIDs() -> Set<[UInt8]> {
        var known = Set<[UInt8]>()
        for id in (try? store.listTransferIDs()) ?? [] {
            if let recovered = try? store.load(id), let obj = recovered.object?.obj { known.insert(Array(obj.utf8)) }
        }
        return known
    }

    // MARK: Secrets nobody refers to

    /// Destroys the secrets of the wrapper that no journal refers to: a crash between `wrap` and the begin record, a reinstall that
    /// took the journals away and left the Keychain. Takes the gate, so it cannot meet a transfer that has wrapped its key and not yet written its begin record.
    func purgeOrphanSecrets() async {
        _ = try? await gate.withGate {
            var referenced = Set<Data>()
            for id in (try? self.store.listTransferIDs()) ?? [] {
                guard let recovered = try? self.store.load(id) else { continue }
                referenced.insert(recovered.begin.wrappedKey)
                if let token = recovered.token { referenced.insert(token.wrappedValue) }
            }
            for blob in (try? self.secrets.allBlobs()) ?? [] where !referenced.contains(blob) {
                self.secrets.destroy(blob)
            }
        }
    }
}


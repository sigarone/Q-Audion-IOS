import Foundation

/// The send pipeline of file transfer v2 (WIRE_SPEC 12.7, 12.8, 12.10): preflight, the object on the server, parts in parallel with a
/// resume state that upholds the nonce-reuse rule, `complete`, and the descriptor handed to the chat.
///
/// ```
/// let pipeline = FileV2SendPipeline(dependencies: ..., configuration: ...)
/// let end = await pipeline.send(FileV2SendRequest(source: FileV2FileSource(url: url), conversation: .direct(userID: ...),
///                                                 metadata: FileV2SendMetadata(kind: .file, name: ...)))
/// ```
///
/// What a caller can rely on:
///
/// - Nothing is uploaded unless the chat can carry a descriptor to the conversation (`canCarryDescriptor`), the source is 1 byte to
///   5 GiB, and its identity (`FileV2SourceIdentity`: size, modification time to the nanosecond, inode, creation time, a SHA-256 of
///   its first and last 64 KiB) was captured.
/// - `K` and `file_id` come from the system generator, `K` and the download token are held by the `FileV2SecretWrapper` (the
///   Keychain, `ThisDeviceOnly`, in production), and the journal holds only the blobs the wrapper returned. No key, token, tag,
///   path or full id is ever printed.
/// - The tags of a part are durable in the journal before the part is PUT; a resume re-encrypts from the source and compares every
///   tag with the journal's (`FileV2SendEngine` explains the rule). A changed source cancels the transfer: the object is deleted,
///   the state wiped, the key zeroed, and a new `send` makes a new key and a new `file_id`.
/// - Memory does not depend on the file size, nor on the number of files sent together: at most the adaptive number of sealed parts
///   (8 388 736 bytes each) and the chunk being sealed, within the budget of `FileV2MemBudget`, which is the PIPELINE's: every
///   transfer of the pipeline shares the same slots, so ten files sent at once hold what one does.
/// - `.sentOk` is reported only when the chat SENT the descriptor.
///
/// Task cancellation (the app is going away) stops the workers promptly and keeps the state: the result is `.interrupted` and
/// `resume` goes on from it. Cancelling the TRANSFER is `cancel(transferID:)`.
///
/// ONE WRITER PER TRANSFER. A transfer is run, resumed, announced again or cancelled by one holder at a time, across the pipelines of a
/// process and across the processes that share a store directory (the app and an extension of its App Group): the pipeline takes the
/// store's exclusive lock of the transfer (`FileV2SendStore.acquireLock`, `flock` for the file store) BEFORE it reads the journal, and
/// keeps it until the operation has ended, whatever the way it ends. A second caller gets `.failed(busy)` (or `.busy` from
/// `cancelTransfer`) and touches nothing. Without this, two holders would each build a ledger of tags that lacks what the other
/// sealed, and could seal one chunk from two versions of a file under one nonce (WIRE_SPEC 12.8 rule 2).
///
/// INTEGRATION CONTRACT (what the app that uses the pipeline MUST do):
///
/// - Call `recoverOnLaunch()` once at every launch, before it starts transfers, and only after the device's protected data is
///   available (`FileV2SendDependencies.protectedDataAvailable`; on iOS `UIApplication.shared.isProtectedDataAvailable`). The
///   pipeline does nothing at all while it says no. This call is not optional: the Keychain item that holds a key is
///   `ThisDeviceOnly`, which keeps it off other devices and out of iCloud, but a restore of an ENCRYPTED backup onto the same device
///   brings it back. WIRE_SPEC 12.8 says the key never comes back from a backup; what makes that true here is that the journal (the
///   only thing that refers to the key) is excluded from every backup, and that this call destroys every secret no journal refers
///   to. Do not run it while another process of the App Group is in the middle of starting a transfer.
/// - Use ONE pipeline per store directory in a process, and keep the store directory in a location that is excluded from backup
///   (the store marks it, and refuses to start if it cannot).
/// - Make the chat deduplicate on the `idempotencyKey` of `FileV2DescriptorChannel.announce` (see there).
/// - A process that is suspended while it holds a file lock in a container that other processes share can be terminated by the
///   system (`0xdead10cc` on iOS). If the store directory is in an App Group container, cancel the Tasks of the running transfers
///   before the app is suspended (the background task's expiration handler): the run then ends as `.interrupted`, keeps its state and
///   releases its lock. If only the app uses the directory it can be in the app's own Application Support, where this does not apply.
public final class FileV2SendPipeline: @unchecked Sendable {

    /// What the pipeline keeps about a transfer that is running in this process.
    private final class ActiveTransfer: @unchecked Sendable {
        private let lock = NSLock()
        private var runTask: Task<FileV2SendState, Never>?
        private var completion: Task<FileV2SendState, Never>?
        private var cancelRequested = false

        var isCancelRequested: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelRequested
        }

        /// Called before the entry is visible in the table, inside the table's critical section: an entry anyone can find is attached.
        func attach(run: Task<FileV2SendState, Never>, completion: Task<FileV2SendState, Never>) {
            lock.lock()
            self.runTask = run
            self.completion = completion
            lock.unlock()
        }

        func requestCancel() -> Task<FileV2SendState, Never>? {
            lock.lock()
            cancelRequested = true
            let task = runTask
            let finished = completion
            lock.unlock()
            task?.cancel()
            return finished
        }
    }

    private enum Prepared {
        case engine(FileV2SendEngine)
        case terminal(FileV2SendState)
    }

    private enum Admission {
        case started(run: Task<FileV2SendState, Never>, completion: Task<FileV2SendState, Never>)
        case refused(FileV2SendFailure.Reason)
    }

    let context: FileV2SendContext
    private let active = FileV2Locked<[String: ActiveTransfer]>([:])

    public init(dependencies: FileV2SendDependencies, configuration: FileV2SendConfiguration = FileV2SendConfiguration()) {
        self.context = FileV2SendContext(dependencies: dependencies, configuration: configuration)
    }

    /// The most the pipeline held in memory and in how many parts, since it was made.
    public var diagnostics: FileV2SendDiagnostics { context.gauge.diagnostics }

    // MARK: Sending

    /// Sends a file: preflight, then upload, then the descriptor. Returns when the transfer ends or is interrupted.
    @discardableResult
    public func send(_ request: FileV2SendRequest, onState: FileV2SendStateSink? = nil) async -> FileV2SendState {
        guard fileV2IsValidTransferID(request.transferID) else {
            return Self.report(.failed(FileV2SendFailure(.badRequest)), to: onState)
        }
        let context = self.context
        return await runRegistered(id: request.transferID, onState: onState) { isCancelled in
            switch await Self.prepareNew(context, request, onState, isCancelled) {
            case .engine(let engine): return await engine.run()
            case .terminal(let terminal): return terminal
            }
        }
    }

    /// Goes on with a transfer whose state is on the device (a restart, a pause that kept its state, a descriptor the chat did not
    /// take): takes the transfer's lock (`.failed(busy)` if another holder has it), rebuilds the nonce ledger from the journal,
    /// checks that the source is unchanged, finds the object again (create is idempotent on the header), asks the server which
    /// parts it has, and uploads only the missing ones. A transfer that was completed only announces again, with no upload and
    /// WITHOUT looking at the source: the descriptor describes the blob that is on the server, which was complete and was checked when
    /// it was sealed, and a source that is gone or was saved again since does not change that (the source is checked, as always, if
    /// the server lost the object and an upload becomes necessary again).
    @discardableResult
    public func resume(transferID: String, onState: FileV2SendStateSink? = nil) async -> FileV2SendState {
        guard fileV2IsValidTransferID(transferID) else {
            return Self.report(.failed(FileV2SendFailure(.badRequest)), to: onState)
        }
        let context = self.context
        return await runRegistered(id: transferID, onState: onState) { isCancelled in
            switch await Self.prepareResume(context, transferID, onState, isCancelled) {
            case .engine(let engine): return await engine.run()
            case .terminal(let terminal): return terminal
            }
        }
    }

    /// Cancels a transfer: the workers stop promptly, the object is deleted on the server (404 is success), `qa_file_cancel` goes
    /// through the chat if a descriptor may have been sent, the key and the token are destroyed and the journal removed. A cancelled
    /// transfer leaves nothing on the disk or in the Keychain. Works on a transfer that is running and on one that only has state.
    /// Returns whether there was a transfer to cancel.
    ///
    /// `false` when there was nothing to cancel AND when another holder (another pipeline, another process) has the transfer: use
    /// `cancelTransfer` to tell the two apart.
    @discardableResult
    public func cancel(transferID: String) async -> Bool {
        await cancelTransfer(transferID: transferID) == .cancelled
    }

    /// `cancel` with a result that says what happened. A transfer that is running in this pipeline is cancelled through its run (it
    /// stops, then the clean-up runs while the lock is still held); one that only has state is cancelled under the lock taken here; one
    /// that another holder has is left alone (`.busy`).
    public func cancelTransfer(transferID: String) async -> FileV2CancelOutcome {
        guard fileV2IsValidTransferID(transferID) else { return .nothingToCancel }
        // An entry that anyone can find is already attached to its tasks (see `runRegistered`): there is no window in which the
        // transfer is registered and cannot be cancelled.
        if let entry = active.withValue({ $0[transferID] }), let completion = entry.requestCancel() {
            let final = await completion.value           // the running task has stopped and the clean-up is done
            return final == .failed(FileV2SendFailure(.cancelled)) ? .cancelled : .nothingToCancel
        }
        let lock: FileV2SendTransferLock
        do { lock = try context.store.acquireLock(transferID) } catch FileV2SendStoreError.busy { return .busy } catch {
            return .storageUnavailable
        }
        defer { lock.release() }
        return await context.cleanup(transferID: transferID) ? .cancelled : .nothingToCancel
    }

    // MARK: Restart

    /// The transfers whose state is on the device. A journal that cannot be read is not listed.
    public func listResumable() async -> [FileV2ResumableTransfer] {
        let running = active.withValue { Set($0.keys) }
        var out: [FileV2ResumableTransfer] = []
        for id in (try? context.store.listTransferIDs()) ?? [] {
            guard let recovered = try? context.store.load(id) else { continue }
            out.append(FileV2ResumableTransfer(transferID: id, phase: recovered.phase, conversation: recovered.begin.conversation,
                                               source: recovered.begin.source, createdMs: recovered.begin.createdMs,
                                               confirmedParts: recovered.confirmedParts.count, isRunning: running.contains(id)))
        }
        return out
    }

    /// Run once at every launch, before any transfer starts (the integration contract is in the documentation of the class): destroys
    /// the secrets of the wrapper that no journal refers to (a crash between the wrapping of a key and its begin record, a reinstall
    /// that took the journals away and left the Keychain, a Keychain item that came back with a restored backup), and finishes the
    /// clean-up of transfers that were being cancelled when the app died.
    ///
    /// It DECIDES NOTHING FROM WHAT IT CANNOT READ. It does nothing while the protected data is unavailable
    /// (`FileV2SendDependencies.protectedDataAvailable`), and it stops, with every secret in place, when the journals cannot be listed
    /// or when one cannot be read for a reason other than being corrupt (see `FileV2SendContext.purgeOrphanSecrets`). Returns whether
    /// the purge ran to its end; when it did not, run it again at the next launch or when the data is available.
    @discardableResult
    public func recoverOnLaunch() async -> Bool {
        guard await context.protectedDataIsAvailable() else { return false }
        let ids: [String]
        do { ids = try context.store.listTransferIDs() } catch { return false }
        for id in ids {
            // A journal that cannot be read is left alone here (the purge below stops on it too); one that says `cancelled` is finished
            // under the transfer's lock, and skipped when another holder has it.
            guard let recovered = try? context.store.load(id), recovered.phase == .cancelled else { continue }
            guard let lock = try? context.store.acquireLock(id) else { continue }
            await context.cleanup(transferID: id)
            lock.release()
        }
        return await context.purgeOrphanSecrets()
    }

    /// Deletes the unfinished objects of the account that are in no local journal and have been idle for `minIdleMs` (the orphans of lost
    /// state), never the account's other unfinished objects. A user interface that has told the user what this does may pass 0 to
    /// include objects that are less than the default idle time old. Returns how many it deleted. Throws, and deletes nothing, while the
    /// protected data is unavailable or the journals cannot be read (an object whose journal could not be read looks like an orphan and
    /// is not one).
    public func discardOrphanedUploads(minIdleMs: Int64? = nil) async throws -> Int {
        try await context.sweepOrphans(minIdleMs: minIdleMs ?? context.config.orphanMinIdleMs)
    }

    // MARK: The registry

    /// Admits a transfer and runs `work` for it. In ONE critical section of the registry: the entry is checked against the registry (one
    /// run per id in this pipeline), the store's exclusive lock of the transfer is taken (one run per id across pipelines and
    /// processes), the tasks are made and attached to the entry, and only then is the entry made visible. So `cancelTransfer` either
    /// finds a transfer it can fully cancel, or does not find it and takes the lock itself (and the run, if it comes, gets `busy`):
    /// there is no moment in which the transfer is registered and cannot be cancelled.
    ///
    /// The lock is held by the completion task, which gives it up on its last line, after the clean-up of a cancel: every path of the
    /// run ends there.
    private func runRegistered(id: String, onState: FileV2SendStateSink?,
                               _ work: @escaping @Sendable (@escaping @Sendable () -> Bool) async -> FileV2SendState) async -> FileV2SendState {
        let entry = ActiveTransfer()
        let context = self.context
        let table = self.active
        let admission = table.withValue { registry -> Admission in
            guard registry[id] == nil else { return .refused(.alreadyRunning) }
            let lock: FileV2SendTransferLock
            do { lock = try context.store.acquireLock(id) } catch FileV2SendStoreError.busy { return .refused(.busy) } catch {
                return .refused(.storage)
            }
            let runTask = Task { await work({ entry.isCancelRequested }) }
            let completion = Task { () -> FileV2SendState in
                var finalState = await runTask.value
                if entry.isCancelRequested && Self.endedWithState(finalState) {
                    // The user cancelled: the workers have stopped, now the clean-up (it must not run under a cancelled task).
                    await context.cleanup(transferID: id)
                    finalState = Self.report(.failed(FileV2SendFailure(.cancelled)), to: onState)
                    context.record(.finished(code: "cancelled"))
                }
                lock.release()
                table.withValue { $0[id] = nil }
                return finalState
            }
            entry.attach(run: runTask, completion: completion)
            registry[id] = entry
            return .started(run: runTask, completion: completion)
        }
        switch admission {
        case .refused(let reason):
            return Self.report(.failed(FileV2SendFailure(reason)), to: onState)
        case .started(let runTask, let completion):
            return await withTaskCancellationHandler { await completion.value } onCancel: { runTask.cancel() }
        }
    }

    /// A run that ended and left the transfer's state on the device (interrupted, or paused by a failure that keeps it): a cancel that was
    /// asked for before the run ended has still to finish the job.
    private static func endedWithState(_ state: FileV2SendState) -> Bool {
        switch state {
        case .interrupted: return true
        case .failed(let failure): return failure.keepsState
        default: return false
        }
    }

    private static func report(_ state: FileV2SendState, to sink: FileV2SendStateSink?) -> FileV2SendState {
        sink?(state)
        return state
    }

    // MARK: Preflight and begin (a new transfer)

    private static func prepareNew(_ context: FileV2SendContext, _ request: FileV2SendRequest, _ onState: FileV2SendStateSink?,
                                   _ isCancelled: @escaping @Sendable () -> Bool) async -> Prepared {
        func refuse(_ reason: FileV2SendFailure.Reason) -> Prepared {
            let failure = FileV2SendFailure(reason)
            sinkReport(.failed(failure), onState)
            context.record(.finished(code: reason.rawValue))
            return .terminal(.failed(failure))
        }
        onState?(.preparing)

        // The source: 1 byte to 5 GiB, and its identity (path, size, modification time), captured now.
        let identity: FileV2SourceIdentity
        do { identity = try request.source.currentIdentity() } catch { return refuse(.sourceUnavailable) }
        guard identity.size >= 1 else { return refuse(.emptySource) }
        guard identity.size <= FileV2.maxSize else { return refuse(.sourceTooLarge) }

        // WIRE_SPEC 12.7: if the channel cannot send a text message to the conversation, the file MUST NOT be sent either. Asked before
        // anything is generated, wrapped or uploaded.
        guard await context.deps.channel.canCarryDescriptor(to: request.conversation) else { return refuse(.channelUnavailable) }

        guard request.metadata.kind != nil else { return refuse(.badRequest) }

        // The descriptor must fit in 8 KiB (the builder drops the waveform, the preview and the thumbnail first): refuse now, not after the upload.
        guard descriptorFits(request.metadata, size: identity.size) else { return refuse(.descriptorTooLarge) }

        if Task.isCancelled || isCancelled() { return .terminal(.interrupted) }

        // The key material and the begin record are one critical section: a launch-time purge of orphaned secrets must never see a
        // wrapped key that no journal refers to yet.
        let begun: (FileV2Encryptor, FileV2SendBeginRecord)
        do {
            begun = try await context.gate.withGate {
                let encryptor = try FileV2Encryptor.makeNew(plaintextSize: identity.size)
                var key = encryptor.fileKey
                defer { FileV2Secret.wipe(&key) }
                let wrapped: Data
                do { wrapped = try context.secrets.wrap(key) } catch {
                    encryptor.close()
                    throw error
                }
                let record = FileV2SendBeginRecord(
                    transferID: request.transferID, createdMs: context.clock.nowMs(), fileID: encryptor.fileID,
                    header: encryptor.header.bytes, wrappedKey: wrapped, plaintextSize: identity.size, source: identity,
                    conversation: request.conversation, metadata: request.metadata)
                do { try context.store.begin(record) } catch {
                    context.secrets.destroy(wrapped)
                    encryptor.close()
                    throw error
                }
                return (encryptor, record)
            }
        } catch is CancellationError {
            return .terminal(.interrupted)
        } catch FileV2SendStoreError.alreadyExists {
            return refuse(.alreadyRunning)
        } catch {
            return refuse(.storage)
        }
        context.record(.started(resumed: false))
        return .engine(FileV2SendEngine(context: context, begin: begun.1, encryptor: begun.0, source: request.source,
                                        recovered: nil, onState: onState, isUserCancelled: isCancelled))
    }

    private static func sinkReport(_ state: FileV2SendState, _ sink: FileV2SendStateSink?) { sink?(state) }

    /// Builds the descriptor of a file of `size` bytes with a throwaway key and the longest object id and token the format allows.
    private static func descriptorFits(_ metadata: FileV2SendMetadata, size: UInt64) -> Bool {
        guard let kind = metadata.kind, let encryptor = try? FileV2Encryptor.makeNew(plaintextSize: size) else { return false }
        defer { encryptor.close() }
        let token = FileV2Descriptor.Token(v: String(repeating: "0", count: FileV2.tokenValueHexLength),
                                           exp: FileV2.maxJSONInteger, max: FileV2.maxTokenMax)
        let source = FileV2Descriptor.Source(via: .srv, obj: "00000000-0000-0000-0000-000000000000", token: token)
        let file = FileV2FileInput(encryptor: encryptor, kind: kind, source: source, name: metadata.name, mimeType: metadata.mimeType,
                                   media: metadata.media?.descriptorMedia, preview: metadata.preview, ex: metadata.ex, xp: metadata.xp)
        return (try? FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: file))) != nil
    }

    // MARK: Reading a journal (a resume)

    private static func prepareResume(_ context: FileV2SendContext, _ id: String, _ onState: FileV2SendStateSink?,
                                      _ isCancelled: @escaping @Sendable () -> Bool) async -> Prepared {
        func refuse(_ reason: FileV2SendFailure.Reason, cleanUp: Bool) async -> Prepared {
            if cleanUp { await context.cleanup(transferID: id) }
            if reason == .sourceChanged { context.record(.contentChanged) }
            let failure = FileV2SendFailure(reason)
            sinkReport(.failed(failure), onState)
            context.record(.finished(code: reason.rawValue))
            return .terminal(.failed(failure))
        }
        onState?(.preparing)

        let recovered: FileV2SendRecovered
        do { recovered = try context.store.load(id) } catch FileV2SendStoreError.notFound {
            return await refuse(.stateLost, cleanUp: false)
        } catch {
            // A journal that cannot be read: nothing in it can be trusted (the nonce rule needs its tags). Remove it.
            return await refuse(.stateLost, cleanUp: true)
        }
        let begin = recovered.begin

        // A transfer whose cancel was interrupted: finish it.
        if recovered.phase == .cancelled {
            await context.cleanup(transferID: id)
            let failure = FileV2SendFailure(.cancelled)
            sinkReport(.failed(failure), onState)
            return .terminal(.failed(failure))
        }
        // Two records that disagree about the tag of a chunk: the journal cannot vouch for the nonce rule.
        if recovered.hasConflictingTags { return await refuse(.stateLost, cleanUp: true) }

        // Rule 1 of 12.8: the source's identity changed: cancel (new `K` and `file_id` if the caller restarts). Only a transfer that
        // may still have to upload needs its source now. One whose upload is over (completed, being announced, announce pending)
        // only announces again: nothing is sealed, no tag is compared, and the blob on the server is complete, so the source is not
        // looked at, and a source that is gone (a temporary copy the system purged) does not destroy an uploaded blob. If the server
        // lost the object and an upload becomes necessary again, the engine finds and verifies the source then (rule 1), and not before.
        var source: FileV2SendSource?
        if recovered.phase == .uploading {
            do {
                let found = try context.deps.sources.source(for: begin.source)
                guard try found.currentIdentity().isUnchanged(comparedTo: begin.source) else { throw FileV2SendSourceError.unavailable }
                source = found
            } catch {
                return await refuse(.sourceChanged, cleanUp: true)
            }
        }

        // The key: if its secret is gone (the Keychain was restored or reset) the transfer cannot be carried on.
        var key: Data
        do { key = try context.secrets.unwrap(begin.wrappedKey) } catch { return await refuse(.stateLost, cleanUp: true) }
        defer { FileV2Secret.wipe(&key) }

        // The encryptor starts with the journal's tags: the ledger is loaded at construction, there is no way to resume with an empty one.
        let encryptor: FileV2Encryptor
        do {
            encryptor = try FileV2Encryptor.resume(fileKey: key, fileID: begin.fileID, plaintextSize: begin.plaintextSize,
                                                   persistedTags: recovered.tags)
        } catch {
            return await refuse(.stateLost, cleanUp: true)
        }
        guard encryptor.header.bytes == begin.header else {
            encryptor.close()
            return await refuse(.stateLost, cleanUp: true)
        }
        if Task.isCancelled || isCancelled() {
            encryptor.close()
            return .terminal(.interrupted)
        }
        context.record(.started(resumed: true))
        return .engine(FileV2SendEngine(context: context, begin: begin, encryptor: encryptor, source: source, recovered: recovered,
                                        onState: onState, isUserCancelled: isCancelled))
    }
}

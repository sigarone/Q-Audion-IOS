import Foundation

// The requests of a transfer that are not part uploads: create, the parts map, complete and the download token. Each goes through
// `FileV2SendContext.request`, which applies the disposition table (retry with backoff and `Retry-After`, refresh of the access
// token, 404 means the object is gone, ...).

extension FileV2SendEngine {

    enum ObjectResult {
        case ready(FileV2Created)
        case terminal(FileV2SendState)
    }

    enum MapResult {
        case map(FileV2PartsMap)
        case recreate
        case terminal(FileV2SendState)
    }

    enum CompleteOutcome {
        case done
        case recreate
        /// 409 `incomplete`: the server lacks parts the transfer believed it had.
        case incomplete
        case terminal(FileV2SendState)
    }

    // MARK: Create

    /// The token the create asks for: `max_uses` 30 for a 1:1 conversation, the group scope for a group (the server checks
    /// membership at download time).
    func tokenRequest() -> FileV2TokenRequest {
        switch begin.conversation.kind {
        case .direct:
            return .forRecipient(begin.conversation.id, ttlSeconds: ctx.config.tokenTTLSeconds, maxUses: ctx.config.directMaxUses)
        case .group:
            return .forGroup(begin.conversation.id, ttlSeconds: ctx.config.tokenTTLSeconds, maxUses: ctx.config.groupMaxUses)
        }
    }

    /// Creates the object, or finds the one this transfer left (create is idempotent on the header), and journals it.
    ///
    /// The create and the journal write of its object are one critical section (the gate), so that an orphan sweep of another
    /// transfer never meets an object that exists on the server and in no journal. When the account is at its limit of unfinished
    /// uploads or objects (or its quota), the orphans of lost state are deleted and the create is repeated ONCE; if that frees
    /// nothing the user is told to delete something.
    func ensureObject() async -> ObjectResult {
        var remedyTried = false
        while true {
            let request = FileV2CreateRequest(blobLength: blobLength, head: encryptor.header.bytes, partSize: FileV2Wire.partSize,
                                              token: tokenRequest())
            let result: FileV2RequestResult<FileV2Created> = await ctx.request(.create) {
                try await self.ctx.gate.withGate {
                    let created = try await self.ctx.server.create(request)
                    try self.accept(created)
                    return created
                }
            }
            switch result {
            case .value(let created):
                return .ready(created)
            case .interrupted:
                return .terminal(interrupted())
            case .failure(let failure):
                if failure.code == "quota_exceeded", !remedyTried {
                    remedyTried = true
                    if await freeOrphans() { continue }
                }
                return .terminal(await end(failure))
            case .userRemedy(let error):
                if !remedyTried {
                    remedyTried = true
                    if await freeOrphans() { continue }
                }
                return .terminal(await end(FileV2SendFailure(.userRemedy, transferError: .quota, details: error.details, code: error.code)))
            case .recreate, .done, .sendMissing:
                return .terminal(await end(FileV2SendFailure(transfer: .badRequest)))
            }
        }
    }

    private func freeOrphans() async -> Bool {
        let deleted = (try? await ctx.sweepOrphans(minIdleMs: ctx.config.orphanMinIdleMs)) ?? 0
        return deleted > 0
    }

    /// Checks what the server answered and journals the object (when it is new) and the token. Runs inside the gate. Throws
    /// `FileV2WireFormatError` for an answer that does not describe the object this transfer asked for, and a store error when the
    /// journal cannot be written (the create then counts as failed and is repeated: it is idempotent).
    func accept(_ created: FileV2Created) throws {
        guard created.partSize == FileV2Wire.partSize, created.blobLength == blobLength, created.parts == totalParts,
              FileV2Descriptor.isValidObjectID(Array(created.obj.utf8)) else {
            throw FileV2WireFormatError.malformedAnswer
        }
        let previous = state.withValue { $0.object }
        let sameObject = previous.map { Array($0.obj.utf8) == Array(created.obj.utf8) } ?? false
        if !sameObject {
            let record = FileV2SendObjectRecord(obj: created.obj, blobLength: blobLength, parts: totalParts)
            try ctx.store.append(.object(record), to: id)
            state.withValue { current in
                current.object = record
                current.doneParts = []
                current.bytesDone = 0
                // A new object has no part and is not complete: the journal's replay does the same on this record.
                if current.phase == .completed || current.phase == .announcing || current.phase == .announcePending {
                    current.phase = .uploading
                }
            }
        }
        state.withValue { $0.objectAcknowledged = true }
        if let token = created.token { try accept(token) }
        let clock = ctx.clock
        let memoryCap = ctx.maxParallelismByMemory
        let metered = ctx.config.metered
        state.withValue { current in
            if current.parallelism == nil {
                current.parallelism = FileV2AdaptiveParallelism(
                    serverParallelism: created.parallelism, serverMaxParallelism: created.maxParallelism,
                    memoryCap: memoryCap, metered: metered, startMs: clock.monotonicMs())
            }
        }
    }

    /// Wraps a token the server issued, journals it, and destroys the one it replaces. The token is a secret: it goes into the
    /// descriptor and nowhere else.
    func accept(_ token: FileV2IssuedToken) throws {
        let wrapped: Data
        do { wrapped = try ctx.secrets.wrap(Data(token.v.utf8)) } catch { throw FileV2SendStoreError.io("secret") }
        let record = FileV2SendTokenRecord(wrappedValue: wrapped, exp: token.exp, max: token.max, scope: token.scope)
        do { try ctx.store.append(.token(record), to: id) } catch {
            ctx.secrets.destroy(wrapped)
            throw error
        }
        let old = state.withValue { current -> FileV2SendTokenRecord? in
            let previous = current.tokenRecord
            current.tokenRecord = record
            return previous
        }
        if let old = old { ctx.secrets.destroy(old.wrappedValue) }
    }

    // MARK: The parts map

    func fetchPartsMap() async -> MapResult {
        guard let obj = state.withValue({ $0.object?.obj }) else { return .terminal(await end(FileV2SendFailure(.badRequest))) }
        let result: FileV2RequestResult<FileV2PartsMap> = await ctx.request(.partsMap) {
            try await self.ctx.server.partsMap(obj: obj)
        }
        switch result {
        case .value(let map):
            guard map.blobLength == blobLength, map.partSize == FileV2Wire.partSize, map.parts == totalParts else {
                return .terminal(await end(FileV2SendFailure(.badRequest)))
            }
            return .map(map)
        case .recreate:
            return .recreate
        case .interrupted:
            return .terminal(interrupted())
        case .failure(let failure):
            return .terminal(await end(failure))
        case .done, .userRemedy, .sendMissing:
            return .terminal(await end(FileV2SendFailure(.badRequest)))
        }
    }

    // MARK: Complete

    /// Asks the server to close the object, once every part is up. Checks the source one more time first: a source that grew or was
    /// edited while it was being read would give a blob that mixes two versions.
    func completeObject(alreadyComplete: Bool) async -> CompleteOutcome {
        emit(.completing)
        if !alreadyComplete {
            guard sourceIsUnchanged() else { return .terminal(await end(FileV2SendFailure(.sourceChanged))) }
            guard let obj = state.withValue({ $0.object?.obj }) else { return .terminal(await end(FileV2SendFailure(.badRequest))) }
            let result: FileV2RequestResult<Bool> = await ctx.request(.complete) {
                try await self.ctx.server.complete(obj: obj)
                return true
            }
            switch result {
            case .value, .done:
                break
            case .recreate:
                return .recreate
            case .sendMissing:
                return .incomplete
            case .interrupted:
                return .terminal(interrupted())
            case .failure(let failure):
                return .terminal(await end(failure))
            case .userRemedy:
                return .terminal(await end(FileV2SendFailure(.badRequest)))
            }
        }
        do { try ctx.store.append(.phase(.completed), to: id) } catch { return .terminal(await end(FileV2SendFailure(.storage))) }
        state.withValue { $0.phase = .completed }
        return .done
    }
}

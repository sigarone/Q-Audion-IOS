import Foundation

// The end of a transfer: the download token, the descriptor, and the hand-over to the chat. The transfer is reported as sent only when
// the chat says it SENT the descriptor.

extension FileV2SendEngine {

    enum AnnounceOutcome {
        case finished(FileV2SendState)
        /// The server deleted the object (404 on the token request): a new one is needed.
        case recreate
    }

    enum TokenResult {
        case ready(FileV2Descriptor.Token)
        case recreate
        case terminal(FileV2SendState)
    }

    func announce() async -> AnnounceOutcome {
        emit(.announcing)

        let token: FileV2Descriptor.Token
        switch await ensureToken() {
        case .ready(let value): token = value
        case .recreate: return .recreate
        case .terminal(let terminal): return .finished(terminal)
        }

        let body: String
        do {
            body = try buildDescriptor(token: token)
        } catch {
            return .finished(await end(FileV2SendFailure(transfer: .descriptorTooLarge)))
        }

        // The phase is durable BEFORE the descriptor is handed over: a crash in between leaves "it may have gone out", and a cancel
        // after that sends `qa_file_cancel`.
        do { try ctx.store.append(.phase(.announcing), to: id) } catch { return .finished(await end(FileV2SendFailure(.storage))) }
        state.withValue { current in
            current.phase = .announcing
            current.maybeAnnounced = true
        }

        let outcome = await ctx.deps.channel.announce(body, to: begin.conversation, idempotencyKey: id)
        // A cancelled task does not know what the chat did with the descriptor: the phase stays `announcing` (it MAY have gone out), and
        // whatever comes next (a resume, a cancel) acts on that.
        if Task.isCancelled || isUserCancelled() { return .finished(interrupted()) }

        switch outcome {
        case .sent:
            await ctx.finishDelivered(transferID: id)
            emit(.sentOk)
            ctx.record(.finished(code: "sent"))
            return .finished(.sentOk)
        case .queued:
            // The chat owns the message now (its outbox holds the descriptor, key and token included): this side is done.
            await ctx.finishDelivered(transferID: id)
            emit(.sentAnnouncePending)
            ctx.record(.finished(code: "announce_pending"))
            return .finished(.sentAnnouncePending)
        case .unavailable:
            // The blob is on the server and stays: a retry only announces again, with no upload.
            try? ctx.store.append(.phase(.announcePending), to: id)
            state.withValue { $0.phase = .announcePending }
            return .finished(await end(FileV2SendFailure(transfer: .announceNotSent)))
        }
    }

    /// The token for the descriptor: the one the create returned, unwrapped, unless it is missing, unreadable (its secret is gone) or
    /// about to expire, in which case the server issues a new one (allowed at any time, before or after the object is complete).
    func ensureToken() async -> TokenResult {
        let now = ctx.clock.nowMs()
        let margin = ctx.config.tokenRefreshMarginMs
        if let record = state.withValue({ $0.tokenRecord }), record.exp == 0 || record.exp > now &+ margin {
            if var secret = try? ctx.secrets.unwrap(record.wrappedValue) {
                defer { FileV2Secret.wipe(&secret) }
                if let value = String(data: secret, encoding: .utf8) {
                    return .ready(FileV2Descriptor.Token(v: value, exp: record.exp, max: Int64(record.max)))
                }
            }
        }
        guard let obj = state.withValue({ $0.object?.obj }) else { return .terminal(await end(FileV2SendFailure(.badRequest))) }
        let scope = tokenRequest()
        let result: FileV2RequestResult<FileV2IssuedToken> = await ctx.request(.issueToken) {
            try await self.ctx.server.issueToken(obj: obj, scope: scope)
        }
        switch result {
        case .value(let issued):
            do { try accept(issued) } catch { return .terminal(await end(FileV2SendFailure(.storage))) }
            return .ready(FileV2Descriptor.Token(v: issued.v, exp: issued.exp, max: Int64(issued.max)))
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

    /// The descriptor of the file, by the library's builder: `src` via `srv` with the object and the token exactly as the server returned
    /// them. The key comes from the encryptor, which is open for the whole run.
    func buildDescriptor(token: FileV2Descriptor.Token) throws -> String {
        guard let kind = begin.metadata.kind, let obj = state.withValue({ $0.object?.obj }) else {
            throw FileV2Error.invalidArgument("descriptor input")
        }
        let metadata = begin.metadata
        let file = FileV2FileInput(encryptor: encryptor, kind: kind,
                                   source: FileV2Descriptor.Source(via: .srv, obj: obj, token: token),
                                   name: metadata.name, mimeType: metadata.mimeType, media: metadata.media?.descriptorMedia,
                                   preview: metadata.preview, ex: metadata.ex, xp: metadata.xp)
        return try FileV2DescriptorBuilder.build(FileV2DescriptorInput(file: file))
    }
}

extension FileV2SendContext {

    /// The end of a transfer whose descriptor the chat has taken (sent or queued): the secrets are destroyed and the journal removed.
    /// The blob stays on the server for the recipients: this does NOT delete the object.
    func finishDelivered(transferID id: String) async {
        if let recovered = try? store.load(id) {
            secrets.destroy(recovered.begin.wrappedKey)
            if let token = recovered.token { secrets.destroy(token.wrappedValue) }
        }
        try? store.remove(id)
    }
}

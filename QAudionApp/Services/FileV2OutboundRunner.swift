import Foundation
import QAudionEngine

/// One send of a file (a document, an image, a voice note, a video), from the prepared file to the message that carries its
/// descriptor (file transfer v2, WIRE_SPEC section 12). The engine's `FileV2Sender` does the upload; this is the part that needs the
/// app: the limit on sends running together, the leftovers of a killed send, and the way the descriptor reaches the chat.
///
/// Two ways of delivering the descriptor share the same run (`run(key:request:appState:onProgress:deliver:)`):
///
///   - a 1:1 chat (`run(_:sendService:appState:onProgress:)`): the row of the file BECOMES the message that carries the descriptor and
///     the durable end-to-end send seals it (or queues it for the outbox);
///   - a group (`GroupFileV2Send`): the descriptor is sealed into the group payload with `msg_type` 1.
///
/// Static functions with every dependency passed in, so that the send does not depend on the chat screen still being there: the
/// caller only listens to the progress and to the end.
@MainActor
enum FileV2OutboundRunner {

    /// What one 1:1 send needs. Nothing here is secret: the key, the file id and the token exist only inside the engine's sender and
    /// the descriptor it hands back.
    struct Context {
        let messageId: UUID
        let conversationId: UUID
        let peerUserId: String
        /// What the row shows while it has no descriptor (`📎 name`, `📷 Foto`, ...).
        let displayText: String
        /// The row's `mediaMimeType` while it has no descriptor: `FileV2ChatBody.pendingMime(kind:)`.
        let pendingMime: String
        let kind: FileV2Descriptor.Kind
        let sourceURL: URL
        /// The picked name, as the descriptor's `nm` (the engine cuts it to 255 bytes).
        let name: String
        let mimeType: String
        let media: FileV2Descriptor.Media?
        let preview: Data?
        let thumbnailURL: URL?
        /// The descriptor's `ex` (-1 view once, N seconds); `nil` when there is no timer.
        let ex: Int64?
        /// The descriptor's `xp`: 0 export blocked; `nil` = allowed.
        let xp: Int64?
    }

    /// The rows of the sends running in THIS process (a 1:1 message id, or the id of a group row). A row of a file that is still
    /// "sending" and is not here belongs to a send the system ended (the app was closed, or killed, while it uploaded): it will never
    /// finish, and the chat marks it failed.
    private static var inFlight: Set<String> = []

    /// At most this many sends run together: each one holds up to two objects on the server (the file and its thumbnail) and the
    /// account may have ten unfinished at a time, so a batch of photos goes through in turns instead of being refused.
    private static let gate = SendGate()

    static func isInFlight(_ messageId: UUID) -> Bool { inFlight.contains(messageId.uuidString) }

    /// The same for a send named by a key (the id of a group row).
    static func isInFlight(key: String) -> Bool { inFlight.contains(key) }

    /// Runs the 1:1 send to its end. Returns `nil` when the descriptor was handed to the chat (sent, or queued in the outbox for the
    /// moment the connection is back), otherwise the failure. A failure after the upload has deleted the objects on the server (the
    /// engine does it), so nothing is left that counts against the account's quota.
    static func run(
        _ context: Context,
        sendService: ChatMessageSendService,
        appState: AppState,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void
    ) async -> FileV2Failure? {
        let request = FileV2Sender.Request(
            sourceURL: context.sourceURL, kind: context.kind, name: context.name, mimeType: context.mimeType,
            audience: .recipient(context.peerUserId), media: context.media, preview: context.preview,
            thumbnail: context.thumbnailURL.map { FileV2Sender.Thumbnail(sourceURL: $0) }, ex: context.ex, xp: context.xp)
        let store = ConversationStore()
        return await run(key: context.messageId.uuidString, request: request, appState: appState, onProgress: onProgress,
                         deliver: { body in
                             try await deliverToChat(body, context: context, sendService: sendService, store: store)
                         })
    }

    /// Runs a send whose descriptor goes where `deliver` puts it. When the server says the account has no room for another object (too
    /// many unfinished uploads, or the quota) and this is the only send running here, the leftovers of a send that was killed
    /// (unfinished objects idle for 30 minutes or more, deleted one by one) are deleted and the send is tried once more: they hold
    /// quota and slots for hours otherwise. A younger unfinished object may be the live upload of another device of the account and
    /// is left alone, and a completed object is never touched; if the room is still not there, the failure (with the numbers of the
    /// quota) is what the user reads.
    static func run(
        key: String,
        request: FileV2Sender.Request,
        appState: AppState,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void,
        deliver: @escaping @MainActor (String) async throws -> Void
    ) async -> FileV2Failure? {
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let server = FileV2AppServices.makeServer(appState: appState)

        await gate.acquire()
        var failure = await attempt(request, server: server, onProgress: onProgress, deliver: deliver)
        if let first = failure, isNoRoomOnServer(first), inFlight.count == 1 {
            if let deleted = try? await FileV2UnfinishedCleanup.run(server: server), deleted > 0 {
                RTLog.info("chat", "filev2 cleanup deleted=\(deleted)")
                failure = await attempt(request, server: server, onProgress: onProgress, deliver: deliver)
            }
        }
        await gate.release()
        if failure == nil { RTLog.info("chat", "filev2 send ok=1") }
        return failure
    }

    private static func isNoRoomOnServer(_ failure: FileV2Failure) -> Bool {
        guard case .transfer(.quota) = failure.reason, let server = failure.server else { return false }
        return server.code == "too_many_uploads" || server.code == "quota_exceeded"
    }

    private static func attempt(
        _ request: FileV2Sender.Request,
        server: FileV2Server,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void,
        deliver: @escaping @MainActor (String) async throws -> Void
    ) async -> FileV2Failure? {
        let sender = FileV2Sender(server: server)
        do {
            try await sender.send(request, progress: { done, total in
                Task { @MainActor in onProgress(done, total) }
            }, deliver: { body in
                try await deliver(body)
            })
            return nil
        } catch let failure as FileV2Failure {
            return failure
        } catch is CancellationError {
            return FileV2Failure.transfer(.network)
        } catch {
            return FileV2Failure(.unreadable)
        }
    }

    private struct DescriptorRefused: Error {}

    /// The descriptor is a text message like any other, so it takes the same road: the row of the file BECOMES the message that
    /// carries it (the outbox re-seals the text of the row at transmit time, so the row has to hold the descriptor before the
    /// send), and `sendEncryptedDurable` seals it and either sends it or, when the socket is not there, queues it for the outbox.
    /// Either way the file counts as announced. Only a refusal before anything was sealed (no key, no session, not signed in)
    /// fails: the row goes back to its name and the engine deletes the upload.
    private static func deliverToChat(_ body: String, context: Context, sendService: ChatMessageSendService,
                                      store: ConversationStore) async throws {
        let msgId = context.messageId
        store.replaceContent(id: msgId, plaintext: body, mediaMimeType: nil)
        // The delivery and read receipts of a file travel as `qa_att_receipt:1` named by the file id (WIRE_SPEC 12.7.6), not by the
        // server id of the message, so the row has to hold that name before the descriptor leaves: the first receipt can come back at
        // any moment after it.
        if let wireId = FileV2ChatBody.receiptId(ofBody: body) {
            store.setWireAttachmentId(id: msgId, wireAttachmentId: wireId)
        }
        // Claims the row for this live attempt so the outbox drain never seals and sends the same message a second time.
        ChatOutboxDrain.shared.beginLiveSend(clientMsgId: msgId.uuidString)
        let outcome = await sendService.sendEncryptedDurable(
            messageId: msgId, conversationId: context.conversationId, peerUserId: context.peerUserId, plaintext: body)
        ChatOutboxDrain.shared.endLiveSend(clientMsgId: msgId.uuidString)
        switch outcome {
        case .delivered(let serverMessageId):
            store.setServerMessageId(localId: msgId, conversationId: context.conversationId, serverMessageId: serverMessageId)
            store.updateMessageStatus(id: msgId, conversationId: context.conversationId, newStatus: .delivered, deliveredAt: Date())
        case .queued:
            ChatOutboxDrain.shared.kick(reason: "file-v2-queued")
        case .failed:
            store.replaceContent(id: msgId, plaintext: context.displayText, mediaMimeType: context.pendingMime)
            throw DescriptorRefused()
        }
    }
}

/// Lets a few sends run together and the rest wait their turn, in the order they asked.
private actor SendGate {
    private let limit = 3
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

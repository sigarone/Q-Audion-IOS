import Foundation
import QAudionEngine

/// One send of a document in a 1:1 chat, from the picked file to the message that carries its descriptor (file transfer v2,
/// WIRE_SPEC section 12). The engine's `FileV2Sender` does the upload; this is the part that needs the app: the chat row, the
/// durable end-to-end send of the descriptor and the outbox.
///
/// A static function with every dependency passed in, so that the send does not depend on the chat screen still being there: the
/// caller (`ChatContainer.sendFileAttachment`) only listens to the progress and to the end.
@MainActor
enum FileV2OutboundRunner {

    /// What one send needs. Nothing here is secret: the key, the file id and the token exist only inside the engine's sender and
    /// the descriptor it hands back.
    struct Context {
        let messageId: UUID
        let conversationId: UUID
        let peerUserId: String
        /// `📎 name`: what the row shows while it has no descriptor.
        let displayText: String
        let sourceURL: URL
        /// The picked name, as the descriptor's `nm` (the engine cuts it to 255 bytes).
        let name: String
        let mimeType: String
        /// The descriptor's `ex` (-1 view once, N seconds); `nil` when there is no timer.
        let ex: Int64?
        /// The descriptor's `xp`: 0 export blocked; `nil` = allowed.
        let xp: Int64?
    }

    /// The rows of the sends running in THIS process. A row of a file that is still "sending" and is not here belongs to a send
    /// the system ended (the app was closed, or killed, while it uploaded): it will never finish, and the chat marks it failed.
    private static var inFlight: Set<UUID> = []

    static func isInFlight(_ messageId: UUID) -> Bool { inFlight.contains(messageId) }

    /// Runs the send to its end. Returns `nil` when the descriptor was handed to the chat (sent, or queued in the outbox for the
    /// moment the connection is back), otherwise the failure. A failure after the upload has deleted the object on the server
    /// (the engine does it), so nothing is left that counts against the account's quota.
    ///
    /// When the server says the account has no room for another object (too many unfinished uploads, or the quota) and this is
    /// the only send running, the account's unfinished objects (the leftovers of a send that was killed) are deleted and the send
    /// is tried once more: they hold quota and slots for hours otherwise. A completed object is never touched.
    static func run(
        _ context: Context,
        sendService: ChatMessageSendService,
        appState: AppState,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void
    ) async -> FileV2Failure? {
        inFlight.insert(context.messageId)
        defer { inFlight.remove(context.messageId) }
        let store = ConversationStore()
        let server = FileV2AppServices.makeServer(appState: appState)

        var failure = await attempt(context, server: server, sendService: sendService, store: store, onProgress: onProgress)
        if let first = failure, isNoRoomOnServer(first), inFlight.count == 1 {
            if let deleted = try? await FileV2UnfinishedCleanup.run(server: server), deleted > 0 {
                RTLog.info("chat", "filev2 cleanup deleted=\(deleted)")
                failure = await attempt(context, server: server, sendService: sendService, store: store, onProgress: onProgress)
            }
        }
        if failure == nil { RTLog.info("chat", "filev2 send ok=1") }
        return failure
    }

    private static func isNoRoomOnServer(_ failure: FileV2Failure) -> Bool {
        guard case .transfer(.quota) = failure.reason, let server = failure.server else { return false }
        return server.code == "too_many_uploads" || server.code == "quota_exceeded"
    }

    private static func attempt(
        _ context: Context,
        server: FileV2Server,
        sendService: ChatMessageSendService,
        store: ConversationStore,
        onProgress: @escaping @MainActor (Int64, Int64) -> Void
    ) async -> FileV2Failure? {
        let sender = FileV2Sender(server: server)
        let request = FileV2Sender.Request(
            sourceURL: context.sourceURL, name: context.name, mimeType: context.mimeType,
            recipientUserID: context.peerUserId, ex: context.ex, xp: context.xp)
        do {
            try await sender.send(request, progress: { done, total in
                Task { @MainActor in onProgress(done, total) }
            }, deliver: { body in
                try await deliver(body, context: context, sendService: sendService, store: store)
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
    private static func deliver(_ body: String, context: Context, sendService: ChatMessageSendService,
                                store: ConversationStore) async throws {
        let msgId = context.messageId
        store.replaceContent(id: msgId, plaintext: body, mediaMimeType: nil)
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
            store.replaceContent(id: msgId, plaintext: context.displayText, mediaMimeType: FileV2ChatBody.pendingMime)
            throw DescriptorRefused()
        }
    }
}

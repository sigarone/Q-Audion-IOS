import Foundation
import GRDB

/// W-MSGOUTBOX (2026-09-01) — one row of the durable 1:1 outbox
/// (`chat_outbox`, migration v8 in `QAudionDatabase`).
///
/// Two kinds share the table, told apart by `kind`:
///   - `kindMessage`: a sealed wire blob waiting to be (re)sent. `id` is
///     the sender's `client_msg_id` — the idempotency key the server
///     echoes verbatim and the receiver stores, so a resend can never
///     become a second message on the far side. `payloadB64` is the EXACT
///     ciphertext the first attempt produced (`ChatMessageSendService
///     .encryptForWire`), persisted so a retry re-sends the same bytes
///     instead of running the ratchet again for the same message.
///   - `kindDeliveryReceipt`: a `msg_delivered` ack the socket could not
///     carry at the time. `id` is the server message id; payload is empty.
///
/// This table carries NO plaintext and NO key material: message bodies
/// stay sealed in `messages.plaintext` (see `LocalStoreCipher`), and what
/// sits here is already end-to-end ciphertext for the peer — the same
/// bytes that go on the wire. Timestamps are epoch milliseconds so the
/// ordering / backoff arithmetic in `OutboxRetryPolicy` never touches a
/// date-format strategy.
public struct ChatOutboxEntry: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chat_outbox"

    public static let kindMessage = "message"
    public static let kindDeliveryReceipt = "delivery_receipt"

    public let id: String
    public let kind: String
    public let conversationId: String?
    public let messageId: String?
    public let peerUserId: String?
    public let payloadB64: String
    public let attempts: Int
    public let createdAtMs: Int64
    public let nextAttemptAtMs: Int64

    public init(id: String, kind: String, conversationId: String?, messageId: String?,
                peerUserId: String?, payloadB64: String, attempts: Int,
                createdAtMs: Int64, nextAttemptAtMs: Int64) {
        self.id = id
        self.kind = kind
        self.conversationId = conversationId
        self.messageId = messageId
        self.peerUserId = peerUserId
        self.payloadB64 = payloadB64
        self.attempts = attempts
        self.createdAtMs = createdAtMs
        self.nextAttemptAtMs = nextAttemptAtMs
    }
}

/// W-MSGOUTBOX (2026-09-01) — persistence for the durable 1:1 outbox.
/// Same shape as every other Persistence store: a thin GRDB wrapper over
/// `QAudionDatabase`, every failure logged with a greppable `=0` marker and
/// swallowed (the caller degrades to "not queued", never crashes). The
/// retry DECISIONS live in `OutboxRetryPolicy`; the drainer that acts on
/// them is `ChatOutboxDrain` in the app target. This class only stores.
public final class ChatOutboxStore {

    private let db: QAudionDatabase

    public init(db: QAudionDatabase = .shared) {
        self.db = db
    }

    /// Upsert a message entry (retrying an enqueue is idempotent, not a
    /// duplicate — same rule as `MeshOutboxStore.enqueue`).
    public func enqueueMessage(clientMsgId: String, messageId: UUID, conversationId: UUID,
                               peerUserId: String, wireBlob: Data, attempts: Int,
                               createdAtMs: Int64, nextAttemptAtMs: Int64) {
        let entry = ChatOutboxEntry(
            id: clientMsgId,
            kind: ChatOutboxEntry.kindMessage,
            conversationId: conversationId.uuidString,
            messageId: messageId.uuidString,
            peerUserId: peerUserId,
            payloadB64: wireBlob.base64EncodedString(),
            attempts: attempts,
            createdAtMs: createdAtMs,
            nextAttemptAtMs: nextAttemptAtMs
        )
        do {
            try db.writer.write { db in
                try entry.save(db)
            }
        } catch {
            print("[ChatOutboxStore] enqueueMessage saved=0 error: \(error)")
        }
    }

    /// Upsert a delivery-receipt entry keyed by the server message id.
    public func enqueueDeliveryReceipt(serverMessageId: String, nowMs: Int64) {
        let entry = ChatOutboxEntry(
            id: serverMessageId,
            kind: ChatOutboxEntry.kindDeliveryReceipt,
            conversationId: nil,
            messageId: nil,
            peerUserId: nil,
            payloadB64: "",
            attempts: 0,
            createdAtMs: nowMs,
            nextAttemptAtMs: 0
        )
        do {
            try db.writer.write { db in
                try entry.save(db)
            }
        } catch {
            print("[ChatOutboxStore] enqueueDeliveryReceipt saved=0 error: \(error)")
        }
    }

    public func entry(id: String) -> ChatOutboxEntry? {
        do {
            return try db.reader.read { db in
                try ChatOutboxEntry.fetchOne(db, key: id)
            }
        } catch {
            print("[ChatOutboxStore] entry failed: \(error)")
            return nil
        }
    }

    /// Queued messages, oldest first — the order a drain pass attempts them in.
    public func pendingMessages() -> [ChatOutboxEntry] {
        pending(kind: ChatOutboxEntry.kindMessage)
    }

    /// Queued delivery receipts, oldest first.
    public func pendingDeliveryReceipts() -> [ChatOutboxEntry] {
        pending(kind: ChatOutboxEntry.kindDeliveryReceipt)
    }

    private func pending(kind: String) -> [ChatOutboxEntry] {
        do {
            return try db.reader.read { db in
                try ChatOutboxEntry
                    .filter(Column("kind") == kind)
                    .order(Column("createdAtMs").asc)
                    .fetchAll(db)
            }
        } catch {
            print("[ChatOutboxStore] pending failed kind=\(kind): \(error)")
            return []
        }
    }

    /// Record one failed attempt: bump the counter and set the next
    /// eligible instant. Column-level UPDATE — `attempts` and
    /// `nextAttemptAtMs` are plain columns, nothing sealed to desync.
    public func recordAttempt(id: String, attempts: Int, nextAttemptAtMs: Int64) {
        do {
            _ = try db.writer.write { db in
                try ChatOutboxEntry
                    .filter(key: id)
                    .updateAll(db, [
                        Column("attempts").set(to: attempts),
                        Column("nextAttemptAtMs").set(to: nextAttemptAtMs),
                    ])
            }
        } catch {
            print("[ChatOutboxStore] recordAttempt failed: \(error)")
        }
    }

    public func remove(id: String) {
        do {
            _ = try db.writer.write { db in
                try ChatOutboxEntry.filter(key: id).deleteAll(db)
            }
        } catch {
            print("[ChatOutboxStore] remove failed: \(error)")
        }
    }

    public func removeAll() {
        do {
            _ = try db.writer.write { db in
                try ChatOutboxEntry.deleteAll(db)
            }
        } catch {
            print("[ChatOutboxStore] removeAll failed: \(error)")
        }
    }

    public func count() -> Int {
        do {
            return try db.reader.read { db in
                try ChatOutboxEntry.fetchCount(db)
            }
        } catch {
            print("[ChatOutboxStore] count failed: \(error)")
            return 0
        }
    }
}

import Foundation
import QAudionEngine

/// W-MSGOUTBOX (2026-09-01) — drains the durable 1:1 outbox
/// (`ChatOutboxStore`, decisions in `OutboxRetryPolicy`): every OUTGOING
/// text row still at `.sending` is re-sent with its ORIGINAL
/// `client_msg_id` until the socket accepts it or `OutboxRetryPolicy` says
/// give up (→ `.failed`, manual retry as before). Delivery receipts the
/// socket could not carry are flushed by the same pass.
///
/// Why (audit memory reference_ios_stability_audit_2026_09_01, P1 item 3):
/// the live send was one in-memory `Task` with a ~10 s budget and no
/// sweep, so a socket blip meant a red row and a process kill meant a
/// clock icon forever. See `OutboxRetryPolicy`'s header.
///
/// Runs ONLY when kicked — on every WS transition into `.authenticated`
/// (which covers app launch: the persistent socket authenticates right
/// after `connectPersistentSocket`), after a live send is queued, and on
/// its own backoff wake-ups — and only while the transport reports
/// authenticated, so an offline day never burns attempts. Single-flight:
/// a kick during a pass sets a flag and the pass re-runs once at the end,
/// never two passes on the same rows (same rule `MeshOutboxDrain` /
/// `NameResolutionService.inFlight` follow).
///
/// Ownership rules that keep it from colliding with the live paths:
///   - a row the live `ChatContainer.sendMessage` attempt is still working
///     on is claimed via `beginLiveSend`/`endLiveSend` and skipped here, so
///     one message is never sealed twice (the ratchet would step twice);
///   - a row waiting on the BLE mesh (`MeshOutboxStore.contains`) is the
///     mesh's, not ours;
///   - attachment rows never appear: `loadPendingOutboundTextMessages`
///     is text-only, the TUS pipeline has its own resume.
///
/// `ConversationStore`/`ChatOutboxStore` instantiated directly, AppState
/// reached only through primitive closures — CLAUDE.md §16.
@MainActor
final class ChatOutboxDrain {
    static let shared = ChatOutboxDrain()

    enum TransportError: Error { case unavailable }

    /// What the orphan path gets back from the app's sealer. `refused`
    /// carries the `ChatContainer.SendFailureReason` raw value so the
    /// container can show the same snackbar copy it shows for a live
    /// failure, without this file naming that type.
    enum EncryptOutcome {
        case sealed(Data)
        case refused(reasonCode: String)
    }

    typealias TransportReadyProvider = @MainActor () -> Bool
    typealias WireSender = @MainActor (_ peerUserId: String, _ wireBlob: Data, _ clientMsgId: String) async throws -> Void
    typealias ReceiptSender = @MainActor (_ serverMessageId: String) async throws -> Void
    typealias WireEncrypter = @MainActor (_ messageId: UUID, _ peerUserId: String, _ plaintext: String) async -> EncryptOutcome

    /// `chatRefreshNotification` userInfo keys the drainer adds when it
    /// gives up on a row, so the open `ChatContainer` can raise its
    /// existing "Riprova" snackbar for a row it did not fail itself.
    static let failedMessageIdKey = "outboxFailedMessageId"
    static let failureReasonKey = "outboxFailureReason"
    /// `ChatContainer.SendFailureReason.networkError.rawValue` — the reason
    /// a row exhausted on transport failures reports.
    static let transportFailureReasonCode = "network_error"
    /// `ChatContainer.SendFailureReason.cryptoFailure.rawValue` — a queued
    /// payload that no longer decodes (should never happen; belt and braces).
    static let payloadFailureReasonCode = "crypto_failure"

    private let store: ConversationStore
    private let outbox: ChatOutboxStore
    private let meshOutbox: MeshOutboxStore

    private var isTransportReady: TransportReadyProvider?
    private var sendWire: WireSender?
    private var sendReceipt: ReceiptSender?
    private var encrypt: WireEncrypter?

    private var draining = false
    private var rerunRequested = false
    private var wakeTask: Task<Void, Never>?
    /// client_msg_ids a live `ChatContainer` attempt currently owns.
    private var liveSends: Set<String> = []

    init(store: ConversationStore = ConversationStore(),
         outbox: ChatOutboxStore = ChatOutboxStore(),
         meshOutbox: MeshOutboxStore = .shared) {
        self.store = store
        self.outbox = outbox
        self.meshOutbox = meshOutbox
    }

    /// Idempotent — `AppState.connectPersistentSocket` calls this every time
    /// it builds the persistent provider; the closures read the CURRENT
    /// provider at call time, so re-binding is harmless.
    func configure(isTransportReady: @escaping TransportReadyProvider,
                   sendWire: @escaping WireSender,
                   sendReceipt: @escaping ReceiptSender,
                   encrypt: @escaping WireEncrypter) {
        self.isTransportReady = isTransportReady
        self.sendWire = sendWire
        self.sendReceipt = sendReceipt
        self.encrypt = encrypt
    }

    // MARK: - Live-send ownership

    func beginLiveSend(clientMsgId: String) {
        liveSends.insert(clientMsgId)
    }

    func endLiveSend(clientMsgId: String) {
        liveSends.remove(clientMsgId)
    }

    // MARK: - Trigger

    /// Start a pass, or ask the running one to run again when it finishes.
    func kick(reason: String) {
        guard OutboxRetryPolicy.enabled else { return }
        if draining {
            rerunRequested = true
            return
        }
        draining = true
        Task { [weak self] in
            guard let self else { return }
            await self.runPass(reason: reason)
            self.draining = false
            if self.rerunRequested {
                self.rerunRequested = false
                self.kick(reason: "rerun")
            }
        }
    }

    // MARK: - Pass

    private func runPass(reason: String) async {
        guard let isTransportReady, let sendWire, let sendReceipt, let encrypt else { return }
        guard isTransportReady() else { return }
        let nowMs = Self.nowMs()
        var sent = 0
        var waiting = 0
        var failed = 0
        var receipts = 0
        var earliestWakeMs: Int64? = nil

        // 1. Delivery receipts — cheap, fire-and-forget on the wire, so
        // they go first. Stop on the first transport error: the socket is
        // gone for everything else in this pass too.
        for entry in outbox.pendingDeliveryReceipts() {
            if nowMs - entry.createdAtMs >= OutboxRetryPolicy.maxAgeMs {
                outbox.remove(id: entry.id)
                continue
            }
            do {
                try await sendReceipt(entry.id)
                outbox.remove(id: entry.id)
                receipts += 1
            } catch {
                break
            }
        }

        // 2. Messages, oldest first.
        let rows = store.loadPendingOutboundTextMessages()
        var conversationById: [UUID: Conversation] = [:]
        for conv in store.loadConversations() {
            conversationById[conv.id] = conv
        }
        var transportDown = false
        for row in rows {
            if transportDown { break }
            guard let clientMsgId = row.clientMsgId, !clientMsgId.isEmpty else {
                // No idempotency key means no safe resend. Pre-W86 rows
                // only; surface it instead of leaving a clock forever.
                guard let conv = conversationById[row.conversationId] else { continue }
                fail(row: row, peerUserId: conv.peerUserId, reasonCode: Self.transportFailureReasonCode, attempts: 0)
                failed += 1
                continue
            }
            if liveSends.contains(clientMsgId) { continue }
            if meshOutbox.contains(messageId: row.id.uuidString) { continue }
            guard let conv = conversationById[row.conversationId], conv.kind == .oneToOne else { continue }
            let peerUserId = conv.peerUserId

            var entry = outbox.entry(id: clientMsgId)
            if entry == nil {
                // Orphan: the process died between the row write and the
                // live attempt's enqueue. Seal from the stored body ONCE and
                // persist the bytes so every later attempt re-sends them.
                switch await encrypt(row.id, peerUserId, row.plaintext) {
                case .sealed(let blob):
                    outbox.enqueueMessage(
                        clientMsgId: clientMsgId, messageId: row.id,
                        conversationId: row.conversationId, peerUserId: peerUserId,
                        wireBlob: blob, attempts: 0,
                        createdAtMs: Self.ms(row.sentAt), nextAttemptAtMs: 0)
                    entry = outbox.entry(id: clientMsgId)
                case .refused(let reasonCode):
                    fail(row: row, peerUserId: peerUserId, reasonCode: reasonCode, attempts: 0)
                    failed += 1
                    continue
                }
            }
            guard let current = entry else { continue }

            switch OutboxRetryPolicy.rowAction(
                attempts: current.attempts, createdAtMs: current.createdAtMs,
                nextAttemptAtMs: current.nextAttemptAtMs, nowMs: nowMs) {
            case .giveUpAttempts, .giveUpAge:
                outbox.remove(id: clientMsgId)
                fail(row: row, peerUserId: peerUserId,
                     reasonCode: Self.transportFailureReasonCode, attempts: current.attempts)
                failed += 1
                continue
            case .wait(let untilMs):
                earliestWakeMs = Self.earlier(earliestWakeMs, untilMs)
                waiting += 1
                continue
            case .attemptNow:
                break
            }

            guard let blob = Data(base64Encoded: current.payloadB64), !blob.isEmpty else {
                outbox.remove(id: clientMsgId)
                fail(row: row, peerUserId: peerUserId,
                     reasonCode: Self.payloadFailureReasonCode, attempts: current.attempts)
                failed += 1
                continue
            }
            do {
                try await sendWire(peerUserId, blob, clientMsgId)
                // Same optimistic semantics as the live path
                // (`ChatContainer.sendMessage` `.delivered` branch): the
                // socket accepted the frame; the real server id is bound
                // later by the self-echo `msg_receive`.
                outbox.remove(id: clientMsgId)
                store.updateMessageStatus(
                    id: row.id, conversationId: row.conversationId,
                    newStatus: .delivered, deliveredAt: Date())
                postRefresh(peerUserId: peerUserId, extra: nil)
                sent += 1
            } catch {
                let attempts = current.attempts + 1
                let nextAttemptAtMs = Self.nowMs() + OutboxRetryPolicy.backoffMs(afterFailedAttempts: attempts)
                outbox.recordAttempt(id: clientMsgId, attempts: attempts, nextAttemptAtMs: nextAttemptAtMs)
                earliestWakeMs = Self.earlier(earliestWakeMs, nextAttemptAtMs)
                // The rows behind this one keep their attempt counters; the
                // wake below retries the lot once the backoff elapses.
                transportDown = true
            }
        }

        // 3. Sweep: an entry whose row is no longer an outgoing `.sending`
        // row (delivered by the live path, deleted, tombstoned, or gone
        // with its conversation) has nothing left to do.
        for entry in outbox.pendingMessages() {
            if liveSends.contains(entry.id) { continue }
            if let found = store.findByClientMsgId(entry.id),
               found.message.direction == .outgoing,
               found.message.status == .sending {
                continue
            }
            outbox.remove(id: entry.id)
        }

        if let wakeMs = earliestWakeMs {
            scheduleWake(atMs: wakeMs)
        }
        if !rows.isEmpty || receipts > 0 || failed > 0 {
            RTLog.info("chat", "outbox drain rows=\(rows.count) sent=\(sent) wait=\(waiting) failed=\(failed) receipts=\(receipts)")
        }
    }

    // MARK: - Helpers

    private func fail(row: Message, peerUserId: String, reasonCode: String, attempts: Int) {
        store.updateMessageStatus(id: row.id, conversationId: row.conversationId, newStatus: .failed)
        RTLog.warn("chat", "outbox giveup=1 attempts=\(attempts) age=\(Int(Date().timeIntervalSince(row.sentAt)))")
        postRefresh(peerUserId: peerUserId, extra: [
            Self.failedMessageIdKey: row.id.uuidString,
            Self.failureReasonKey: reasonCode,
        ])
    }

    private func postRefresh(peerUserId: String, extra: [String: Any]?) {
        var info: [String: Any] = ["peerUserId": peerUserId]
        if let extra {
            for (key, value) in extra {
                info[key] = value
            }
        }
        NotificationCenter.default.post(name: AppState.chatRefreshNotification, object: nil, userInfo: info)
    }

    private func scheduleWake(atMs: Int64) {
        wakeTask?.cancel()
        let delayMs = max(atMs - Self.nowMs(), 0)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.kick(reason: "backoff-wake")
        }
    }

    private static func earlier(_ current: Int64?, _ candidate: Int64) -> Int64 {
        guard let current else { return candidate }
        return min(current, candidate)
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private static func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}

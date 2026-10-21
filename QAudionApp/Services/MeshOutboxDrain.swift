import Foundation
import QAudionEngine

/// Drives `MeshOutboxStore` (docs/mesh/MESH_LINK_SPEC.md section 10.2).
///
/// - A message that a first hop accepted is "sent", NOT delivered: it stays in the
///   outbox and is retransmitted every 20 s (a new packet around the same sealed shell, so
///   the receiver's duplicate check on the shell id makes a second copy harmless) until
///   a valid delivery receipt arrives (`acknowledged`) or the outbox gives up after an
///   hour, when the message becomes "failed".
/// - A receipt that cannot be sent right away is queued the same way, and leaves the
///   outbox once a first hop accepted it.
///
/// Owns the `ConversationStore` write for both outcomes directly, so a retry that lands
/// (or finally expires) updates the user's chat history even if that conversation isn't
/// the one on screen right now — mirrors Android's `PendingSendOrchestrator` draining
/// independently of any open chat.
///
/// `ConversationStore`, not `AppState`: this is a plain `Services/*.swift` type
/// instantiating `ConversationStore` directly, the same pattern
/// `BackupCoordinator`/`EphemeralMessageJanitor`/`LocalCryptoWipe` already use — see
/// CLAUDE.md §16 for why `AppState` itself is never taken as a parameter type in a new
/// file.
@MainActor
final class MeshOutboxDrain {
    static let shared = MeshOutboxDrain()

    private let outbox: MeshOutboxStore
    private let store: ConversationStore
    private var timer: Timer?
    private var inFlight: Set<String> = []
    private var lastReachable: Set<String> = []

    /// How often the outbox is looked at. An entry is retried once its own 20 s have passed
    /// (`MeshOutboxPolicy.retryMs`); this only bounds how late that can happen.
    private static let tickSeconds: TimeInterval = 5

    init(outbox: MeshOutboxStore = .shared, store: ConversationStore = ConversationStore()) {
        self.outbox = outbox
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.drainAndSweep()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Queues a send and tries it right away. The entry stays until a delivery receipt (message) or a
    /// first-hop acceptance (receipt) says otherwise.
    func submit(_ entry: MeshOutboxEntry) {
        outbox.enqueue(entry)
        drainAndSweep()
    }

    /// A delivery or read receipt for `clientMsgId` arrived: the message has been delivered, so it leaves the outbox.
    func acknowledged(clientMsgId: String) {
        outbox.acknowledge(clientMsgId: clientMsgId)
    }

    /// The set of reachable peers changed: a target that just became reachable is retried without waiting out
    /// the full interval.
    func reachabilityChanged() {
        let reachable = Set(MeshRuntime.shared.peers.filter { $0.connected }.map { $0.nodeHex })
        guard reachable != lastReachable else { return }
        lastReachable = reachable
        drainAndSweep()
    }

    func drainAndSweep() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let reachable = Set(MeshRuntime.shared.peers.filter { $0.connected }.map { $0.nodeHex })
        let due = outbox.due(nowMs: nowMs, reachableTargets: reachable)
        var retried = 0
        for entry in due where !inFlight.contains(entry.id) {
            if entry.attempts > 0 { retried += 1 }
            attempt(entry)
        }
        let gaveUp = sweepExpired(nowMs: nowMs)
        let pending = outbox.pendingCount()
        if pending > 0 || gaveUp > 0 {
            MeshLog.emit(.outbox, [("pending", String(pending)), ("retried", String(retried)), ("gaveUp", String(gaveUp))])
        }
    }

    private func sweepExpired(nowMs: Int64) -> Int {
        let expired = outbox.expired(nowMs: nowMs)
        for entry in expired {
            outbox.remove(id: entry.id)
            if entry.kind == .message {
                failMessage(entry)
            }
            logApp(entry, state: "failed", attempt: entry.attempts)
        }
        return expired.count
    }

    private func attempt(_ entry: MeshOutboxEntry) {
        guard let payload = Data(base64Encoded: entry.payloadB64) else {
            // An undecodable payload can never succeed — drop it rather than retry forever.
            outbox.remove(id: entry.id)
            if entry.kind == .message { failMessage(entry) }
            logApp(entry, state: "failed", attempt: entry.attempts)
            return
        }
        inFlight.insert(entry.id)
        MeshRuntime.shared.sendData(toNodeHex: entry.targetNodeHex, payload: payload, type: entry.packetType) { [weak self] report in
            Task { @MainActor in
                self?.attempted(entry, report: report)
            }
        }
    }

    private func attempted(_ entry: MeshOutboxEntry, report: MeshSendReport) {
        inFlight.remove(entry.id)
        var accepted = false
        switch report.result {
        case .sentDirect, .sentViaRelay:
            accepted = true
        case .queued, .failed:
            accepted = false
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let outcome = outbox.recordAttempt(id: entry.id, nowMs: nowMs, accepted: accepted)
        let attemptNumber = entry.attempts + 1
        switch outcome {
        case .firstAcceptance:
            markSent(entry)
            logApp(entry, state: "sent", attempt: attemptNumber)
        case .removed:
            // A receipt a first hop accepted, or an entry that left the outbox while this attempt was in flight
            // (its receipt arrived first).
            if accepted { logApp(entry, state: "sent", attempt: attemptNumber) }
        case .retained:
            logApp(entry, state: accepted ? "sent" : "queued", attempt: attemptNumber)
        }
    }

    /// A first hop accepted the message: "sent" (one tick). The second tick still comes from the peer's own
    /// `MeshReceipt`, so a message that is only sent stays in the outbox.
    private func markSent(_ entry: MeshOutboxEntry) {
        guard entry.kind == .message,
              let mid = UUID(uuidString: entry.messageId),
              let cid = UUID(uuidString: entry.conversationId) else { return }
        store.updateMessageStatus(id: mid, conversationId: cid, newStatus: .sent, viaMesh: true)
        postChatRefresh(entry, conversationId: cid)
    }

    private func failMessage(_ entry: MeshOutboxEntry) {
        guard let mid = UUID(uuidString: entry.messageId),
              let cid = UUID(uuidString: entry.conversationId) else { return }
        store.updateMessageStatus(id: mid, conversationId: cid, newStatus: .failed)
        postChatRefresh(entry, conversationId: cid)
    }

    private func postChatRefresh(_ entry: MeshOutboxEntry, conversationId: UUID) {
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification, object: nil,
            userInfo: ["peerUserId": entry.peerUserId, "conversationId": conversationId]
        )
    }

    private func logApp(_ entry: MeshOutboxEntry, state: String, attempt: Int) {
        let kind = entry.kind == .message ? "msg" : "rcpt"
        let ph = MeshLog.payloadHash(Data(base64Encoded: entry.payloadB64) ?? Data())
        MeshLog.emit(.appTx, [("ph", ph), ("kind", kind), ("state", state), ("attempt", String(attempt))])
    }
}

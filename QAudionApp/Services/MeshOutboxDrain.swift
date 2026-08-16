import Foundation
import QAudionEngine

/// Drives `MeshOutboxStore`: retries entries whose target has become
/// reachable, and gives up on ones that have aged past
/// `MeshOutboxStore.maxAgeMs`. Owns the `ConversationStore` write for both
/// outcomes directly, so a retry that lands (or finally expires) updates
/// the user's chat history even if that conversation isn't the one on
/// screen right now — mirrors Android's `PendingSendOrchestrator` draining
/// independently of any open chat, rather than a UI-triggered action.
///
/// `ConversationStore`, not `AppState`: this is a plain `Services/*.swift`
/// type instantiating `ConversationStore` directly, the same pattern
/// `BackupCoordinator`/`EphemeralMessageJanitor`/`LocalCryptoWipe` already
/// use — see CLAUDE.md §16 for why `AppState` itself is never taken as a
/// parameter type in a new file.
@MainActor
final class MeshOutboxDrain {
    static let shared = MeshOutboxDrain()

    private let outbox: MeshOutboxStore
    private let store: ConversationStore
    private var timer: Timer?

    /// Backstop cadence. Real responsiveness comes from `MeshRuntime`
    /// calling `drainAndSweep()` whenever its peer set changes (a target
    /// coming back into range); this timer only covers the case where a
    /// peer was already visible when a send failed for some other
    /// transient reason (a busy radio, a dropped write).
    private static let drainIntervalSeconds: TimeInterval = 20

    init(outbox: MeshOutboxStore = .shared, store: ConversationStore = ConversationStore()) {
        self.outbox = outbox
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.drainIntervalSeconds, repeats: true) { [weak self] _ in
            self?.drainAndSweep()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func drainAndSweep() {
        Task { [weak self] in
            await self?.drainAndSweepAsync()
        }
    }

    private func drainAndSweepAsync() async {
        let reachable = Set(MeshRuntime.shared.peers.filter { $0.connected }.map { $0.nodeHex })
        let ready = outbox.pending(reachableNodeHexes: reachable)
        for entry in ready {
            await attempt(entry)
        }
        sweepExpired()
    }

    private func sweepExpired() {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for entry in outbox.expired(nowMs: nowMs) {
            outbox.remove(messageId: entry.messageId)
            failMessage(entry)
        }
    }

    private func attempt(_ entry: MeshPendingSend) async {
        guard let payload = Data(base64Encoded: entry.sealedShellB64) else {
            // Undecodable payload can never succeed — drop it rather than
            // retry forever on something that will never change.
            outbox.remove(messageId: entry.messageId)
            failMessage(entry)
            return
        }
        let delivered = await sendOverMesh(toNodeHex: entry.targetNodeHex, payload: payload)
        if delivered {
            outbox.remove(messageId: entry.messageId)
            deliverMessage(entry)
        } else {
            outbox.bumpAttempts(messageId: entry.messageId)
        }
    }

    private func sendOverMesh(toNodeHex: String, payload: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            MeshRuntime.shared.sendData(toNodeHex: toNodeHex, payload: payload) { delivered in
                continuation.resume(returning: delivered)
            }
        }
    }

    private func deliverMessage(_ entry: MeshPendingSend) {
        guard let mid = UUID(uuidString: entry.messageId),
              let cid = UUID(uuidString: entry.conversationId) else { return }
        // .sent, not .delivered: the radio accepted the write. The second
        // tick still comes from the peer's own MeshReceipt, same rule
        // ChatContainer.finishMeshSend already follows for the live path.
        store.updateMessageStatus(id: mid, conversationId: cid, newStatus: .sent, viaMesh: true)
    }

    private func failMessage(_ entry: MeshPendingSend) {
        guard let mid = UUID(uuidString: entry.messageId),
              let cid = UUID(uuidString: entry.conversationId) else { return }
        store.updateMessageStatus(id: mid, conversationId: cid, newStatus: .failed)
    }
}

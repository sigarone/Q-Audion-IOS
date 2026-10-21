import Foundation
import QAudionEngine

/// Persisted mesh outbox (docs/mesh/MESH_LINK_SPEC.md section 10.2): the sends the
/// mesh is still responsible for. The rules themselves (what is due, when to retry,
/// when to give up, which entries a receipt removes) are the engine's
/// `MeshOutboxQueue`; this type only keeps it in `UserDefaults` under a lock.
///
/// A MESSAGE entry stays here after a first hop accepted it and is retransmitted
/// every 20 s until a valid delivery receipt arrives (`acknowledge`) or the outbox
/// gives up after an hour. A RECEIPT entry is removed once a first hop accepted it.
/// Entries carry the already-sealed `MeshSealedShell` bytes (base64), so there is no
/// plaintext and no key material here.
///
/// Not `@MainActor`: every method is a short, synchronous, lock-guarded
/// read-modify-write, safe to call from anywhere.
final class MeshOutboxStore {
    static let shared = MeshOutboxStore()

    /// An entry gives up after this long (kept for callers that show the number).
    static let maxAgeMs: Int64 = MeshOutboxPolicy.giveUpMs

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let storageKey = "qaudion.mesh.outbox.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Replaces any existing entry with the same id (an enqueue is idempotent).
    func enqueue(_ entry: MeshOutboxEntry) {
        mutate { $0.enqueue(entry) }
    }

    /// Drops everything (the account left).
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.storageKey)
    }

    func remove(id: String) {
        mutate { $0.remove(id: id) }
    }

    /// A delivery (or read) receipt for `clientMsgId` arrived: the message leaves the outbox. Returns the entry, if any.
    @discardableResult
    func acknowledge(clientMsgId: String) -> MeshOutboxEntry? {
        var removed: MeshOutboxEntry?
        mutate { removed = $0.acknowledge(clientMsgId: clientMsgId) }
        return removed
    }

    /// Is this MESSAGE waiting on the mesh? A mesh-routed row stays `.sending` while it has no first-hop acceptance,
    /// which is the same status the network outbox drainer (`ChatOutboxDrain`) looks for; this is how that drainer
    /// knows to leave a mesh-owned row alone instead of re-sending it over the WebSocket the user chose not to use.
    func contains(messageId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return load().contains(id: messageId)
    }

    func entry(id: String) -> MeshOutboxEntry? {
        lock.lock()
        defer { lock.unlock() }
        return load().entry(id: id)
    }

    /// Entries to send now, oldest first.
    func due(nowMs: Int64, reachableTargets: Set<String>) -> [MeshOutboxEntry] {
        lock.lock()
        defer { lock.unlock() }
        return load().due(nowMs: nowMs, reachableTargets: reachableTargets)
    }

    /// Entries the outbox gives up on. The caller owns the `ConversationStore` write that goes with it.
    func expired(nowMs: Int64) -> [MeshOutboxEntry] {
        lock.lock()
        defer { lock.unlock() }
        return load().expired(nowMs: nowMs)
    }

    @discardableResult
    func recordAttempt(id: String, nowMs: Int64, accepted: Bool) -> MeshOutboxQueue.AttemptOutcome {
        var outcome: MeshOutboxQueue.AttemptOutcome = .removed
        mutate { outcome = $0.recordAttempt(id: id, nowMs: nowMs, accepted: accepted) }
        return outcome
    }

    /// Entries currently held, for the `outbox` log line.
    func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return load().entries.count
    }

    private func mutate(_ change: (inout MeshOutboxQueue) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var queue = load()
        change(&queue)
        save(queue)
    }

    private func load() -> MeshOutboxQueue {
        guard let data = defaults.data(forKey: Self.storageKey),
              let queue = try? JSONDecoder().decode(MeshOutboxQueue.self, from: data) else {
            return MeshOutboxQueue()
        }
        return queue
    }

    private func save(_ queue: MeshOutboxQueue) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

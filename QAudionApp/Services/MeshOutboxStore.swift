import Foundation

/// A mesh send waiting for its target to become reachable again.
///
/// `sealedShellB64` is the exact bytes `ChatContainer.completeMeshSend`
/// would otherwise have handed straight to `MeshRuntime.sendData` — the
/// already-encrypted `MeshSealedShell.encode()` output, base64'd for JSON
/// storage. This type carries no plaintext and no key material: it is a
/// retry queue for bytes that are already opaque ciphertext.
struct MeshPendingSend: Codable, Equatable {
    let messageId: String
    let conversationId: String
    let peerUserId: String
    let targetNodeHex: String
    let sealedShellB64: String
    let createdAtMs: Int64
    var attempts: Int
}

/// Persisted queue of mesh sends waiting for their target to become
/// reachable, so a send to a peer that's briefly out of range gets retried
/// instead of failing on the spot.
///
/// Before this existed, `BleMeshTransport.sendLocked` failing once meant
/// the message failed, full stop — the single largest functional gap
/// against the Android sibling's real store-and-forward outbox
/// (`PendingSendOrchestrator` draining `KIND_BLE_MESH` rows). This closes
/// it on iOS with a much smaller footprint than Android's: a handful of
/// queued sends doesn't need a GRDB table and migration, so this is a
/// plain Codable array under one UserDefaults key — the same persistence
/// style `ConversationStore` itself used before message history moved to
/// GRDB (see that file's `migrateIfNeeded`).
///
/// Not `@MainActor`: `MeshOutboxDrain` (the only writer/reader today) does
/// all its work on the main actor already, and every method here is a
/// short, synchronous, lock-guarded read-modify-write — safe to call from
/// anywhere.
final class MeshOutboxStore {
    static let shared = MeshOutboxStore()

    /// A retryable send gives up after this long without a successful
    /// delivery — same order of magnitude as the Android sibling's
    /// `MAX_MESH_ATTEMPTS` ceiling (~1h), past which a dead peer's row
    /// would otherwise retry forever.
    static let maxAgeMs: Int64 = 60 * 60 * 1000

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let storageKey = "qaudion.mesh.outbox.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Replaces any existing entry for the same message (retrying an
    /// enqueue is idempotent, not a duplicate).
    func enqueue(_ entry: MeshPendingSend) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        all.removeAll { $0.messageId == entry.messageId }
        all.append(entry)
        saveLocked(all)
    }

    func remove(messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        all.removeAll { $0.messageId == messageId }
        saveLocked(all)
    }

    func bumpAttempts(messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadLocked()
        guard let idx = all.firstIndex(where: { $0.messageId == messageId }) else { return }
        all[idx].attempts += 1
        saveLocked(all)
    }

    /// W-MSGOUTBOX (2026-09-01) — is this message waiting on the mesh? A
    /// mesh-routed row stays `.sending` while it sits here (see
    /// `ChatContainer.finishMeshSend`), which is the same status the
    /// network outbox drainer (`ChatOutboxDrain`) looks for; this is how
    /// that drainer knows to leave a mesh-owned row alone instead of
    /// re-sending it over the WebSocket the user chose not to use.
    func contains(messageId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().contains { $0.messageId == messageId }
    }

    /// Entries whose target is currently reachable, oldest first — the
    /// order a drain pass should attempt them in.
    func pending(reachableNodeHexes: Set<String>) -> [MeshPendingSend] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
            .filter { reachableNodeHexes.contains($0.targetNodeHex) }
            .sorted { $0.createdAtMs < $1.createdAtMs }
    }

    /// Entries older than `maxAgeMs`. This store never marks a message
    /// failed on its own — the caller (`MeshOutboxDrain`) owns that
    /// decision and the `ConversationStore` write that goes with it; this
    /// only reports which rows have aged out.
    func expired(nowMs: Int64) -> [MeshPendingSend] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked().filter { nowMs - $0.createdAtMs > Self.maxAgeMs }
    }

    private func loadLocked() -> [MeshPendingSend] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let all = try? JSONDecoder().decode([MeshPendingSend].self, from: data) else {
            return []
        }
        return all
    }

    private func saveLocked(_ all: [MeshPendingSend]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

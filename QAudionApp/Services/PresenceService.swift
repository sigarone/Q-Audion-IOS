import Foundation
import Combine
import QAudionEngine

/// Thin Observable wrapper around `BCryptoPresenceManager` so the
/// SwiftUI layer can render online/offline dots without poking the
/// engine directly.
///
/// Lifecycle:
///  - `attach(provider:)` is called once after auth-success — it builds
///    a single `BCryptoPresenceManager` instance bound to the live WS
///    transport and registers a `statusChanged` callback that flushes
///    into `@Published var statuses`.
///  - `subscribe(userIds:)` replaces the tracked set on the wire (the
///    server treats each `presence_subscribe` as authoritative). The
///    natural caller is the contacts list / conversations list once
///    they have loaded the visible userIds.
///  - `status(for:)` is a read-through for views that need a single dot
///    without subscribing the whole map.
///
/// Engine parity: matches the Android `PresenceRepository` and Desktop
/// `PresenceStore`. Wire shape:
///   client → server: `{ "type": "presence_subscribe", "data": { "user_ids": [...] } }`
///   server → client: `{ "type": "presence_update",   "data": { "user_id", "status" } }`
@MainActor
final class PresenceService: ObservableObject {

    /// Most-recently-seen status per userId, in canonical engine values
    /// (`.online` / `.offline` / `.unknown`). Never nil — missing keys
    /// default to `.unknown` via `status(for:)`.
    @Published private(set) var statuses: [String: BCryptoPresenceManager.Status] = [:]

    private var manager: BCryptoPresenceManager?
    private var subscribed: Set<String> = []

    /// Bind to the live engine. Idempotent — calling with the same
    /// provider replaces the manager and re-subscribes any tracked ids
    /// so the new WS connection picks up the same state.
    func attach(provider: BCryptoBackendProvider) {
        let mgr = provider.presenceManager
        // Statuses arrive on a background queue inside the engine; the
        // manager promises main-queue dispatch on `statusChanged` but
        // we still hop to MainActor to satisfy `@MainActor` isolation.
        mgr.statusChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.statuses = snapshot
            }
        }
        self.manager = mgr
        // Re-emit on reconnect — if we had a tracked set from a previous
        // attach, restore it on the new transport.
        if !subscribed.isEmpty {
            mgr.subscribe(userIds: Array(subscribed))
        }
    }

    /// Replace the tracked set. Server treats this as authoritative.
    /// Drops cached statuses for users no longer tracked so the UI
    /// doesn't display stale online dots after a contact is removed.
    func subscribe(userIds: [String]) {
        let set = Set(userIds.filter { !$0.isEmpty })
        subscribed = set
        statuses = statuses.filter { set.contains($0.key) }
        manager?.subscribe(userIds: Array(set))
    }

    /// Convenience helper for views that only need a single dot.
    func isOnline(_ userId: String) -> Bool {
        return (statuses[userId] ?? .unknown) == .online
    }

    func status(for userId: String) -> BCryptoPresenceManager.Status {
        return statuses[userId] ?? .unknown
    }

    /// Clear local state on logout. Also drops the manager reference so
    /// the next auth-success builds a fresh one bound to the new WS.
    func reset() {
        manager?.statusChanged = nil
        manager = nil
        subscribed.removeAll()
        statuses.removeAll()
    }
}

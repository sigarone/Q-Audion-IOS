import Foundation

/// Tracks the online status of a fixed set of contacts via the
/// `presence_subscribe` / `presence_update` WebSocket flow defined in
/// `bcrypto-server/internal/signaling/messages.go`.
///
/// Server contract:
/// - Client sends `{ "type": "presence_subscribe", "data": { "user_ids": [...] } }`
///   once per connection (or whenever the tracked set changes).
/// - Server responds with `{ "type": "presence_update", "data": { "user_id", "status" } }`
///   for every tracked user and pushes further updates whenever a user's
///   status changes ("online" / "offline").
///
/// This manager exposes an `@Published`-style notification via `statusChanged`
/// so SwiftUI views (`ConversationListView`, `HomeView`) can reactively
/// re-render presence badges. It is safe to call from any thread; the
/// internal state is guarded by an `NSLock`.
public final class BCryptoPresenceManager: @unchecked Sendable {

    public enum Status: String {
        case online, offline, unknown
    }

    private let ws: BCryptoWebSocketClient
    private let lock = NSLock()
    private var statuses: [String: Status] = [:]   // userId → status
    private var subscribed: Set<String> = []       // currently subscribed userIds

    /// Fired on the main queue every time a `presence_update` modifies the
    /// known status map. Parameter: the full current userId → status
    /// dictionary (a snapshot, safe to read without extra synchronisation).
    public var statusChanged: (([String: Status]) -> Void)?

    public init(ws: BCryptoWebSocketClient) {
        self.ws = ws
        ws.registerHandler(type: "presence_update") { [weak self] _, data in
            self?.handlePresenceUpdate(data)
        }
    }

    // MARK: - Subscription management

    /// Replace the tracked user set. Sends a single `presence_subscribe` with
    /// the full list. The server treats the list as the authoritative set,
    /// so newly-added users start receiving updates and dropped users stop.
    public func subscribe(userIds: [String]) {
        lock.lock()
        subscribed = Set(userIds)
        // Drop any cached statuses for users we're no longer tracking so the
        // UI doesn't display stale information for a contact that was removed.
        let snapshot = statuses.filter { subscribed.contains($0.key) }
        statuses = snapshot
        lock.unlock()

        ws.send(type: "presence_subscribe", data: ["user_ids": userIds])

        notifyListeners(snapshot: snapshot)
    }

    /// Add a single user to the subscription set without losing existing
    /// subscriptions. Re-sends the full list because the server treats each
    /// `presence_subscribe` as a replace.
    public func addSubscriber(_ userId: String) {
        lock.lock()
        subscribed.insert(userId)
        let current = Array(subscribed)
        lock.unlock()
        ws.send(type: "presence_subscribe", data: ["user_ids": current])
    }

    public func unsubscribe(_ userId: String) {
        lock.lock()
        subscribed.remove(userId)
        statuses.removeValue(forKey: userId)
        let current = Array(subscribed)
        let snapshot = statuses
        lock.unlock()
        ws.send(type: "presence_subscribe", data: ["user_ids": current])
        notifyListeners(snapshot: snapshot)
    }

    /// Read the most recently known status for a user. Returns `.unknown`
    /// if the user hasn't been subscribed or no update has arrived yet.
    public func status(for userId: String) -> Status {
        lock.lock(); defer { lock.unlock() }
        return statuses[userId] ?? .unknown
    }

    /// Snapshot of the full userId → status map. Useful for populating a
    /// list UI in a single read.
    public var allStatuses: [String: Status] {
        lock.lock(); defer { lock.unlock() }
        return statuses
    }

    // MARK: - Inbound handler

    private func handlePresenceUpdate(_ data: [String: Any]) {
        guard let userId = data["user_id"] as? String,
              let statusString = data["status"] as? String else { return }
        let status = Status(rawValue: statusString) ?? .unknown

        lock.lock()
        // Silently ignore updates for users we aren't tracking — server may
        // fan out updates to all connected clients for a given user id and
        // we don't want to cache state the UI never asked for.
        guard subscribed.contains(userId) else {
            lock.unlock()
            return
        }
        statuses[userId] = status
        let snapshot = statuses
        lock.unlock()

        notifyListeners(snapshot: snapshot)
    }

    private func notifyListeners(snapshot: [String: Status]) {
        guard let callback = statusChanged else { return }
        DispatchQueue.main.async { callback(snapshot) }
    }
}

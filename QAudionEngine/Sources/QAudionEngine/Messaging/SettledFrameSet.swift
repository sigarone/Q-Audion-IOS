import Foundation

/// 2026-09-19 service-message root fix — bounded memory of inbound frames whose
/// outcome is final (consumed service frame, dropped frame, persisted user row,
/// placeholder).
///
/// Consulted BEFORE decrypt on every path that can see a frame twice (live
/// `msg_receive`, `msg_pending_sync` replay on every reconnect, the retry
/// drain). A consumed ratchet key cannot open the same ciphertext a second
/// time, so without this a frame that was handled correctly and merely came
/// back (the server keeps an un-acked entry pending for 24 h and replays it on
/// every reconnect) would fail its second decrypt and turn into a placeholder.
///
/// FIFO-bounded: the oldest key is forgotten first once ``capacity`` is
/// exceeded. Keys are opaque strings built by the caller; the two helpers
/// below fix the shape so live and replay paths agree.
public struct SettledFrameSet: Equatable, Sendable {

    public static let defaultCapacity: Int = 512

    public let capacity: Int
    private var order: [String] = []
    private var members: Set<String> = []

    public init(capacity: Int = SettledFrameSet.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { order.count }

    public func contains(_ key: String) -> Bool {
        members.contains(key)
    }

    /// Inserts `key`; a key already present keeps its position.
    public mutating func insert(_ key: String) {
        guard !members.contains(key) else { return }
        members.insert(key)
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            members.remove(evicted)
        }
    }

    // MARK: Key shapes

    /// Key for the server-assigned message id.
    public static func serverKey(_ serverMessageId: String) -> String {
        "s:" + serverMessageId
    }

    /// Key for the sender's `client_msg_id`, scoped by sender so two peers'
    /// UUIDs can never collide into a drop.
    public static func clientKey(senderId: String, clientMsgId: String) -> String {
        "c:" + senderId + ":" + clientMsgId
    }

    /// True when either identifier of a frame is already settled.
    public func containsFrame(serverMessageId: String, senderId: String, clientMsgId: String?) -> Bool {
        // An empty server id is "unknown", never a shared key that would swallow every later frame.
        if !serverMessageId.isEmpty, contains(Self.serverKey(serverMessageId)) { return true }
        if let cmid = clientMsgId, !cmid.isEmpty,
           contains(Self.clientKey(senderId: senderId, clientMsgId: cmid)) {
            return true
        }
        return false
    }

    /// Settles a frame. `includeClientKey` is false for a placeholder: a
    /// resend of the same `client_msg_id` must still get through so it can
    /// replace the placeholder in place.
    public mutating func insertFrame(
        serverMessageId: String, senderId: String, clientMsgId: String?, includeClientKey: Bool
    ) {
        if !serverMessageId.isEmpty { insert(Self.serverKey(serverMessageId)) }
        if includeClientKey, let cmid = clientMsgId, !cmid.isEmpty {
            insert(Self.clientKey(senderId: senderId, clientMsgId: cmid))
        }
    }
}

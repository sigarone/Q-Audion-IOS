import Foundation

/// The packet the app really sealed or opened for the row `rowId`. Carries no plain text and no key material: only the
/// public packet size and the first bytes of the packet in base64 (enough for the 240 characters that are animated).
public struct EnigmaWireEvent: Sendable {
    public let rowId: String
    /// The conversation the row belongs to (only the open conversation animates).
    public let conversationKey: String
    public let direction: EnigmaDirection
    /// Real length in bytes of the whole packet.
    public let packetBytes: Int
    /// Base64 of the first `EnigmaBus.prefixBytes` bytes of the packet.
    public let wirePrefixBase64: String

    public init(rowId: String, conversationKey: String, direction: EnigmaDirection, packetBytes: Int, wirePrefixBase64: String) {
        self.rowId = rowId
        self.conversationKey = conversationKey
        self.direction = direction
        self.packetBytes = packetBytes
        self.wirePrefixBase64 = wirePrefixBase64
    }
}

/// One-way hand-off from the send and receive code to the screen.
///
/// Both entry points (`sealed`, `opened`) are called AFTER the cipher has produced its result and are fire-and-forget:
/// synchronous, non-throwing, they never wait for the screen and never touch the packet. Both callers (the send service
/// and the incoming-message handler of the app state) already run on the main actor, so the bus is main-actor isolated and
/// the event reaches the screen's state before the caller goes on (a received row is held back before it is first drawn).
///
/// While no chat screen has the effect switched on (`acquire` not called) they return at their first line, so with the
/// effect off the cost is one integer comparison.
@MainActor
public final class EnigmaBus {
    public static let shared = EnigmaBus()

    /// 180 bytes encode to exactly 240 base64 characters: the animated head of a packet.
    public static let prefixBytes: Int = 180

    private var users = 0
    private var sink: (@MainActor (EnigmaWireEvent) -> Void)?

    public init() {}

    public var isActive: Bool { users > 0 }

    public func acquire() {
        users += 1
    }

    public func release() {
        if users > 0 { users -= 1 }
    }

    /// Where the events go.
    public func setSink(_ newSink: (@MainActor (EnigmaWireEvent) -> Void)?) {
        sink = newSink
    }

    /// The app just sealed `wire` for the outgoing row `rowId` (hook 1: after the encryption, send side).
    public func sealed(rowId: String, conversationKey: String, wire: Data) {
        guard users > 0 else { return }
        emit(rowId: rowId, conversationKey: conversationKey, direction: .send, wire: wire)
    }

    /// The app just opened (tag verified) `wire`, which became the incoming row `rowId` (hook 2: after the verification,
    /// receive side). Never called for a packet whose verification failed.
    public func opened(rowId: String, conversationKey: String, wire: Data) {
        guard users > 0 else { return }
        emit(rowId: rowId, conversationKey: conversationKey, direction: .receive, wire: wire)
    }

    private func emit(rowId: String, conversationKey: String, direction: EnigmaDirection, wire: Data) {
        guard let target = sink else { return }
        let total = wire.count
        if total == 0 { return }
        let head = wire.prefix(EnigmaBus.prefixBytes)
        let event = EnigmaWireEvent(
            rowId: rowId,
            conversationKey: conversationKey,
            direction: direction,
            packetBytes: total,
            wirePrefixBase64: head.base64EncodedString()
        )
        target(event)
    }
}

/// Which messages may reach the receive hook. Only a LIVE message that opened and is plain text gets a scene: history,
/// replays of pending frames, retried frames (they already waited), service payloads, files and the "could not decrypt"
/// placeholder never do. A packet whose verification failed never gets here at all (the hook sits after the verified
/// open, and the failure path does not call it).
public enum EnigmaHookPolicy {
    public static func announceReceive(live: Bool, isRetry: Bool, isUndecryptablePlaceholder: Bool, isPlainText: Bool) -> Bool {
        live && !isRetry && !isUndecryptablePlaceholder && isPlainText
    }
}

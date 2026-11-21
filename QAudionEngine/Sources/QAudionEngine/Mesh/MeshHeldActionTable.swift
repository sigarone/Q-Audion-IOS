import Foundation

/// What a chat sends besides messages, and what a Bluetooth-only conversation does with each kind. The mesh carries text only,
/// so nothing here can go over it yet.
public enum MeshChatTraffic: String, CaseIterable, Sendable {
    // User content: an action the user took on a message.
    case edit, reaction, deleteForEveryone
    // Service traffic.
    case deliveryReceipt, readReceipt, attachmentReceipt, typing, screenshotRequest, screenshotReply, timerEnvelope, avatarAnnounce

    /// The server transport ack of a message that arrived over the network (the `msg_delivered` frame that lets the server drop it
    /// from its pending queue). It reveals nothing new, so it is always sent. `deliveryReceipt` is the end-to-end one to the contact.
    case serverAck

    public var isUserContent: Bool {
        switch self {
        case .edit, .reaction, .deleteForEveryone: return true
        default: return false
        }
    }
}

public enum MeshChatTrafficRoute: Equatable, Sendable {
    /// Send it over the network as usual.
    case network
    /// Keep it, ask the user, and send it through the internet only on their answer.
    case hold
    /// Do not send it at all and do not ask.
    case skip
}

extension MeshFallbackPolicy {
    /// In a Bluetooth-only conversation user content (an edit, a reaction, a delete for everyone) is held and the user is asked;
    /// service traffic (receipts, typing, screenshot permission, timer envelopes) is skipped. Never the network. Elsewhere
    /// everything goes as before.
    public static func route(for traffic: MeshChatTraffic, bluetoothOnly: Bool) -> MeshChatTrafficRoute {
        guard bluetoothOnly, traffic != .serverAck else { return .network }
        return traffic.isUserContent ? .hold : .skip
    }
}

/// An action on a message that a Bluetooth-only conversation held back, with the state of its prompt. Persisted per target
/// message, so the prompt and the unsent state survive a restart. It keeps no text: an edit is rebuilt from the message row when
/// the user says yes. Nothing evicts an entry.
public struct MeshHeldAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case edit, reaction, deleteForEveryone }

    public var kind: Kind
    public var targetClientMsgId: String
    /// The emoji of a reaction.
    public var emoji: String?
    public var state: MeshBtOnlyState

    public init(kind: Kind, targetClientMsgId: String, emoji: String? = nil, state: MeshBtOnlyState = .prompted) {
        self.kind = kind
        self.targetClientMsgId = targetClientMsgId
        self.emoji = emoji
        self.state = state
    }
}

public struct MeshHeldActionTable: Codable, Equatable, Sendable {
    public private(set) var items: [MeshHeldAction]

    public init(items: [MeshHeldAction] = []) {
        self.items = items
    }

    /// Holds an action. A second edit of the same message replaces the first (the row holds the latest text); a reaction that is
    /// held twice is the user taking it back, and both disappear (a reaction envelope toggles on the receiver).
    public mutating func hold(_ action: MeshHeldAction) {
        switch action.kind {
        case .edit:
            items.removeAll { $0.kind == .edit && $0.targetClientMsgId == action.targetClientMsgId }
        case .reaction:
            if let index = items.firstIndex(where: {
                $0.kind == .reaction && $0.targetClientMsgId == action.targetClientMsgId && $0.emoji == action.emoji
            }) {
                items.remove(at: index)
                return
            }
        case .deleteForEveryone:
            // The delete makes the other actions on the message pointless.
            items.removeAll { $0.targetClientMsgId == action.targetClientMsgId }
        }
        var held = action
        held.state = .prompted
        items.append(held)
    }

    public func pending(target: String) -> [MeshHeldAction] {
        items.filter { $0.targetClientMsgId == target }
    }

    /// The state to show on the message: prompted if any action waits for an answer, else unsent if any was refused.
    public func state(target: String) -> MeshBtOnlyState {
        let states = pending(target: target).map(\.state)
        if states.contains(.prompted) { return .prompted }
        return states.isEmpty ? .idle : .undelivered
    }

    public mutating func setState(_ state: MeshBtOnlyState, target: String) {
        for index in items.indices where items[index].targetClientMsgId == target {
            items[index].state = state
        }
    }

    /// The user said yes: the actions of the message leave the table (the caller sends them).
    @discardableResult
    public mutating func release(target: String) -> [MeshHeldAction] {
        let released = pending(target: target)
        items.removeAll { $0.targetClientMsgId == target }
        return released
    }
}

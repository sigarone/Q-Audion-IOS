import Foundation
import QAudionEngine

/// Persists `MeshHeldActionTable`: the edits, reactions and deletes for everyone that a Bluetooth-only conversation held back,
/// with the state of their prompt. No text and no key material (an edit is rebuilt from the message row).
final class MeshHeldActionStore {
    static let shared = MeshHeldActionStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let storageKey = "qaudion.mesh.heldactions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hold(_ action: MeshHeldAction) {
        mutate { $0.hold(action) }
    }

    func state(target: String?) -> MeshBtOnlyState {
        guard let target, !target.isEmpty else { return .idle }
        lock.lock()
        defer { lock.unlock() }
        return load().state(target: target)
    }

    func setState(_ state: MeshBtOnlyState, target: String) {
        mutate { $0.setState(state, target: target) }
    }

    /// The user said yes: the actions leave the store and the caller sends them.
    func release(target: String) -> [MeshHeldAction] {
        var released: [MeshHeldAction] = []
        mutate { released = $0.release(target: target) }
        return released
    }

    private func mutate(_ change: (inout MeshHeldActionTable) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var table = load()
        change(&table)
        guard let data = try? JSONEncoder().encode(table) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func load() -> MeshHeldActionTable {
        guard let data = defaults.data(forKey: Self.storageKey),
              let table = try? JSONDecoder().decode(MeshHeldActionTable.self, from: data) else {
            return MeshHeldActionTable()
        }
        return table
    }
}

/// Whether a conversation is Bluetooth only, asked by the paths that send something other than a message. The contact's routing
/// preference or a target armed on the radar for the conversation.
@MainActor
enum BluetoothOnlyGate {
    static func isBluetoothOnly(peerUserId: String) -> Bool {
        if MeshRoutingPreferenceStore().preference(for: peerUserId) == .meshOnly { return true }
        guard !MeshRuntime.shared.activeTargets.isEmpty else { return false }
        let conversation = ConversationStore().loadConversations().first { $0.peerUserId == peerUserId && $0.kind == .oneToOne }
        guard let conversation else { return false }
        return MeshRuntime.shared.activeTarget(for: conversation.id.uuidString) != nil
    }

    /// A send the Bluetooth-only rule refused: the row is held and the prompt is shown. A message that does not exist as a row (a
    /// technical frame) is not touched.
    static func holdRefused(messageId: UUID) {
        let store = ConversationStore()
        guard let found = store.findByClientMsgId(messageId.uuidString), found.message.direction == .outgoing else { return }
        store.setBluetoothHold(id: messageId, hold: true)
        if MeshBtPromptStore.shared.state(messageId: messageId.uuidString) == .idle {
            MeshBtPromptStore.shared.set(.prompted, messageId: messageId.uuidString)
        }
        NotificationCenter.default.post(
            name: AppState.chatRefreshNotification, object: nil,
            userInfo: ["conversationId": found.conversationId])
    }

    /// A chat just became Bluetooth only (the contact was switched to it, or a target was armed): a live share of that chat stops,
    /// because it streams over the network and the mesh cannot carry it.
    static func chatBecameBluetoothOnly(peerUserId: String) {
        LocationShareCenter.shared.stopShares(forPeer: peerUserId, reason: "bluetooth_only", final: .now)
    }

    /// Whether this traffic may go over the network to this peer.
    static func networkAllowed(_ traffic: MeshChatTraffic, peerUserId: String) -> Bool {
        MeshFallbackPolicy.route(for: traffic, bluetoothOnly: isBluetoothOnly(peerUserId: peerUserId)) == .network
    }
}

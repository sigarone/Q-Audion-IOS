import Foundation
import QAudionEngine

/// The two rate limits of the mesh receive path that have to outlive one call:
///   - the unknown-sender directory refresh runs at most once per 60 s across all callers
///     (docs/mesh/MESH_LINK_SPEC.md section 11);
///   - a duplicate message is answered with a fresh delivery receipt at most every 10 s per message, so a sender
///     that keeps retransmitting because the first receipt was lost finally gets one, without every duplicate
///     arrival (a flood delivers the same packet several times) causing a receipt.
/// Plain values; the rules are `MeshRefreshGate` / `MeshKeyedGate` in the engine.
@MainActor
final class MeshReceiveSupport {
    static let shared = MeshReceiveSupport()

    private var contactRefreshGate = MeshRefreshGate()
    private var duplicateAckGate = MeshKeyedGate(intervalMs: 10_000)

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// True (and the gate closes) if a contact refresh may run now.
    func mayRefreshContacts() -> Bool {
        contactRefreshGate.tryEnter(nowMs: Self.nowMs())
    }

    /// True (and the gate closes) if the duplicate of `clientMsgId` may be answered with a receipt now.
    func mayAnswerDuplicate(clientMsgId: String) -> Bool {
        duplicateAckGate.tryEnter(key: clientMsgId, nowMs: Self.nowMs())
    }
}

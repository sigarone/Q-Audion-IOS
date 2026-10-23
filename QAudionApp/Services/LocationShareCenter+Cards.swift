import Foundation
import QAudionEngine

/// What the card of a location row shows, from the row and the live-share store (`LocationCardResolver` holds the rules).
extension LocationShareCenter {

    /// The state of the card for `message`, at the present. For a received live row the receiver of that conversation is first brought
    /// to the present: a share whose end time was reached is ENDED whether or not anything looked at it.
    func cardState(for message: Message) -> LocationCardState {
        let now: Int64 = Self.nowUnix()
        let clientId: String = message.clientMsgId ?? ""
        let outgoing: Bool = message.direction == .outgoing
        var ownEndAt: Int64?
        var view: LiveShareView?
        if outgoing {
            if let share = activeShares.first(where: { $0.id == clientId }) {
                ownEndAt = Int64(share.endAt.timeIntervalSince1970)
            }
        } else if let peer = message.senderUserId, let receiver = shareReceiver(forPeer: peer) {
            view = receiver.share(id: clientId, now: now)
        }
        return LocationCardResolver.resolve(rowText: message.plaintext, outgoing: outgoing, ownShareEndAt: ownEndAt, view: view)
    }

    /// The running share of this device in the conversation with `peerUserId`, for the strip above the composer.
    func activeShare(forPeer peerUserId: String) -> ActiveShare? {
        activeShares.first { $0.peerUserId == peerUserId }
    }

    /// The user taps "Interrompi" on a card or on the strip: one tap, no confirmation (docs 1.4).
    func stopFromUser(startClientMsgId id: String) {
        stopShare(startClientMsgId: id, reason: "user", final: .onTick)
    }

    func stopFromUser(peerUserId: String) {
        stopShares(forPeer: peerUserId, reason: "user", final: .onTick)
    }
}

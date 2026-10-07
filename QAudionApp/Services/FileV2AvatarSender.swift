import Foundation
import QAudionEngine

/// The user's own avatar, sent to one contact in the file transfer v2 format (WIRE_SPEC section 12, kind `avatar`): the JPEG is
/// encrypted in the v2 format with a key of its own for this contact, uploaded to the server, and the descriptor travels as the body
/// of an ordinary end-to-end encrypted chat message to that contact. The contact's app recognises it by its kind and keeps it as the
/// picture of the contact: it never becomes a row of a conversation, a preview, an unread count or a notification.
///
/// One call is one contact (the caller loops over the contacts, paced, and decides when an avatar is worth sending: see
/// `AvatarAnnounceCoordinator`). A re-send of the same avatar is a new file with a new key (WIRE_SPEC 12.8 rule 5); to keep the
/// storage of the account (one quota for every object, kept for weeks) from filling with copies, the object of the PREVIOUS send to
/// the same contact is deleted as soon as the new one has been announced: a contact who has not fetched the old one yet fetches the
/// new one, an avatar being the same picture.
@MainActor
enum FileV2AvatarSender {

    enum Outcome: Equatable {
        /// The descriptor was handed to the chat channel.
        case sent
        /// The chat cannot seal a message for this contact yet (no session, no pairwise key). Nothing was uploaded and no key
        /// exchange was started: a broadcast to many contacts must not start one per contact; the next real exchange does.
        case noChannel
        /// The upload or the message failed; `code` is the telemetry code (no identifier, no key).
        case failed(code: String)
    }

    /// The object of the last avatar sent to each contact: an object id is not a secret (it is useless without the token), and it is
    /// all that is needed to delete it.
    private static let lastObjectsKey = "qaudion.avatarV2.lastObjects"

    private struct DeliveryRefused: Error {}

    /// Uploads `avatarFile` (the self-avatar JPEG, left where it is: it is only read) and announces it to `peerId`.
    static func send(avatarFile: URL, to peerId: String, appState: AppState) async -> Outcome {
        let sendService = ChatMessageSendService(appState: appState)
        guard sendService.hasTextChannel(peerUserId: peerId) else { return .noChannel }
        let server = FileV2AppServices.makeServer(appState: appState)
        let request = FileV2Sender.Request(
            sourceURL: avatarFile, kind: .avatar, name: nil, mimeType: "image/jpeg", audience: .recipient(peerId))
        var announcedBody: String?
        do {
            try await FileV2Sender(server: server).send(request) { body in
                let outcome = await sendService.sendEncrypted(messageId: UUID(), peerUserId: peerId, plaintext: body)
                switch outcome {
                case .delivered, .sent:
                    announcedBody = body
                case .failed:
                    throw DeliveryRefused()
                }
            }
        } catch let failure as FileV2Failure {
            return .failed(code: failure.code)
        } catch {
            return .failed(code: "announce_not_sent")
        }
        if let body = announcedBody, let object = FileV2ChatBody.descriptor(ofBody: body)?.source.obj {
            await replaceLastObject(of: peerId, with: object, server: server)
        }
        return .sent
    }

    /// Remembers `object` as the avatar object of `peerId` and deletes the one it replaces (best effort: a 404 or a network error is
    /// ignored, the server's own retention removes what is left).
    private static func replaceLastObject(of peerId: String, with object: String, server: FileV2Server) async {
        var objects = UserDefaults.standard.dictionary(forKey: lastObjectsKey) as? [String: String] ?? [:]
        let previous = objects[peerId]
        objects[peerId] = object
        UserDefaults.standard.set(objects, forKey: lastObjectsKey)
        if let previous, previous != object {
            _ = try? await server.delete(obj: previous)
        }
    }
}

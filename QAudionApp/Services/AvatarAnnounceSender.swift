import Foundation
import CryptoKit
import QAudionEngine

/// E2EE avatar transport (see `docs/E2EE_AVATAR_TRANSPORT_DESIGN.md` in
/// bcrypto-server) — sender side of the `qa_ctl:1` `avatar_announce`
/// envelope. Mirrors `ChatAttachAnnounceSender` (W355) almost exactly:
/// same `AttachmentEncryption` primitive, same upload endpoint, same
/// `qa_ctl` control-channel pattern riding an ordinary encrypted
/// `msg_send` — the only real difference is the envelope type and the
/// `version` counter used for receiver-side dedup.
///
/// **One call = one peer.** The caller (`AppState`, on avatar change or
/// first contact) loops over every currently-known peer and calls this
/// once per peer, so each peer gets ciphertext encrypted under ITS OWN
/// pairwise chain key — never one shared URL/blob every authenticated
/// account could fetch (the plaintext-avatar gap this replaces, see the
/// design doc §1).
@MainActor
final class AvatarAnnounceSender {

    enum SendError: Error, LocalizedError {
        case notAuthenticated
        case readFailed(String)
        case encryptFailed(String)
        case uploadFailed(String)
        case envelopeFailed(String)
        /// No real pairwise PSK exists yet for this peer — same
        /// fail-closed contract as `ChatAttachAnnounceSender`. Caller
        /// should skip this peer (a key exchange is already the normal
        /// consequence of any other send attempt to them) rather than
        /// retry avatar delivery on its own loop.
        case pskMissing

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:    return "Non autenticato"
            case .readFailed(let m):   return "Lettura fallita: \(m)"
            case .encryptFailed(let m):return "Cifratura fallita: \(m)"
            case .uploadFailed(let m): return "Upload fallito: \(m)"
            case .envelopeFailed(let m): return "Envelope fallito: \(m)"
            case .pskMissing: return "Scambio chiavi in corso — riprova tra poco."
            }
        }
    }

    private let appState: AppState
    private let vault = SovereignKeyVault()

    init(appState: AppState) {
        self.appState = appState
    }

    /// Encrypt `avatarJpegBytes` under `recipientUserId`'s pairwise
    /// chain key, upload the ciphertext, and return the `avatar_announce`
    /// JSON envelope ready to ride the normal encrypted send path.
    /// Does NOT trigger a key exchange on `.pskMissing` itself — the
    /// caller loops over many peers and should decide per-peer whether
    /// to trigger one (see `AppState.broadcastAvatarToKnownPeers`).
    func prepareEnvelopeJson(
        avatarJpegBytes: Data,
        recipientUserId: String,
        version: Int
    ) async throws -> String {
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let senderId = appState.currentUserId, !senderId.isEmpty else {
            throw SendError.notAuthenticated
        }
        _ = token

        let attachmentId = Self.uuidV4Bytes()
        let senderUuidBytes = Self.uuidBytes(from: senderId) ?? Self.uuidV4Bytes()
        let meta: AttachmentEncryption.Meta
        do {
            meta = try AttachmentEncryption.Meta(
                attachmentId: attachmentId,
                senderUuid: senderUuidBytes,
                mime: "image/jpeg",
                byteLength: avatarJpegBytes.count
            )
        } catch {
            throw SendError.encryptFailed(String(describing: error))
        }

        let chainKey: Data
        do {
            chainKey = try PairwiseChainKeyResolver.deriveChainKey(
                selfId: senderId, peerId: recipientUserId,
                infoLabel: "avatar-chain-v1", vault: vault
            )
        } catch PairwiseChainKeyResolver.ResolveError.pskMissing {
            throw SendError.pskMissing
        }

        let encrypted: AttachmentEncryption.Encrypted
        do {
            encrypted = try AttachmentEncryption.encryptAttachment(
                messageChainKey: chainKey, plaintext: avatarJpegBytes, meta: meta)
        } catch {
            throw SendError.encryptFailed(String(describing: error))
        }

        let provider = appState.makeUploadProvider()
        let fileId: String
        do {
            fileId = try await provider.storageApi.uploadFile(
                data: encrypted.ciphertext,
                filename: "avatar-\(attachmentId.base64EncodedString().prefix(16)).bin"
            )
        } catch {
            throw SendError.uploadFailed(error.localizedDescription)
        }

        let attMeta = AvatarAnnounceMeta(
            id: attachmentId.base64EncodedString(),
            mime: "image/jpeg",
            byteLength: Int64(avatarJpegBytes.count),
            sha256B64: encrypted.sha256Plain.base64EncodedString(),
            fileId: fileId,
            version: version
        )
        let envelope = AvatarAnnounceEnvelope(
            att: attMeta,
            ts: Int64(Date().timeIntervalSince1970)
        )
        do {
            return try envelope.toJsonString()
        } catch {
            throw SendError.envelopeFailed(String(describing: error))
        }
    }

    // MARK: - Helpers

    private static func uuidV4Bytes() -> Data {
        let u = UUID()
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    private static func uuidBytes(from str: String) -> Data? {
        guard let u = UUID(uuidString: str) else { return nil }
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
}

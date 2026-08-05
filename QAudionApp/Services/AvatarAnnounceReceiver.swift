import Foundation
import CryptoKit
import QAudionEngine

/// E2EE avatar transport — receiver side of the `qa_ctl:1`
/// `avatar_announce` envelope. Mirrors `ChatAttachAnnounceReceiver`
/// (W356) almost exactly. Caller (`AppState.handleIncomingMessage`)
/// downloads + decrypts, then writes the PLAINTEXT bytes to a local
/// cache file and stamps `ContactsStore.setAvatarLocalPath` — the
/// server-hosted ciphertext is never re-uploaded, never re-shared, and
/// this receiver never persists anything itself (pure
/// download-decrypt-return, same separation of concerns as the
/// attachment receiver).
@MainActor
final class AvatarAnnounceReceiver {

    enum ReceiveError: Error, LocalizedError {
        case notAuthenticated
        case downloadFailed(String)
        case decodeFailed(String)
        case invalidId
        /// No real pairwise PSK bound yet for this sender.
        case pskMissing

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:    return "Non autenticato"
            case .downloadFailed(let m): return "Download fallito: \(m)"
            case .decodeFailed(let m): return "Decodifica fallita: \(m)"
            case .invalidId:           return "ID avatar non valido"
            case .pskMissing: return "Scambio chiavi in corso — riprova tra poco."
            }
        }
    }

    private let appState: AppState
    private let vault = SovereignKeyVault()

    init(appState: AppState) {
        self.appState = appState
    }

    /// Download + decrypt. Returns the PLAINTEXT JPEG bytes — caller
    /// writes them to disk and updates `ContactsStore`.
    func downloadAndDecrypt(
        envelope: AvatarAnnounceEnvelope,
        senderId: String
    ) async throws -> Data {
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let recipientId = appState.currentUserId, !recipientId.isEmpty else {
            throw ReceiveError.notAuthenticated
        }
        guard let attachmentId = Data(base64Encoded: envelope.att.id),
              attachmentId.count == 16 else {
            throw ReceiveError.invalidId
        }
        guard let expectedSha = Data(base64Encoded: envelope.att.sha256B64),
              expectedSha.count == 32 else {
            throw ReceiveError.decodeFailed("sha256_b64 not 32 bytes")
        }
        _ = token

        // 2026-07-30 fix (W-AVATAR404): download via the tus recipient
        // capability-token path — see AvatarAnnounceMeta kdoc for why the
        // legacy `storageApi.downloadFile` always 404'd for a recipient.
        let provider = appState.makeUploadProvider()
        let claim = DownloadTokenClaim(
            fileId: envelope.att.fileId,
            expiresAtMs: envelope.att.tokenExpiresMs,
            maxUses: envelope.att.tokenMaxUses,
            tokenHex: envelope.att.token
        )
        let ciphertext: Data
        do {
            ciphertext = try await provider.downloadTokenClient.downloadCiphertext(
                fileId: envelope.att.fileId,
                claim: claim
            )
        } catch {
            throw ReceiveError.downloadFailed(error.localizedDescription)
        }

        let senderUuidBytes = Self.uuidBytes(from: senderId) ?? Data(repeating: 0, count: 16)
        let meta: AttachmentEncryption.Meta
        do {
            meta = try AttachmentEncryption.Meta(
                attachmentId: attachmentId,
                senderUuid: senderUuidBytes,
                mime: envelope.att.mime,
                byteLength: Int(envelope.att.byteLength)
            )
        } catch {
            throw ReceiveError.decodeFailed(String(describing: error))
        }

        // W-AVATARPSKPICK (2026-08-05, live-log confirmed): this used to
        // derive the chain key from the single "newest" PSK
        // (`deriveChainKey(...vault:)`) — the same single-candidate shape
        // W-MSGPSKPICK (2026-08-02) already fixed for the message-receive
        // path (`AppState.handleIncomingMessage`), for the identical
        // reason: a call rebinds a fresh call-derived PSK for this contact
        // on BOTH devices, and if that rebind lands between the sender's
        // encrypt and this device's decrypt, "newest" can disagree by one
        // slot — the receiver then derives a different chain key than the
        // sender used, and `AttachmentEncryption.decryptAttachment`'s AEAD
        // open fails outright with no fallback. Confirmed live: two
        // `recv applied=0 code=5 ... decodeFailed("openFailed")` entries
        // for the same peer, each racing multiple `call-derived PSK bound
        // to peer=<id>` events within the same few seconds — exactly the
        // W-MSGPSKPICK race, just never ported to this receiver. Mirror
        // that fix: try every PSK genuinely bound to this peer, newest
        // first, same as the message path's `pskCandidates` retry.
        let pskCandidates = PairwiseChainKeyResolver.orderedPskCandidates(peerId: senderId, vault: vault)
        guard !pskCandidates.isEmpty else { throw ReceiveError.pskMissing }

        var lastError: Error = ReceiveError.decodeFailed("no PSK candidate opened")
        for psk in pskCandidates {
            let chainKey = PairwiseChainKeyResolver.deriveChainKey(
                psk: psk, selfId: recipientId, peerId: senderId, infoLabel: "avatar-chain-v1")
            do {
                return try AttachmentEncryption.decryptAttachment(
                    messageChainKey: chainKey,
                    ciphertext: ciphertext,
                    meta: meta,
                    expectedSha256Plain: expectedSha
                )
            } catch {
                lastError = error
                continue
            }
        }
        throw ReceiveError.decodeFailed(String(describing: lastError))
    }

    private static func uuidBytes(from str: String) -> Data? {
        guard let u = UUID(uuidString: str) else { return nil }
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
}

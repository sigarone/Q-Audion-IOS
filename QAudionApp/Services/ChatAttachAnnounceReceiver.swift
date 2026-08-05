import Foundation
import CryptoKit
import QAudionEngine

/// W356 — receiver-side counterpart of [ChatAttachAnnounceSender].
///
/// Given a parsed [AttachAnnounceEnvelope] (from the inbound chat
/// plaintext) plus the (sender, recipient) pair, this service:
///
///   1. Mints the same deterministic chain key the sender used.
///   2. Downloads the ciphertext from `/api/v1/files/{file_id}` via
///      the existing storage API.
///   3. Calls AttachmentEncryption.decryptAttachment which:
///        - re-derives (key, nonce) from chainKey + attachmentId + senderUuid
///        - opens the XChaCha20-Poly1305 sealed box with the canonical
///          CBOR AAD (anti-tamper: any tampered byte invalidates the tag)
///        - verifies SHA-256(plaintext) matches the announced digest
///   4. Writes the recovered plaintext to a temp file and returns the
///      URL so the caller (UI bubble) can play the voice note.
///
/// **Cross-platform contract:** the chain key derivation, AEAD opening,
/// and SHA-256 verification all match the sender's path exactly so an
/// Android-produced attach_announce envelope decodes here without any
/// coordination beyond knowing the (sender, recipient) pair.
@MainActor
final class ChatAttachAnnounceReceiver {

    enum ReceiveError: Error, LocalizedError {
        case notAuthenticated
        case downloadFailed(String)
        case decodeFailed(String)
        case writeFailed(String)
        case invalidId
        /// FIX H1-PARITY (2026-07-30): no real pairwise PSK bound yet for
        /// this sender — see `PairwiseChainKeyResolver.orderedPskCandidates`.
        case pskMissing

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:    return "Non autenticato"
            case .downloadFailed(let m): return "Download fallito: \(m)"
            case .decodeFailed(let m): return "Decodifica fallita: \(m)"
            case .writeFailed(let m):  return "Scrittura fallita: \(m)"
            case .invalidId:           return "ID allegato non valido"
            case .pskMissing: return "Scambio chiavi in corso — riprova tra poco."
            }
        }
    }

    private let appState: AppState
    private let vault = SovereignKeyVault()

    init(appState: AppState) {
        self.appState = appState
    }

    /// Download + decrypt + write to temp file. Returns the temp URL.
    func downloadAndDecrypt(
        envelope: AttachAnnounceEnvelope,
        senderId: String
    ) async throws -> URL {
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

        // 1. Download ciphertext.
        // `token` only gates the "authenticated" early-throw above.
        _ = token
        // UPLOAD-401 FIX (2026-07-03) — refresher-wired provider builder
        // instead of a bare BCryptoBackendProvider, so downloading a
        // received voice note self-heals on token expiry instead of 401'ing
        // forever (see AppState.makeUploadProvider).
        let provider = appState.makeUploadProvider()
        let ciphertext: Data
        do {
            ciphertext = try await provider.storageApi.downloadFile(fileId: envelope.att.fileId)
        } catch {
            throw ReceiveError.downloadFailed(error.localizedDescription)
        }

        // 2. Build meta + chain key (same derivation as sender).
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
        // W-ATTACHPSKPICK (2026-08-05) — same fix as AvatarAnnounceReceiver
        // (identical bug, sibling receiver): this used to derive the chain
        // key from a single "newest PSK" candidate
        // (`deterministicChainKey`, now removed). A completed call rebinds
        // a fresh call-derived PSK for this contact on BOTH devices; if
        // that rebind lands between the sender's encrypt and this
        // device's decrypt, each side can consider a DIFFERENT PSK
        // "newest", so the derived chain key differs and the AEAD open
        // fails outright with no fallback — the identical race
        // W-MSGPSKPICK (2026-08-02) already fixed for the message-receive
        // path. Try every PSK genuinely bound to this peer, newest first,
        // one AEAD open each, same as that fix and the avatar receiver.
        let pskCandidates = PairwiseChainKeyResolver.orderedPskCandidates(peerId: senderId, vault: vault)
        guard !pskCandidates.isEmpty else {
            // FIX H1-PARITY: no real pairwise PSK bound yet for this
            // sender — kick off a key exchange and fail closed rather
            // than falling back to a server-guessable key.
            appState.triggerKeyExchange(with: senderId)
            throw ReceiveError.pskMissing
        }

        // 3. Decrypt + verify SHA-256.
        var plaintext: Data? = nil
        var lastError: Error = ReceiveError.decodeFailed("no PSK candidate opened")
        for psk in pskCandidates {
            let chainKey = PairwiseChainKeyResolver.deriveChainKey(
                psk: psk, selfId: recipientId, peerId: senderId, infoLabel: "attach-chain-v1")
            do {
                plaintext = try AttachmentEncryption.decryptAttachment(
                    messageChainKey: chainKey,
                    ciphertext: ciphertext,
                    meta: meta,
                    expectedSha256Plain: expectedSha
                )
                break
            } catch {
                lastError = error
                continue
            }
        }
        guard let plaintext else {
            throw ReceiveError.decodeFailed(String(describing: lastError))
        }

        // 4. Write to temp.
        //
        // W-GRPATTACHPATH (2026-08-03): `att.id` is base64 (16 raw bytes)
        // and its alphabet includes `/`, which `appendingPathComponent`
        // treats as a real path separator — an id containing one turns
        // this into a write inside a subdirectory that was never created
        // (write(to:) doesn't auto-create intermediates), failing with
        // NSFileWriteNoSuchFileError. Confirmed live on the group-chat
        // twin of this receiver (GroupAttachmentReceiver) — same
        // construction here, fixed the same way.
        let tempDir = FileManager.default.temporaryDirectory
        let ext = Self.fileExtension(forMime: envelope.att.mime)
        let safeId = String(envelope.att.id.prefix(16)).replacingOccurrences(of: "/", with: "_")
        let url = tempDir.appendingPathComponent("attach-\(safeId)\(ext)")
        do {
            try plaintext.write(to: url, options: [.atomic])
        } catch {
            throw ReceiveError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: - Helpers

    private static func uuidBytes(from str: String) -> Data? {
        // W388: `UUID.uuid` is a get-only computed property; copy the tuple
        // into a mutable local before passing as inout.
        guard let u = UUID(uuidString: str) else { return nil }
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    private static func fileExtension(forMime mime: String) -> String {
        switch mime.lowercased() {
        case "audio/opus":     return ".opus"
        case "audio/m4a", "audio/x-m4a", "audio/mp4": return ".m4a"
        case "audio/wav":      return ".wav"
        case "image/jpeg":     return ".jpg"
        case "image/png":      return ".png"
        case "video/mp4":      return ".mp4"
        case "application/pdf":return ".pdf"
        default:               return ".bin"
        }
    }
}

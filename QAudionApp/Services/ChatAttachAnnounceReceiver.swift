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
        /// this sender — see `deterministicChainKey`'s kdoc.
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
        let chainKey: Data
        do {
            chainKey = try Self.deterministicChainKey(senderId: senderId, recipientUserId: recipientId, vault: vault)
        } catch ReceiveError.pskMissing {
            // FIX H1-PARITY: no real pairwise PSK bound yet for this
            // sender — kick off a key exchange and fail closed rather
            // than falling back to a server-guessable key.
            appState.triggerKeyExchange(with: senderId)
            throw ReceiveError.pskMissing
        }

        // 3. Decrypt + verify SHA-256.
        let plaintext: Data
        do {
            plaintext = try AttachmentEncryption.decryptAttachment(
                messageChainKey: chainKey,
                ciphertext: ciphertext,
                meta: meta,
                expectedSha256Plain: expectedSha
            )
        } catch {
            throw ReceiveError.decodeFailed(String(describing: error))
        }

        // 4. Write to temp.
        let tempDir = FileManager.default.temporaryDirectory
        let ext = Self.fileExtension(forMime: envelope.att.mime)
        let url = tempDir.appendingPathComponent("attach-\(envelope.att.id.prefix(16))\(ext)")
        do {
            try plaintext.write(to: url, options: [.atomic])
        } catch {
            throw ReceiveError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: - Helpers

    /// Mirrors `ChatAttachAnnounceSender.deterministicChainKey` exactly
    /// (same FIX H1-PARITY fail-closed PSK ladder, factored into
    /// ``PairwiseChainKeyResolver``) — from the receiver's side, the
    /// PEER whose PSK is looked up is `senderId` (the other party), not
    /// `recipientUserId` (self).
    private static func deterministicChainKey(
        senderId: String, recipientUserId: String, vault: SovereignKeyVault
    ) throws -> Data {
        do {
            return try PairwiseChainKeyResolver.deriveChainKey(
                selfId: recipientUserId, peerId: senderId,
                infoLabel: "attach-chain-v1", vault: vault
            )
        } catch PairwiseChainKeyResolver.ResolveError.pskMissing {
            throw ReceiveError.pskMissing
        }
    }

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

import Foundation
import CryptoKit
import QAudionEngine

/// Fase-1B — GROUP attachment receive pipeline.
///
/// Counterpart of ``GroupAttachmentSender``. Given a decoded
/// ``GroupAttachmentEnvelope`` (from the decrypted 0xE4 group plaintext of
/// a `msg_type == 1` frame) plus the sender's id and our own id, this:
///
///   1. Reads OUR capability token from `dl[selfId]` (§4 PATH 1 — the 1:1
///      token is recipient-scoped, so each member downloads with the token
///      minted for them; the server re-derives the HMAC from OUR JWT).
///   2. Downloads the ciphertext via `GET /files/{file_id}` with the three
///      `X-Download-*` headers (``BCryptoDownloadTokenClient``).
///   3. Decrypts with the random `key_b64` fed as the cipher root, binding
///      the same `{id, mime, sha256, byte_length}` AAD the sender bound,
///      and verifies sha256(plaintext).
///   4. Writes the plaintext to a temp file and returns the URL for the
///      group bubble to render (reusing ``ImageBubbleContent`` /
///      ``FileBubbleContent``).
@MainActor
final class GroupAttachmentReceiver {

    enum ReceiveError: Error, LocalizedError {
        case notAuthenticated
        case noTokenForSelf
        case badDescriptor(String)
        case downloadFailed(String)
        case decodeFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:      return "Non autenticato"
            case .noTokenForSelf:        return "Nessun token di download per questo utente"
            case .badDescriptor(let m):  return "Descriptor non valido: \(m)"
            case .downloadFailed(let m): return "Download fallito: \(m)"
            case .decodeFailed(let m):   return "Decodifica fallita: \(m)"
            case .writeFailed(let m):    return "Scrittura fallita: \(m)"
            }
        }
    }

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Download + decrypt + write to temp. Returns the local file URL.
    func downloadAndDecrypt(
        envelope: GroupAttachmentEnvelope,
        senderId: String,
        selfId: String
    ) async throws -> URL {
        guard let token = appState.authService.loadToken(), !token.isEmpty, !selfId.isEmpty else {
            throw ReceiveError.notAuthenticated
        }
        _ = token
        let att = envelope.attachment

        // Only the single-shot (total_chunks == 1) blob shape is handled —
        // that is what this client and the image case emit. A multi-chunk
        // blob from another platform is surfaced rather than mis-decrypted.
        guard att.totalChunks <= 1 else {
            throw ReceiveError.badDescriptor("multi-chunk blob (total_chunks=\(att.totalChunks)) unsupported")
        }
        guard let entry = envelope.dl[selfId] else {
            throw ReceiveError.noTokenForSelf
        }
        guard let attachmentId = Data(base64Encoded: att.id), attachmentId.count == 16 else {
            throw ReceiveError.badDescriptor("attachment.id not 16 bytes")
        }
        guard let keyBytes = Data(base64Encoded: att.keyB64), keyBytes.count == 32 else {
            throw ReceiveError.badDescriptor("key_b64 not 32 bytes")
        }
        guard let expectedSha = Data(base64Encoded: att.sha256B64), expectedSha.count == 32 else {
            throw ReceiveError.badDescriptor("sha256_b64 not 32 bytes")
        }

        // 1. Download ciphertext with the capability token.
        let provider = appState.makeUploadProvider()
        let ciphertext: Data
        do {
            ciphertext = try await provider.downloadTokenClient.downloadCiphertext(
                fileId: att.fileId, claim: entry.claim(fileId: att.fileId))
        } catch {
            throw ReceiveError.downloadFailed(error.localizedDescription)
        }

        // 2. Decrypt with the random content key as the cipher root. The
        //    sender bound its OWN uuid as senderUuid; we reconstruct it from
        //    senderId (same deterministic parse both sides).
        let senderUuid = Self.uuidBytes(from: senderId) ?? Data(repeating: 0, count: 16)
        let plaintext: Data
        do {
            let meta = try AttachmentEncryption.Meta(
                attachmentId: attachmentId,
                senderUuid: senderUuid,
                mime: att.mime,
                byteLength: Int(att.byteLength))
            plaintext = try AttachmentEncryption.decryptAttachment(
                messageChainKey: keyBytes,
                ciphertext: ciphertext,
                meta: meta,
                expectedSha256Plain: expectedSha)
        } catch {
            throw ReceiveError.decodeFailed(String(describing: error))
        }

        // 3. Write to temp for the bubble.
        let dir = FileManager.default.temporaryDirectory
        let ext = GroupAttachmentSender.fileExtension(forMime: att.mime, filename: att.filename)
        let url = dir.appendingPathComponent("grpattach-\(att.id.prefix(16))\(ext)")
        do {
            try plaintext.write(to: url, options: [.atomic])
        } catch {
            throw ReceiveError.writeFailed(error.localizedDescription)
        }
        return url
    }

    private static func uuidBytes(from str: String) -> Data? {
        guard let u = UUID(uuidString: str) else { return nil }
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
}

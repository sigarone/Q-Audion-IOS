import Foundation
import CryptoKit
import Security   // SecRandomCopyBytes / kSecRandomDefault / errSec*
import QAudionEngine

/// Fase-1B — GROUP attachment send pipeline.
///
/// Mirrors the 1:1 ``ChatAttachAnnounceSender`` but for the group
/// transport. The blob is encrypted with a RANDOM per-file key (not a
/// chain-key derivation) and that key travels inside the 0xE4-sealed
/// group descriptor (``GroupAttachmentEnvelope``). Download authorization
/// uses §4 PATH 1 — one capability token per OTHER member (no server
/// change; the 1:1 token is recipient-scoped and cannot be shared).
///
/// **Blob cipher — parity reuse:** we reuse the SAME cross-platform
/// ``AttachmentEncryption`` cipher the 1:1 path uses (single-shot
/// XChaCha20-Poly1305, HKDF-expanded from the root key, AAD binding
/// `{id, mime, sha256, byte_length}`). The random `key_b64` is fed as the
/// root (`messageChainKey`) instead of a per-pair chain key — this is the
/// literal "reuse the 1:1 blob encryption, keyed by the random per-file
/// key" instruction. `total_chunks` is always 1 (single-shot).
@MainActor
final class GroupAttachmentSender {

    enum SendError: Error, LocalizedError {
        case notAuthenticated
        case encryptFailed(String)
        case uploadFailed(String)
        case tokenIssueFailed(String)
        case envelopeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:     return "Non autenticato"
            case .encryptFailed(let m): return "Cifratura fallita: \(m)"
            case .uploadFailed(let m):  return "Upload fallito: \(m)"
            case .tokenIssueFailed(let m): return "Token fallito: \(m)"
            case .envelopeFailed(let m):return "Envelope fallito: \(m)"
            }
        }
    }

    /// Everything the optimistic UI row + the wire frame need.
    struct Prepared {
        /// The 0xE4-plaintext descriptor JSON — hand to
        /// `GroupChatService.encryptForWire` as the plaintext.
        let descriptorJson: String
        let kind: String
        let mime: String
        let filename: String
        let byteLength: Int64
        let caption: String?
        /// Local path of the ORIGINAL plaintext bytes so the sender's own
        /// bubble renders immediately without a download round-trip.
        let localPath: String
    }

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Encrypt + upload the blob, mint a capability token for every other
    /// member, and return the descriptor JSON ready to seal into the group
    /// payload.
    ///
    /// - Parameters:
    ///   - members: the FULL current roster (incl. self); a token is minted
    ///     for every member except `selfId`.
    func prepare(
        data: Data,
        mime: String,
        kind: String,
        filename: String,
        caption: String?,
        width: Int?,
        height: Int?,
        members: [String],
        selfId: String
    ) async throws -> Prepared {
        guard let token = appState.authService.loadToken(), !token.isEmpty, !selfId.isEmpty else {
            throw SendError.notAuthenticated
        }
        _ = token

        // 1. Random attachment id (16B) + random content key (32B).
        let attachmentId = Self.uuidV4Bytes()
        let keyBytes = Self.randomBytes(32)
        let senderUuid = Self.uuidBytes(from: selfId) ?? Data(repeating: 0, count: 16)

        // 2. Encrypt the blob with the shared cross-platform cipher, keyed
        //    by the random content key as the root.
        let meta: AttachmentEncryption.Meta
        let encrypted: AttachmentEncryption.Encrypted
        do {
            meta = try AttachmentEncryption.Meta(
                attachmentId: attachmentId,
                senderUuid: senderUuid,
                mime: mime,
                byteLength: data.count)
            encrypted = try AttachmentEncryption.encryptAttachment(
                messageChainKey: keyBytes, plaintext: data, meta: meta)
        } catch {
            throw SendError.encryptFailed(String(describing: error))
        }

        // 3. Upload ciphertext (self-healing provider — see makeUploadProvider).
        let provider = appState.makeUploadProvider()
        let fileId: String
        do {
            fileId = try await provider.storageApi.uploadFile(
                data: encrypted.ciphertext,
                filename: "grpattach-\(attachmentId.base64EncodedString().prefix(16)).bin")
        } catch {
            throw SendError.uploadFailed(error.localizedDescription)
        }

        // 4. §4 PATH 1 — one capability token per OTHER member. A failure
        //    for one member is logged and skipped (that member simply can't
        //    download); the send does NOT abort for the rest.
        var dl: [String: GroupDownloadEntry] = [:]
        let recipients = members.filter { $0 != selfId && !$0.isEmpty }
        for member in recipients {
            do {
                let issued = try await provider.downloadTokenClient.issueToken(
                    fileId: fileId, recipientUserId: member)
                dl[member] = GroupDownloadEntry(
                    tok: issued.tokenHex, exp: issued.expiresAtMs, max: issued.maxUses)
            } catch {
                print("[GroupAttachmentSender] issue-token for \(member) failed: \(error)")
            }
        }
        guard !dl.isEmpty else {
            // No member can download → treat as a hard failure so the UI can
            // surface it rather than shipping an undownloadable attachment.
            throw SendError.tokenIssueFailed("no download tokens minted")
        }

        // 5. Build descriptor.
        let att = GroupAttachmentMeta(
            id: attachmentId.base64EncodedString(),
            fileId: fileId,
            mime: mime,
            byteLength: Int64(data.count),
            sha256B64: encrypted.sha256Plain.base64EncodedString(),
            keyB64: keyBytes.base64EncodedString(),
            filename: filename,
            chunkSize: 262144,
            totalChunks: 1,
            width: width,
            height: height,
            blurhash: nil,
            durationMs: nil)
        let envelope = GroupAttachmentEnvelope(
            kind: kind,
            caption: (caption?.isEmpty == false) ? caption : nil,
            attachment: att,
            dl: dl)
        let json: String
        do { json = try envelope.toJsonString() }
        catch { throw SendError.envelopeFailed(String(describing: error)) }

        // 6. Stash the plaintext locally so the sender's own bubble shows
        //    the file immediately.
        let localPath = Self.writeLocalCopy(data: data, id: attachmentId, mime: mime, filename: filename)

        return Prepared(
            descriptorJson: json,
            kind: kind,
            mime: mime,
            filename: filename,
            byteLength: Int64(data.count),
            caption: (caption?.isEmpty == false) ? caption : nil,
            localPath: localPath)
    }

    // MARK: - Helpers

    private static func writeLocalCopy(data: Data, id: Data, mime: String, filename: String) -> String {
        let dir = FileManager.default.temporaryDirectory
        let ext = Self.fileExtension(forMime: mime, filename: filename)
        let url = dir.appendingPathComponent("grpattach-\(id.base64EncodedString().prefix(16))\(ext)")
        try? data.write(to: url, options: [.atomic])
        return url.path
    }

    static func fileExtension(forMime mime: String, filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty { return "." + ext }
        switch mime.lowercased() {
        case "image/jpeg": return ".jpg"
        case "image/png":  return ".png"
        case "image/gif":  return ".gif"
        case "image/heic": return ".heic"
        case "application/pdf": return ".pdf"
        default: return ".bin"
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

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

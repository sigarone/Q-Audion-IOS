import Foundation
import CryptoKit
import Security
import QAudionEngine

/// SEC-WIREUNIFY (2026-08-03) — iOS send pipeline for the cross-platform
/// `qa_fa_announce:1` file-attachment scheme (X25519-per-device wrap +
/// XChaCha20-Poly1305 chunk cipher), converging iOS onto Android's
/// wire-format — the scheme the user picked after the cross-platform
/// attachment audit ("procedi con fare questo").
///
/// Replaces the per-content-type senders (`ChatAttachAnnounceSender`,
/// `ChatVoiceNoteSender`'s `qfile` path) for ALL four content types this
/// app sends 1:1 (photo, camera capture, generic file, voice note) — they
/// all reduce to "encrypt this Data blob and announce it" at this layer.
///
/// **Pipeline** (mirrors Android `FileAttachmentSender.kt` +
/// `FileAttachmentSendController.kt`):
///   1. Resolve the peer's published X25519 identity key
///      (`BCryptoKmsClient.fetchUserIdentityBundleV2`) — fails closed with
///      `.peerNoX25519` if the peer hasn't published one yet (no
///      pairwise-PSK fallback needed: unlike the old `qa_ctl:1` path this
///      scheme is self-authenticating per-recipient, no ratchet required).
///   2. Mint a fresh 32-byte content key + 16-byte fileId (UUIDv4).
///   3. Split plaintext into 64 KiB chunks, seal each via
///      `FileAttachmentCipher.sealChunk`, concatenate the `ChunkRecord`
///      byte records into one ciphertext blob (byte-identical to what
///      Android's chunked-tus-PATCH loop produces on the wire, just built
///      in memory here instead of streamed — see the type doc for why).
///   4. Upload the blob via the existing tus-always `storageApi.uploadFile`.
///   5. `FileAttachmentAnnounce.seal` the content key to the peer's device.
///   6. Best-effort mint a recipient download-capability token.
///   7. Encode + send the `qa_fa_announce:1` envelope over `opaque_message`.
@MainActor
final class ChatFileAttachmentSender {

    enum SendError: Error, LocalizedError {
        case notAuthenticated
        case peerNoX25519
        case encryptFailed(String)
        case uploadFailed(String)
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Non autenticato"
            case .peerNoX25519: return "Il destinatario non ha ancora pubblicato una chiave — riprova più tardi."
            case .encryptFailed(let m): return "Cifratura fallita: \(m)"
            case .uploadFailed(let m): return "Upload fallito: \(m)"
            case .sendFailed(let m): return "Invio fallito: \(m)"
            }
        }
    }

    /// Plaintext bytes per content-chunk before sealing — matches
    /// Android's `FileAttachmentWireFormat.DEFAULT_CHUNK_SIZE`.
    static let defaultChunkSize = 65_536

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Encrypt, upload, and announce `data` to `recipientUserId`. Returns
    /// once the announce has been sent — caller owns local UI state
    /// (optimistic bubble, progress) same as the other attachment senders.
    ///
    /// - Parameters:
    ///   - ephemeralSpecSec: cross-device disappearing-message TTL, same
    ///     three-way convention as `AttachAnnounceMeta.ex` (0/nil = none,
    ///     -1 = view-once, N = seconds).
    ///   - exportAllowed: export-permission choice; `false` embeds `xp: 0`.
    func send(
        data: Data,
        mime: String,
        filename: String,
        recipientUserId: String,
        ephemeralSpecSec: Int64? = nil,
        exportAllowed: Bool = true
    ) async throws {
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let selfId = appState.currentUserId, !selfId.isEmpty else {
            throw SendError.notAuthenticated
        }
        _ = token
        guard !data.isEmpty else {
            throw SendError.encryptFailed("empty payload")
        }

        let provider = appState.makeUploadProvider()

        // 1. Resolve the peer's published X25519 identity key.
        guard let bundle = await provider.kmsClient.fetchUserIdentityBundleV2(userId: recipientUserId),
              let peerX25519Pub = bundle.x25519Pub, peerX25519Pub.count == 32,
              let peerDeviceId = Self.uuidBytes(from: recipientUserId) else {
            throw SendError.peerNoX25519
        }

        // 2. Fresh content key + fileId + senderId.
        let contentKey = Self.randomBytes(32)
        let fileId = Self.uuidV4Bytes()
        guard let senderId = Self.uuidBytes(from: selfId) else {
            throw SendError.encryptFailed("self id is not a UUID")
        }

        // 3. Split + seal chunks, concatenate ChunkRecord byte records.
        let plainChunks = Self.splitIntoChunks(data, chunkSize: Self.defaultChunkSize)
        let totalChunks = plainChunks.count
        var blob = Data()
        do {
            for (idx, chunk) in plainChunks.enumerated() {
                let ct = try FileAttachmentCipher.sealChunk(
                    contentKey: contentKey, fileId: fileId, senderId: senderId,
                    chunkIdx: idx, totalChunks: totalChunks, plaintext: chunk)
                blob.append(Self.beUInt32(UInt32(idx)))
                blob.append(Self.beUInt32(UInt32(ct.count)))
                blob.append(ct)
            }
        } catch {
            throw SendError.encryptFailed(String(describing: error))
        }

        // 4. Upload ciphertext blob (always tus, no size threshold).
        let tusFileId: String
        do {
            tusFileId = try await provider.storageApi.uploadFile(
                data: blob, filename: "fa-\(fileId.base64EncodedString().prefix(16)).bin")
        } catch {
            throw SendError.uploadFailed(error.localizedDescription)
        }

        // 5. Seal the content key to the peer's single device (MVP —
        //    matches Android's PeerFileAttachmentRecipientResolver).
        let sealed: FileAttachmentAnnounce.Sealed
        do {
            let recipient = try FileAttachmentAnnounce.RecipientDevice(
                deviceId: peerDeviceId, identityPub: peerX25519Pub)
            sealed = try FileAttachmentAnnounce.seal(
                contentKey: contentKey, fileId: fileId, senderId: senderId, recipientDevices: [recipient])
        } catch {
            throw SendError.encryptFailed(String(describing: error))
        }

        // 6. Best-effort download-capability token — never abort the send
        //    over a token-issuance failure (degrades to owner-direct,
        //    same signal-not-kill contract as Android).
        var downloadTokenHex: String?
        var downloadTokenExpiresMs: Int64?
        var downloadTokenMaxUses: Int?
        do {
            let issued = try await provider.downloadTokenClient.issueToken(
                fileId: tusFileId, recipientUserId: recipientUserId)
            downloadTokenHex = issued.tokenHex
            downloadTokenExpiresMs = issued.expiresAtMs
            downloadTokenMaxUses = Int(issued.maxUses)
        } catch {
            RTLog.warn("voicenote", "file-attachment issue-token failed: \(error)")
        }

        // 7. Encode + send.
        let envelope = FileAttachmentAnnounceWireEnvelope(
            fileId: Self.uuidString(fromRawBytes: fileId),
            senderId: selfId,
            senderEphPubB64: sealed.senderEphPub.base64EncodedString(),
            tusFileId: tusFileId,
            totalChunks: totalChunks,
            chunkSize: Self.defaultChunkSize,
            totalSizeBytes: Int64(data.count),
            mime: mime,
            filename: filename,
            wraps: sealed.wraps.map {
                .init(deviceIdB64: $0.deviceId.base64EncodedString(),
                      wrappedContentKeyB64: $0.wrappedContentKey.base64EncodedString())
            },
            downloadTokenHex: downloadTokenHex,
            downloadTokenExpiresMs: downloadTokenExpiresMs,
            downloadTokenMaxUses: downloadTokenMaxUses,
            ephemeralSpecSec: (ephemeralSpecSec ?? 0) != 0 ? ephemeralSpecSec : nil,
            xp: exportAllowed ? nil : 0
        )
        do {
            let payload = try envelope.toWirePayload()
            try await provider.callingApi.sendOpaqueMessageString(recipientId: recipientUserId, payload: payload)
        } catch {
            throw SendError.sendFailed(String(describing: error))
        }
    }

    // MARK: - Helpers

    private static func splitIntoChunks(_ data: Data, chunkSize: Int) -> [Data] {
        var chunks: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(data.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }

    private static func beUInt32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
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

    private static func uuidString(fromRawBytes raw: Data) -> String {
        guard raw.count == 16 else { return "" }
        let bytes = [UInt8](raw)
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple).uuidString
    }
}

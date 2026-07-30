import Foundation
import CryptoKit
import QAudionEngine

/// W355 — cross-platform voice-note / attachment send via the
/// `qa_ctl:1` `attach_announce` envelope.
///
/// **Pipeline:**
///   1. Mint a fresh 16-byte attachment id (UUIDv4).
///   2. Build the AttachmentEncryption.Meta block.
///   3. AttachmentEncryption.encrypt (XChaCha20-Poly1305 + canonical-CBOR
///      AAD, see W346).
///   4. Upload the ciphertext to `/api/v1/files/upload` via the existing
///      BCryptoStorageApiImpl.
///   5. Build the AttachAnnounceEnvelope JSON
///      (`{qa_ctl:1, t:"attach_announce", att:{...}, ts:<unix>}`).
///   6. Caller passes the JSON through the regular
///      `ChatMessageSendService` path (treated as plaintext of a
///      normal `msg_send`, encrypted under the per-pair PSK / v3
///      ratchet just like any text message).
///
/// **Cross-platform contract:** the resulting wire matches Android's
/// `attach_announce` envelope (`feature/feature-chat/.../attachments/
/// ChatControlEnvelope.kt`) and Desktop's TS counterpart byte-for-byte.
/// An iOS-produced voice note can be downloaded + decrypted on Android
/// or Desktop without conversion.
///
/// **Chain key plumbing (transitional):** AttachmentEncryption derives
/// (key, nonce) from a 32-byte `messageChainKey`. In the full v3
/// architecture this comes from the MessageRatchet's per-message
/// chain — until the engine surfaces that snapshot per envelope, we
/// derive a deterministic chain key from the per-pair PSK so both
/// sides agree without coordination.
@MainActor
final class ChatAttachAnnounceSender {

    enum SendError: Error, LocalizedError {
        case notAuthenticated
        case readFailed(String)
        case encryptFailed(String)
        case uploadFailed(String)
        case envelopeFailed(String)
        /// W-PHONEVERIFY-adjacent FIX H1-PARITY (2026-07-30): no real
        /// pairwise PSK exists yet for this peer — see
        /// `deterministicChainKey`'s kdoc. A key exchange has been
        /// triggered; the caller should surface this as "retry once the
        /// peer accepts", same UX as `ChatMessageSendService`'s identical
        /// `.pskMissing` case.
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

    /// Encrypt + upload + return the `attach_announce` JSON envelope.
    /// Caller passes the result through ChatContainer's normal text
    /// send path so the outer message rides the per-pair PSK / v3
    /// ratchet path and the recipient's parser dispatches on the
    /// `qa_ctl` marker.
    ///
    /// - Parameter timerOverrideSeconds: W447 — per-attachment
    ///   ephemeral-timer override chosen in the pre-send dialog.
    ///   `nil`/`0` = no override, embedded verbatim into `att.ex` so the
    ///   receiver can prefer it over the conversation default (see
    ///   ``AttachmentTimerResolver``).
    /// - Parameter exportBlocked: export-permission choice from the
    ///   pre-send dialog. `false` (default) = export allowed, matches
    ///   the wire default and omits `att.xp` entirely; `true` embeds
    ///   `att.xp: 0` so the receiver marks the attachment export-blocked.
    ///   Client-side/UI honor-system signal only — see
    ///   ``AttachAnnounceMeta/xp`` doc.
    func prepareEnvelopeJson(
        recording: VoiceNoteRecorder.Recording,
        recipientUserId: String,
        timerOverrideSeconds: Int? = nil,
        exportBlocked: Bool = false
    ) async throws -> String {
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let senderId = appState.currentUserId, !senderId.isEmpty else {
            throw SendError.notAuthenticated
        }
        // 1. Read the captured M4A bytes.
        try? await Task.sleep(nanoseconds: 200_000_000)  // flush window
        let bytes: Data
        do { bytes = try Data(contentsOf: recording.fileURL) }
        catch { throw SendError.readFailed(error.localizedDescription) }

        // 2. Build meta block with a fresh 16-byte attachment id (UUIDv4).
        let attachmentId = Self.uuidV4Bytes()
        let senderUuidBytes = Self.uuidBytes(from: senderId) ?? Self.uuidV4Bytes()
        let meta: AttachmentEncryption.Meta
        do {
            meta = try AttachmentEncryption.Meta(
                attachmentId: attachmentId,
                senderUuid: senderUuidBytes,
                mime: recording.mimeType,
                byteLength: bytes.count
            )
        } catch {
            throw SendError.encryptFailed(String(describing: error))
        }

        // 3. Encrypt.
        let chainKey: Data
        do {
            chainKey = try Self.deterministicChainKey(
                senderId: senderId, recipientUserId: recipientUserId, vault: vault)
        } catch SendError.pskMissing {
            // FIX H1-PARITY: mirror ChatMessageSendService — no real pairwise
            // PSK yet, kick off a key exchange and fail closed rather than
            // falling back to a server-guessable key.
            appState.triggerKeyExchange(with: recipientUserId)
            throw SendError.pskMissing
        }
        let encrypted: AttachmentEncryption.Encrypted
        do {
            encrypted = try AttachmentEncryption.encryptAttachment(
                messageChainKey: chainKey, plaintext: bytes, meta: meta)
        } catch {
            throw SendError.encryptFailed(String(describing: error))
        }

        // 4. Upload ciphertext.
        // `token` only gates the "authenticated" early-throw above.
        _ = token
        // UPLOAD-401 FIX (2026-07-03) — refresher-wired provider builder
        // instead of a bare BCryptoBackendProvider, so this voice-note
        // upload self-heals on token expiry instead of 401'ing forever
        // (see AppState.makeUploadProvider).
        let provider = appState.makeUploadProvider()
        let fileId: String
        do {
            fileId = try await provider.storageApi.uploadFile(
                data: encrypted.ciphertext,
                filename: "voicenote-\(attachmentId.base64EncodedString().prefix(16)).bin"
            )
        } catch {
            throw SendError.uploadFailed(error.localizedDescription)
        }

        // 5. Build envelope JSON.
        let attMeta = AttachAnnounceMeta(
            id: attachmentId.base64EncodedString(),
            mime: recording.mimeType,
            byteLength: Int64(bytes.count),
            sha256B64: encrypted.sha256Plain.base64EncodedString(),
            fileId: fileId,
            durationMs: Int64(recording.durationMs),
            ex: timerOverrideSeconds,
            xp: exportBlocked ? 0 : nil
        )
        let envelope = AttachAnnounceEnvelope(
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

    /// Deterministic chain key for the transitional flow: HKDF-SHA256
    /// over the REAL per-pair PSK. Both ends derive the same 32 bytes
    /// without extra signaling. This will be replaced with the v3
    /// ratchet's per-message chain key once the engine surfaces it.
    ///
    /// Delegates to ``PairwiseChainKeyResolver`` (factored out
    /// 2026-07-30 — see that type's doc for why a third copy-paste of
    /// this exact ladder was refused). Throws `.pskMissing` (fail-closed,
    /// same as `ChatMessageSendService`'s FIX H1) rather than falling
    /// back to a server-guessable key when no real PSK is bound yet.
    private static func deterministicChainKey(
        senderId: String, recipientUserId: String, vault: SovereignKeyVault
    ) throws -> Data {
        do {
            return try PairwiseChainKeyResolver.deriveChainKey(
                selfId: senderId, peerId: recipientUserId,
                infoLabel: "attach-chain-v1", vault: vault
            )
        } catch PairwiseChainKeyResolver.ResolveError.pskMissing {
            throw SendError.pskMissing
        }
    }

    private static func uuidV4Bytes() -> Data {
        // W388: `UUID.uuid` is a get-only computed property, so we cannot
        // pass it as `inout` to `withUnsafeBytes(of:&...)`. Copy the tuple
        // into a mutable local first.
        let u = UUID()
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }

    /// Try to parse a UUIDv4 string into raw 16-byte form. Returns nil
    /// if the input is not a valid UUID (e.g. "self" placeholder, custom
    /// userId scheme without hyphens).
    private static func uuidBytes(from str: String) -> Data? {
        guard let u = UUID(uuidString: str) else { return nil }
        var tuple = u.uuid
        return withUnsafeBytes(of: &tuple) { Data($0) }
    }
}

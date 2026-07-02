import Foundation
import CryptoKit
import QAudionEngine

/// W79 — orchestrates the iOS-internal voice-note send pipeline.
///
/// **Scope**: iPhone↔iPhone today. Cross-platform (iOS↔Android, iOS↔Desktop)
/// is deferred until the engine ships the Double Ratchet chain-key snapshot
/// the `attach_announce` envelope requires (XChaCha20-Poly1305 + canonical
/// CBOR AAD). Until then, voice notes ride the legacy `qfile` v3 marker
/// extended with the recipient capability claim — same crypto as
/// ``FileTransfer`` (HKDF-SHA256 + AES-256-GCM, AAD =
/// `"file:v2:{sender}:{recipient}:{ts}"`).
///
/// **Pipeline**:
///   1. Read the recorded M4A bytes from the temp URL.
///   2. ``FileTransfer/upload`` encrypts with the per-pair PSK (or the
///      fallback shared secret) and POSTs ciphertext to
///      `/api/v1/files/upload` → returns `fileId`.
///   3. ``BCryptoDownloadTokenClient/issueToken`` mints a recipient
///      capability bound to `recipientUserId`. Server enforces
///      `claims.UserID == record.OwnerUserID`; if the caller doesn't own
///      the upload the request returns 403 (caught here as
///      `.tokenIssueFailed`).
///   4. Rebuild ``FileTransfer/FileMarker`` with the claim + duration
///      stamped into the new ``FileTransfer/FileMarker/QFile/downloadClaim``
///      and ``durationMs`` fields (W79 schema bump).
///   5. JSON-serialize the marker → caller treats the result as the
///      plaintext of a normal chat message and ships via the existing
///      ``ChatMessageSendService`` send path.
///
/// The receiver (handled in ``AppState/handleIncomingMessage``) parses
/// the `qfile` marker, extracts the claim, calls
/// ``BCryptoDownloadTokenClient/downloadCiphertext`` with the 3
/// `X-Download-*` headers, and ``FileTransfer/download`` decrypts.
@MainActor
final class ChatVoiceNoteSender {

    enum Error: Swift.Error, LocalizedError {
        case readFailed(String)
        case uploadFailed(String)
        case tokenIssueFailed(String)
        case markerSerializeFailed(String)

        var errorDescription: String? {
            switch self {
            case .readFailed(let m):           return "Lettura voice note fallita: \(m)"
            case .uploadFailed(let m):         return "Upload voice note fallito: \(m)"
            case .tokenIssueFailed(let m):     return "Mint token download fallito: \(m)"
            case .markerSerializeFailed(let m): return "Serializzazione marker fallita: \(m)"
            }
        }
    }

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Encrypt + upload + mint token → return the JSON marker text ready
    /// to be encrypted as the plaintext of a normal `msg_send`.
    ///
    /// - Parameters:
    ///   - recording: handed back by ``VoiceNoteRecorder/stop``.
    ///   - recipientUserId: peer UUID — bound into the issued token's HMAC
    ///     so a leaked claim cannot be redeemed by any other account.
    ///   - onProgress: optional local-UI callback, `(bytesUploaded,
    ///     totalBytes)`. Only wired on the legacy qfile path (the
    ///     `attach_announce` cross-platform path, gated behind
    ///     `VoiceNote.attachAnnounce.enabled` and default OFF, uploads via
    ///     a separate single-shot pipeline and doesn't report progress).
    /// - Returns: the JSON-serialized ``FileTransfer/FileMarker`` as a
    ///   string; pass this through ``ChatContainer/composerText`` to ride
    ///   the regular send path (AAD-bound chat ciphertext).
    func prepareMarkerJson(
        for recording: VoiceNoteRecorder.Recording,
        recipientUserId: String,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        // W362: when UserDefaults["VoiceNote.attachAnnounce.enabled"]
        // is true, route through the cross-platform attach_announce
        // pipeline (W355 sender). Default OFF — flipped per-tester
        // until peers have W356 receive logic deployed; once both
        // sides flip on, voice notes work iOS↔Android↔Desktop.
        if UserDefaults.standard.bool(forKey: "VoiceNote.attachAnnounce.enabled") {
            do {
                return try await ChatAttachAnnounceSender(appState: appState)
                    .prepareEnvelopeJson(recording: recording,
                                          recipientUserId: recipientUserId)
            } catch {
                // Fall back to the legacy qfile path on any error so
                // the user can still send during the rollover.
                print("[ChatVoiceNoteSender] attach_announce path failed, falling back to qfile: \(error)")
            }
        }

        // 1. Read the captured M4A bytes.
        // AVAudioRecorder.stop() is synchronous on the API, but the
        // kernel may still be flushing the AAC frames + the m4a moov
        // metadata footer when our Task picks up here. A 200 ms grace
        // window is plenty for typical voice-note sizes (≤200 KB) and
        // protects against the read returning a truncated file or
        // ENOENT on slower devices. Mirrors the buffer Android uses
        // around `MediaRecorder.stop()` in `VoiceNoteRecorder.kt`.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let bytes: Data
        do {
            bytes = try Data(contentsOf: recording.fileURL)
        } catch {
            throw Error.readFailed(error.localizedDescription)
        }
        return try await prepareAttachmentMarkerJson(
            bytes: bytes,
            mime: recording.mimeType,
            filename: "voicenote-\(recording.fileURL.deletingPathExtension().lastPathComponent).m4a",
            durationMs: Int64(recording.durationMs),
            recipientUserId: recipientUserId,
            onProgress: onProgress
        )
    }

    /// W82 — generic attachment send (image, voice note, future media).
    /// All chat-attachment types share the same wire (qfile v3 marker
    /// inside an AES-256-GCM-encrypted msg_send), so one orchestrator
    /// covers all of them. The `mime` is stamped into `marker.qfile.mime`
    /// so the receiver can route to the right bubble; `durationMs` is
    /// optional and only set for voice notes.
    /// - Parameter onProgress: optional local-UI callback,
    ///   `(bytesUploaded, totalBytes)`, invoked as TUS chunks complete
    ///   during the upload step. Purely local UI state — never touches
    ///   `attach_announce`/`ChatControlEnvelope` or any wire schema.
    ///   `nil` by default so existing callers keep compiling unchanged.
    func prepareAttachmentMarkerJson(
        bytes: Data,
        mime: String,
        filename: String,
        durationMs: Int64?,
        recipientUserId: String,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        // 1. Build the FileTransfer dependencies. We rebuild per-call so
        //    the service stays stateless and a token rotation is picked
        //    up on the next send.
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let senderId = appState.currentUserId, !senderId.isEmpty else {
            throw Error.uploadFailed("non autenticato")
        }
        let backendConfig = BackendConfig.pinned(serverUrl: appState.serverUrl, accessToken: token)
        let provider = BCryptoBackendProvider(config: backendConfig)
        // No `provider.initialize()` — `uploadFile` and `issueToken` are
        // REST-only; a fresh provider with the auth token is sufficient.

        // BCryptoStorageApiImpl.uploadFile(data:filename:onProgress:) is
        // not part of the StorageApi protocol (mirrors AvatarUploader's
        // existing cast for the same reason), so we cast to the concrete
        // impl to reach the progress-reporting overload. Falls back to
        // the plain protocol call if the concrete type ever changes —
        // `uploadFileWithProgress` stays nil and FileTransfer.upload
        // silently skips progress reporting.
        let storageImpl = provider.storageApi as? BCryptoStorageApiImpl
        let uploadWithProgress: (
            (_ data: Data, _ filename: String,
             _ onProgress: ((Int64, Int64) -> Void)?) async throws -> String
        )? = storageImpl == nil ? nil : { data, filename, progress in
            try await storageImpl!.uploadFile(data: data, filename: filename, onProgress: progress)
        }

        let storage = FileTransfer.StorageApi(
            uploadFile: { data, filename in
                try await provider.storageApi.uploadFile(data: data, filename: filename)
            },
            downloadFile: { _ in
                throw Error.uploadFailed("sender-side download invoked unexpectedly")
            },
            uploadFileWithProgress: uploadWithProgress
        )

        // 2. Resolve PSK adapter — same ladder as ChatMessageSendService.
        let vault = SovereignKeyVault()
        let vaultAdapter = Self.makeVaultAdapter(
            vault: vault,
            peerUserId: recipientUserId,
            senderId: senderId
        )

        // 3. Encrypt + upload via the existing FileTransfer.
        let fileTransfer = FileTransfer(
            storage: storage,
            vault: vaultAdapter,
            selfUserId: senderId
        )
        let baseMarker: FileTransfer.FileMarker
        do {
            baseMarker = try await fileTransfer.upload(
                recipientId: recipientUserId,
                bytes: bytes,
                filename: filename,
                mime: mime,
                onProgress: onProgress
            )
        } catch {
            throw Error.uploadFailed(error.localizedDescription)
        }

        // 4. Mint the recipient capability.
        let issued: IssuedDownloadToken
        do {
            issued = try await provider.downloadTokenClient.issueToken(
                fileId: baseMarker.qfile.fileId,
                recipientUserId: recipientUserId
            )
        } catch {
            throw Error.tokenIssueFailed(error.localizedDescription)
        }

        // 5. Repack the marker with the claim + duration (optional).
        let q = baseMarker.qfile
        let enriched = FileTransfer.FileMarker(qfile: .init(
            fileId: q.fileId,
            name: q.name,
            size: q.size,
            mime: q.mime,
            salt: q.salt,
            nonce: q.nonce,
            tag: q.tag,
            keyId: q.keyId,
            ts: q.ts,
            downloadClaim: issued.claim,
            durationMs: durationMs
        ))

        // 6. Serialize.
        do {
            return try FileTransfer.serializeMarker(enriched)
        } catch {
            throw Error.markerSerializeFailed(error.localizedDescription)
        }
    }

    // MARK: - PSK adapter (mirrors ChatMessageSendService resolution)

    /// Internal-visible so ``ChatVoiceNoteReceiver`` can reuse the same
    /// ladder. Intentionally not `public` — outside the app target there
    /// are no consumers, and keeping the surface tight prevents
    /// accidentally exposing the PSK fallback to engine code.
    static func makeVaultAdapter(
        vault: SovereignKeyVault,
        peerUserId: String,
        senderId: String
    ) -> FileTransfer.VaultAdapter {
        return FileTransfer.VaultAdapter(
            forContact: { contactId in
                if let psk = Self.resolvePsk(vault: vault, peerUserId: contactId, senderId: senderId) {
                    return FileTransfer.VaultEntry(keyId: contactId, material: psk)
                }
                return nil
            },
            primary: {
                if let psk = Self.resolvePsk(vault: vault, peerUserId: peerUserId, senderId: senderId) {
                    return FileTransfer.VaultEntry(keyId: peerUserId, material: psk)
                }
                return nil
            },
            allByPriority: {
                // In the absence of a multi-PSK list (only the per-pair
                // PSK is bound on iOS today) return the resolved primary
                // wrapped as a single-element list. Receiver-side won't
                // use this path; sender doesn't need it either.
                if let psk = Self.resolvePsk(vault: vault, peerUserId: peerUserId, senderId: senderId) {
                    return [FileTransfer.VaultEntry(keyId: peerUserId, material: psk)]
                }
                return []
            }
        )
    }

    /// Same lookup ladder as ``ChatMessageSendService``:
    /// 1. `auto:<peerIdPrefix8>:<peerId>` (ContactKeyExchange-derived PSK).
    /// 2. Bare `peerId` (legacy / manually-bound).
    /// 3. Deterministic SHA256(sortedPair) fallback (insecure, but lets
    ///    the wire flow until ContactKeyExchange completes).
    private static func resolvePsk(
        vault: SovereignKeyVault,
        peerUserId: String,
        senderId: String
    ) -> Data? {
        let prefix = peerUserId.count > 8 ? String(peerUserId.prefix(8)) : peerUserId
        let autoName = "auto:\(prefix):\(peerUserId)"
        if let psk = try? vault.loadPsk(name: autoName), !psk.isEmpty { return psk }
        if let psk = try? vault.loadPsk(name: peerUserId), !psk.isEmpty { return psk }
        // Fallback — symmetric in (peer, self).
        let pair = [peerUserId, senderId].sorted().joined(separator: ":")
        let digest = SHA256.hash(data: Data("qaudion-fallback-psk:\(pair)".utf8))
        return Data(digest)
    }
}

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
    /// - Returns: the JSON-serialized ``FileTransfer/FileMarker`` as a
    ///   string; pass this through ``ChatContainer/composerText`` to ride
    ///   the regular send path (AAD-bound chat ciphertext).
    func prepareMarkerJson(
        for recording: VoiceNoteRecorder.Recording,
        recipientUserId: String
    ) async throws -> String {

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

        // 2. Build the FileTransfer dependencies. We rebuild per-call so
        //    the service stays stateless and a token rotation is picked
        //    up on the next send.
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let senderId = appState.currentUserId, !senderId.isEmpty else {
            throw Error.uploadFailed("non autenticato")
        }
        let backendConfig = BackendConfig(serverUrl: appState.serverUrl, accessToken: token)
        let provider = BCryptoBackendProvider(config: backendConfig)
        // No `provider.initialize()` — `uploadFile` and `issueToken` are
        // REST-only; a fresh provider with the auth token is sufficient.
        // Avoiding initialize() also skips opening a duplicate WS just
        // for this one upload (the persistent WS lives on AppState).

        let storage = FileTransfer.StorageApi(
            uploadFile: { data, filename in
                try await provider.storageApi.uploadFile(data: data, filename: filename)
            },
            downloadFile: { _ in
                // Sender-side path never downloads — receiver builds its
                // own StorageApi with the claim wired through the
                // download-token client.
                throw Error.uploadFailed("sender-side download invoked unexpectedly")
            }
        )

        // 3. Resolve PSK adapter — same pairwise/auto naming as
        //    ChatMessageSendService.
        let vault = SovereignKeyVault()
        let vaultAdapter = Self.makeVaultAdapter(
            vault: vault,
            peerUserId: recipientUserId,
            senderId: senderId
        )

        // 4. Encrypt + upload via the existing FileTransfer.
        let fileTransfer = FileTransfer(
            storage: storage,
            vault: vaultAdapter,
            selfUserId: senderId
        )
        let filename = "voicenote-\(recording.fileURL.deletingPathExtension().lastPathComponent).m4a"
        let baseMarker: FileTransfer.FileMarker
        do {
            baseMarker = try await fileTransfer.upload(
                recipientId: recipientUserId,
                bytes: bytes,
                filename: filename,
                mime: recording.mimeType
            )
        } catch {
            throw Error.uploadFailed(error.localizedDescription)
        }

        // 5. Mint the recipient capability so the peer (different user)
        //    can fetch the ciphertext.
        let issued: IssuedDownloadToken
        do {
            issued = try await provider.downloadTokenClient.issueToken(
                fileId: baseMarker.qfile.fileId,
                recipientUserId: recipientUserId
            )
        } catch {
            throw Error.tokenIssueFailed(error.localizedDescription)
        }

        // 6. Repack the marker with the claim + duration.
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
            durationMs: Int64(recording.durationMs)
        ))

        // 7. Serialize → plaintext that the regular send pipeline will
        //    encrypt as a normal chat msg_send.
        do {
            return try FileTransfer.serializeMarker(enriched)
        } catch {
            throw Error.markerSerializeFailed(error.localizedDescription)
        }
    }

    // MARK: - PSK adapter (mirrors ChatMessageSendService resolution)

    private static func makeVaultAdapter(
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

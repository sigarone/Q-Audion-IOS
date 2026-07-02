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
    ///   - timerOverrideSeconds: W447 — per-attachment ephemeral-timer
    ///     override chosen in the pre-send dialog. `nil`/`0` = no
    ///     override (conversation default applies at receive time via
    ///     ``AttachmentTimerResolver``); embedded as `qfile.ex` /
    ///     `attach_announce.att.ex` so the receiver honors it too.
    ///   - onProgress: optional local-UI callback, `(bytesUploaded,
    ///     totalBytes)`. Only wired on the legacy qfile path (the
    ///     `attach_announce` cross-platform path, gated behind
    ///     `VoiceNote.attachAnnounce.enabled` and default OFF, uploads via
    ///     a separate single-shot pipeline and doesn't report progress).
    ///   - resumeClientMsgId: W-TUSRESUME — forwarded to
    ///     ``prepareAttachmentMarkerJson(bytes:mime:filename:durationMs:recipientUserId:timerOverrideSeconds:onProgress:resumeClientMsgId:)``
    ///     so a >1 MB voice note (rare, but possible on longer
    ///     recordings) gets a resume breadcrumb. Only wired on the
    ///     legacy qfile path, same as `onProgress` — the
    ///     `attach_announce` path is untouched by this change.
    /// - Returns: the JSON-serialized ``FileTransfer/FileMarker`` as a
    ///   string; pass this through ``ChatContainer/composerText`` to ride
    ///   the regular send path (AAD-bound chat ciphertext).
    func prepareMarkerJson(
        for recording: VoiceNoteRecorder.Recording,
        recipientUserId: String,
        timerOverrideSeconds: Int? = nil,
        onProgress: ((Int64, Int64) -> Void)? = nil,
        resumeClientMsgId: String? = nil
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
                                          recipientUserId: recipientUserId,
                                          timerOverrideSeconds: timerOverrideSeconds)
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
            timerOverrideSeconds: timerOverrideSeconds,
            onProgress: onProgress,
            resumeClientMsgId: resumeClientMsgId
        )
    }

    /// W82 — generic attachment send (image, voice note, future media).
    /// All chat-attachment types share the same wire (qfile v3 marker
    /// inside an AES-256-GCM-encrypted msg_send), so one orchestrator
    /// covers all of them. The `mime` is stamped into `marker.qfile.mime`
    /// so the receiver can route to the right bubble; `durationMs` is
    /// optional and only set for voice notes.
    /// - Parameter timerOverrideSeconds: W447 — per-attachment
    ///   ephemeral-timer override chosen in the pre-send dialog.
    ///   `nil`/`0` = no override, embedded verbatim into `qfile.ex` so
    ///   the receiver can prefer it over the conversation default (see
    ///   ``AttachmentTimerResolver``). `nil` by default so existing
    ///   callers keep compiling unchanged and the wire shape stays
    ///   byte-identical to today when no override is chosen.
    /// - Parameter onProgress: optional local-UI callback,
    ///   `(bytesUploaded, totalBytes)`, invoked as TUS chunks complete
    ///   during the upload step. Purely local UI state — never touches
    ///   `attach_announce`/`ChatControlEnvelope` or any wire schema.
    ///   `nil` by default so existing callers keep compiling unchanged.
    /// - Parameter resumeClientMsgId: W-TUSRESUME — when supplied
    ///   (together with a >1 MB payload that takes the TUS chunked
    ///   path), `TusUploadClient` persists a cross-launch resume
    ///   breadcrumb keyed by this id right after the upload's `create()`
    ///   call succeeds. `nil` by default so existing callers (which have
    ///   no notion of a chat message id at this layer, e.g. avatar
    ///   upload reuse) keep compiling unchanged and write no breadcrumb.
    func prepareAttachmentMarkerJson(
        bytes: Data,
        mime: String,
        filename: String,
        durationMs: Int64?,
        recipientUserId: String,
        timerOverrideSeconds: Int? = nil,
        onProgress: ((Int64, Int64) -> Void)? = nil,
        resumeClientMsgId: String? = nil
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

        // BCryptoStorageApiImpl.uploadFile(data:filename:onProgress:resumeContext:)
        // is not part of the StorageApi protocol (mirrors AvatarUploader's
        // existing cast for the same reason), so we cast to the concrete
        // impl to reach the progress-reporting + resume-breadcrumb
        // overload. Falls back to the plain protocol call if the concrete
        // type ever changes — `uploadFileWithProgress` stays nil and
        // FileTransfer.upload silently skips progress reporting AND the
        // resume breadcrumb (degrades to today's always-fresh-upload
        // behavior, never crashes).
        let storageImpl = provider.storageApi as? BCryptoStorageApiImpl
        let uploadWithProgress: (
            (_ data: Data, _ filename: String,
             _ onProgress: ((Int64, Int64) -> Void)?,
             _ resumeContext: (clientMsgId: String, sourceBytes: Data, onFileIdMinted: (String) -> Void)?) async throws -> String
        )? = storageImpl == nil ? nil : { data, filename, progress, resumeCtx in
            try await storageImpl!.uploadFile(
                data: data, filename: filename, onProgress: progress, resumeContext: resumeCtx
            )
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
                onProgress: onProgress,
                resumeContext: resumeClientMsgId.map { (clientMsgId: $0, sourceBytes: bytes) },
                onResumeStateReady: { mintedFileId, saltHex, nonceHex, ts, keyId, pskFingerprintHex in
                    // W-TUSRESUME: fires at most once, right after the
                    // server confirms `mintedFileId` (before the chunk
                    // loop starts) — see `FileTransfer.upload`'s
                    // `onResumeStateReady` doc for why only THIS layer
                    // can supply salt/nonce/ts/keyId/pskFingerprintHex.
                    // `resumeClientMsgId` is guaranteed non-nil here (this
                    // closure is only ever invoked when `resumeContext`
                    // was non-nil, which only happens when
                    // `resumeClientMsgId` was supplied), but the `guard`
                    // keeps this closure provably safe on its own rather
                    // than relying on that invariant holding across
                    // future edits.
                    guard let clientMsgId = resumeClientMsgId else { return }
                    let fp = TusResumeStateStore.fingerprint(of: bytes)
                    let state = TusResumeState(
                        fileId: mintedFileId,
                        clientMsgId: clientMsgId,
                        totalBytes: Int64(bytes.count),
                        sourceSizeAtStart: fp.size,
                        sourceSha256AtStart: fp.sha256Hex,
                        saltHex: saltHex,
                        nonceHex: nonceHex,
                        ts: ts,
                        recipientUserId: recipientUserId,
                        filename: filename,
                        mime: mime,
                        pskFingerprintHex: pskFingerprintHex,
                        durationMs: durationMs,
                        timerOverrideSeconds: timerOverrideSeconds
                    )
                    TusResumeStateStore.save(state)
                }
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

        // 5. Repack the marker with the claim + duration (optional) +
        //    W447 per-attachment timer override (optional).
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
            durationMs: durationMs,
            ex: timerOverrideSeconds
        ))

        // 6. Serialize.
        do {
            return try FileTransfer.serializeMarker(enriched)
        } catch {
            throw Error.markerSerializeFailed(error.localizedDescription)
        }
    }

    /// W-TUSRESUME — tier 1 of the 3-tier retry: continue a
    /// previously-attempted-but-incomplete upload for `state.fileId`
    /// instead of re-encrypting + re-uploading from byte zero. Caller
    /// (``ChatContainer/retryFailedMessage()``) is responsible for the
    /// corruption check (`TusResumeStateStore.checkCorruption`) BEFORE
    /// calling this — `bytes` is trusted here to be the unchanged source
    /// blob the original attempt fingerprinted.
    ///
    /// Mirrors ``prepareAttachmentMarkerJson`` steps 1 (build deps) and
    /// 4–6 (mint token / repack marker / serialize) exactly; only step 3
    /// differs — `FileTransfer.resumeUpload` (HEAD + PATCH-continue with
    /// the PINNED salt/nonce/ts from `state`) instead of
    /// `FileTransfer.upload` (fresh random salt/nonce/ts).
    ///
    /// - Important: unlike ``prepareAttachmentMarkerJson``, this method
    ///   does NOT wrap the underlying `TusUploadClient.TusError` in
    ///   `Error.uploadFailed` — it rethrows it as-is, specifically so
    ///   `ChatContainer.retryFailedMessage()` can `catch let e as
    ///   TusUploadClient.TusError, case .uploadNotFound` without string
    ///   matching. Any other failure (network, crypto, token issuance)
    ///   surfaces as this type's own `Error` cases, same as
    ///   ``prepareAttachmentMarkerJson``.
    func resumeAttachmentMarkerJson(
        state: TusResumeState,
        bytes: Data,
        onProgress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let senderId = appState.currentUserId, !senderId.isEmpty else {
            throw Error.uploadFailed("non autenticato")
        }
        let backendConfig = BackendConfig.pinned(serverUrl: appState.serverUrl, accessToken: token)
        let provider = BCryptoBackendProvider(config: backendConfig)

        guard let storageImpl = provider.storageApi as? BCryptoStorageApiImpl else {
            // No concrete impl to reach the TUS resume primitives —
            // signal_not_kill: never crash, let the caller fall through
            // to tier 3 (today's fresh-upload behavior).
            throw Error.uploadFailed("resume non disponibile per questo backend")
        }

        let storage = FileTransfer.StorageApi(
            uploadFile: { data, filename in
                try await provider.storageApi.uploadFile(data: data, filename: filename)
            },
            downloadFile: { _ in
                throw Error.uploadFailed("sender-side download invoked unexpectedly")
            },
            resumeFile: { fileId, ciphertext, progress in
                let tusClient = storageImpl.makeTusClient()
                let headResult = try await tusClient.head(fileId: fileId)
                // Guard against a corrupt/inconsistent HEAD: the server's
                // reported total must match what we're about to send, and
                // the confirmed offset can't exceed it. Neither should
                // happen (the server is authoritative), but treating a
                // nonsensical response as "not resumable" (tier-3
                // fallback) is safer than PATCHing a bogus byte range.
                guard headResult.totalLength == Int64(ciphertext.count),
                      headResult.offset >= 0,
                      headResult.offset <= Int64(ciphertext.count) else {
                    throw TusUploadClient.TusError.headFailed(0)
                }
                _ = try await tusClient.resume(
                    fileId: fileId,
                    data: ciphertext,
                    fromOffset: headResult.offset,
                    onProgress: progress
                )
            }
        )

        let vault = SovereignKeyVault()

        // W-TUSRESUME (security-review follow-up, 2026-07-02) — re-check
        // the PSK fingerprint BEFORE attempting the resume. The plaintext
        // corruption check (already run by the caller,
        // `ChatContainer.resumeAttachmentIfPossible`) can't detect a PSK
        // rotated/re-bound since the original attempt; if it silently
        // mismatches, `resumeUpload`'s re-seal derives a DIFFERENT file
        // key, corrupting the byte-range continuation the server already
        // has (see `TusResumeState.pskFingerprintHex`'s doc). Treat a
        // mismatch exactly like any other "can't safely resume" signal —
        // throw so the caller clears the stale state and falls through
        // to tier 3, never PATCH a continuation with a key that doesn't
        // match what the server's partial upload was sealed with.
        guard let currentPsk = Self.resolvePsk(vault: vault, peerUserId: state.recipientUserId, senderId: senderId) else {
            throw Error.uploadFailed("PSK non risolvibile per il resume")
        }
        guard TusResumeStateStore.fingerprint(ofPsk: currentPsk) == state.pskFingerprintHex else {
            throw Error.uploadFailed("PSK cambiata dal tentativo originale — resume non sicuro")
        }

        let vaultAdapter = Self.makeVaultAdapter(
            vault: vault,
            peerUserId: state.recipientUserId,
            senderId: senderId
        )
        let fileTransfer = FileTransfer(
            storage: storage,
            vault: vaultAdapter,
            selfUserId: senderId
        )

        let baseMarker: FileTransfer.FileMarker
        do {
            baseMarker = try await fileTransfer.resumeUpload(
                recipientId: state.recipientUserId,
                bytes: bytes,
                filename: state.filename,
                mime: state.mime,
                fileId: state.fileId,
                saltHex: state.saltHex,
                nonceHex: state.nonceHex,
                ts: state.ts,
                // `keyId` isn't persisted on `TusResumeState` — it doesn't
                // need to be. `makeVaultAdapter` (below) always sets
                // `VaultEntry.keyId` to the looked-up contact id, never
                // anything random/session-specific (see
                // `forContact`/`primary` closures), so `recipientUserId`
                // IS the deterministic keyId for this app's PSK
                // resolution scheme — identical to what the original,
                // interrupted `upload()` call would have stamped via
                // `psk.keyId`.
                keyId: state.recipientUserId,
                onProgress: onProgress
            )
        } catch let tusError as TusUploadClient.TusError {
            // Rethrow verbatim — see doc comment above.
            throw tusError
        } catch {
            throw Error.uploadFailed(error.localizedDescription)
        }

        let issued: IssuedDownloadToken
        do {
            issued = try await provider.downloadTokenClient.issueToken(
                fileId: baseMarker.qfile.fileId,
                recipientUserId: state.recipientUserId
            )
        } catch {
            throw Error.tokenIssueFailed(error.localizedDescription)
        }

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
            durationMs: state.durationMs,
            ex: state.timerOverrideSeconds
        ))

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

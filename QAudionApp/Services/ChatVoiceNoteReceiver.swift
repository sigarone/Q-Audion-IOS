import Foundation
import CryptoKit
import QAudionEngine

/// W80 — RECEIVE pipeline for iPhone↔iPhone voice notes (qfile v3 marker).
///
/// Companion to ``ChatVoiceNoteSender`` (W79). Triggered from
/// ``AppState/handleIncomingMessage`` whenever the decrypted plaintext
/// of a `msg_receive` parses as a ``FileTransfer/FileMarker``.
///
/// **Pipeline**:
///   1. The marker carries the `download_claim` minted by the sender.
///      Build a ``FileTransfer/StorageApi`` whose `downloadFile` closure
///      calls ``BCryptoDownloadTokenClient/downloadCiphertext`` with the
///      3 `X-Download-*` headers (server HMAC-binds the recipient's JWT
///      UUID so a leaked claim can't be redeemed by anyone else).
///   2. ``FileTransfer/download`` runs HKDF + AES-256-GCM-decrypt with
///      the same per-pair PSK ladder used on send (auto: → bare peerId →
///      deterministic fallback).
///   3. Plaintext bytes are written to `Library/Caches/voicenotes/<fileId>.m4a`
///      so the chat bubble can hand the URL to AVAudioPlayer.
///   4. ``ConversationStore/setMediaInfo`` stamps the local row with the
///      cache path + duration so the UI flips from "download in arrivo"
///      to a playable bubble.
///
/// Errors are surfaced as a NotificationCenter post (no inline UI to
/// show them) so the snackbar pipeline can pick them up later if
/// desired. For now we just log + leave the placeholder text.
@MainActor
final class ChatVoiceNoteReceiver {

    enum Error: Swift.Error, LocalizedError {
        case missingClaim
        case downloadFailed(String)
        case decryptFailed(String)
        case writeFailed(String)
        /// FIX H1-PARITY (2026-07-30): no real pairwise PSK bound yet for
        /// this sender on the attach_announce path — see
        /// `ChatAttachAnnounceReceiver.ReceiveError.pskMissing`.
        case pskMissing

        var errorDescription: String? {
            switch self {
            case .missingClaim:           return String(localized: "attachment.voice_note.missing_claim", defaultValue: "Marker senza download_claim — peer obsoleto?", comment: "Error text of a received voice note: the message carries no download claim, the other app is probably outdated.")
            case .downloadFailed(let m):  return String(localized: "attachment.voice_note.download_failed", defaultValue: "Download voice note fallito: \(m)", comment: "Error text of a failed voice note transfer; %@ is the technical reason.")
            case .decryptFailed(let m):   return String(localized: "attachment.voice_note.decrypt_failed", defaultValue: "Decrypt voice note fallito: \(m)", comment: "Error text of a failed voice note transfer; %@ is the technical reason.")
            case .writeFailed(let m):     return String(localized: "attachment.voice_note.cache_write_failed", defaultValue: "Scrittura cache fallita: \(m)", comment: "Error text of a failed voice note transfer; %@ is the technical reason.")
            case .pskMissing:             return String(localized: "attachment.error.key_exchange_pending", defaultValue: "Scambio chiavi in corso — riprova tra poco.", comment: "Error text of an attachment, voice note or avatar transfer: the key exchange with the contact is not finished yet.")
            }
        }
    }

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Download + decrypt + cache, returning the local file URL on
    /// success. Caller (AppState) updates the conversation row with
    /// the path + duration via ``ConversationStore/setMediaInfo``.
    func fetch(marker: FileTransfer.FileMarker, senderId: String) async throws -> URL {
        guard let claim = marker.qfile.downloadClaim else {
            throw Error.missingClaim
        }
        let hasToken = appState.authService.loadToken()?.isEmpty == false
        guard hasToken, let selfUserId = appState.currentUserId, !selfUserId.isEmpty else {
            throw Error.downloadFailed(String(localized: "attachment.detail.not_authenticated", defaultValue: "non autenticato", comment: "Reason inside an attachment error (lower case, it follows a colon): the user is not signed in."))
        }

        // UPLOAD-401 FIX (2026-07-03) / 2026-08-07 parity — use the
        // refresher-wired provider builder instead of a bare
        // BCryptoBackendProvider(config: .pinned(serverUrl:accessToken:)).
        // The bare form carries no refresh token and never wires the
        // Ed25519 device-renew fallback, so once the access token expired
        // mid-session every voice-note download (and every retry) would
        // 401 permanently with no self-heal. ChatAttachAnnounceReceiver
        // (the cross-platform sibling of this file) already got this fix
        // in 2026-07-03; this legacy iPhone-only qfile-v3 path did not.
        // See AppState.makeUploadProvider's doc for the full incident.
        let provider = appState.makeUploadProvider()

        // Capture the claim in the closure so FileTransfer.download's
        // generic downloadFile(fileId:) call ends up redeeming the
        // recipient capability instead of the owner-direct path.
        let storage = FileTransfer.StorageApi(
            uploadFile: { _, _ in
                throw Error.downloadFailed("receiver-side upload invoked unexpectedly")
            },
            downloadFile: { fileId in
                do {
                    return try await provider.downloadTokenClient.downloadCiphertext(
                        fileId: fileId, claim: claim
                    )
                } catch {
                    throw Error.downloadFailed(error.localizedDescription)
                }
            }
        )

        // Same vault adapter as the sender — receiver decrypts with the
        // SAME pairwise PSK that the sender's HKDF derived against.
        let vault = SovereignKeyVault()
        let vaultAdapter = ChatVoiceNoteSender.makeVaultAdapter(
            vault: vault, peerUserId: senderId, senderId: selfUserId
        )
        let fileTransfer = FileTransfer(
            storage: storage, vault: vaultAdapter, selfUserId: selfUserId
        )

        let plaintextBytes: Data
        do {
            plaintextBytes = try await fileTransfer.download(
                marker: marker, senderId: senderId
            )
        } catch {
            // FileTransfer.download throws .noPskDecrypted when none of
            // the vault PSKs match the sender's HKDF-derived key —
            // typically means the pairwise PSK is desynced.
            throw Error.decryptFailed(error.localizedDescription)
        }

        // Persist to the per-app caches folder so the file survives app
        // suspension and AVAudioPlayer can mmap it. Caches/ may be
        // reclaimed by the OS under disk pressure, which is acceptable
        // for voice notes (the user can replay the in-chat bubble — we
        // re-fetch on cache miss in a future patch).
        let cacheDir: URL
        do {
            let base = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            cacheDir = base.appendingPathComponent("voicenotes", isDirectory: true)
            if !FileManager.default.fileExists(atPath: cacheDir.path) {
                try FileManager.default.createDirectory(
                    at: cacheDir, withIntermediateDirectories: true, attributes: FileProtection.lockedAccessAttributes
                )
            }
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }

        // Filename includes the fileId so re-deliveries land idempotently.
        // Extension chosen by mime so the file plays/loads correctly.
        let safe = marker.qfile.fileId.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : Character("_") }
        let ext: String
        let mime = marker.qfile.mime.lowercased()
        if mime.hasPrefix("image/jpeg") || mime.hasPrefix("image/jpg") {
            ext = "jpg"
        } else if mime.hasPrefix("image/png") {
            ext = "png"
        } else if mime.hasPrefix("image/heic") {
            ext = "heic"
        } else if mime.hasPrefix("audio/") {
            ext = "m4a"
        } else {
            ext = "bin"
        }
        let outURL = cacheDir.appendingPathComponent(String(safe) + "." + ext)
        do {
            try plaintextBytes.write(to: outURL, options: FileProtection.atomicWriteOptions)
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
        return outURL
    }

    /// Render the friendly bubble text once the attachment has landed.
    /// Voice note: "🎤 Nota vocale (4.2s)"; image: "📷 Foto"; other: "📎 Allegato".
    static func renderReceivedText(marker: FileTransfer.FileMarker) -> String {
        let mime = marker.qfile.mime.lowercased()
        if mime.hasPrefix("audio/") {
            if let dur = marker.qfile.durationMs, dur > 0 {
                let secs = Double(dur) / 1000.0
                let secsText: String = String(format: "%.1f", secs)
                return String(localized: "attachment.voice_note.received_with_duration", defaultValue: "🎤 Nota vocale (\(secsText)s)", comment: "One-line label of a received voice note with its length; %@ is the number of seconds, such as 4.2.")
            }
            return String(localized: "file_v2.kind.voice", defaultValue: "🎤 Nota vocale", comment: "One-line label of a voice note in the conversation list and in notifications.")
        }
        if mime.hasPrefix("image/") {
            return String(localized: "file_v2.kind.image", defaultValue: "📷 Foto", comment: "One-line label of an image message in the conversation list and in notifications.")
        }
        if mime.hasPrefix("video/") {
            return String(localized: "file_v2.kind.video", defaultValue: "🎬 Video", comment: "One-line label of a video message in the conversation list and in notifications.")
        }
        return String(localized: "reply.kind.file", defaultValue: "📎 Allegato", comment: "Quote block of a reply to a document that has no name.")
    }

    // MARK: - W363: attach_announce path (cross-platform)

    /// Cross-platform companion to [fetch] for the qa_ctl:1
    /// attach_announce envelope shape. Delegates the heavy lifting
    /// to [ChatAttachAnnounceReceiver] (W356) and returns a URL the
    /// chat bubble can play. The temp-file location differs from the
    /// legacy qfile path (caches/voicenotes vs. tmp), but the bubble
    /// only needs the URL itself.
    func fetchAttachAnnounce(envelope: AttachAnnounceEnvelope, senderId: String) async throws -> URL {
        let receiver = ChatAttachAnnounceReceiver(appState: appState)
        do {
            return try await receiver.downloadAndDecrypt(envelope: envelope, senderId: senderId)
        } catch let err as ChatAttachAnnounceReceiver.ReceiveError {
            // Map the cross-platform receiver's error categories onto our
            // own so the caller's existing error-handling switch keeps
            // working.
            switch err {
            case .notAuthenticated:
                throw Error.downloadFailed(String(localized: "attachment.detail.not_authenticated", defaultValue: "non autenticato", comment: "Reason inside an attachment error (lower case, it follows a colon): the user is not signed in."))
            case .downloadFailed(let m):
                throw Error.downloadFailed(m)
            case .decodeFailed(let m):
                throw Error.decryptFailed(m)
            case .invalidId:
                throw Error.decryptFailed(String(localized: "attachment.detail.invalid_id", defaultValue: "attachment id non valido", comment: "Reason inside an attachment error (lower case, it follows a colon): the attachment identifier is not valid."))
            case .writeFailed(let m):
                throw Error.writeFailed(m)
            case .pskMissing:
                // Key exchange already triggered inside
                // ChatAttachAnnounceReceiver.downloadAndDecrypt.
                throw Error.pskMissing
            }
        } catch {
            throw Error.decryptFailed(String(describing: error))
        }
    }
}


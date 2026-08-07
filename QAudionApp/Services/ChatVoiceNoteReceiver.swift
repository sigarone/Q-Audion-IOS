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
            case .missingClaim:           return "Marker senza download_claim — peer obsoleto?"
            case .downloadFailed(let m):  return "Download voice note fallito: \(m)"
            case .decryptFailed(let m):   return "Decrypt voice note fallito: \(m)"
            case .writeFailed(let m):     return "Scrittura cache fallita: \(m)"
            case .pskMissing:             return "Scambio chiavi in corso — riprova tra poco."
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
            throw Error.downloadFailed("non autenticato")
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
                    at: cacheDir, withIntermediateDirectories: true
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
            try plaintextBytes.write(to: outURL, options: [.atomic])
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
                return String(format: "🎤 Nota vocale (%.1fs)", secs)
            }
            return "🎤 Nota vocale"
        }
        if mime.hasPrefix("image/") {
            return "📷 Foto"
        }
        if mime.hasPrefix("video/") {
            return "🎬 Video"
        }
        return "📎 Allegato"
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
                throw Error.downloadFailed("non autenticato")
            case .downloadFailed(let m):
                throw Error.downloadFailed(m)
            case .decodeFailed(let m):
                throw Error.decryptFailed(m)
            case .invalidId:
                throw Error.decryptFailed("attachment id non valido")
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


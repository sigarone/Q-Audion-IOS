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

        var errorDescription: String? {
            switch self {
            case .missingClaim:           return "Marker senza download_claim — peer obsoleto?"
            case .downloadFailed(let m):  return "Download voice note fallito: \(m)"
            case .decryptFailed(let m):   return "Decrypt voice note fallito: \(m)"
            case .writeFailed(let m):     return "Scrittura cache fallita: \(m)"
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
        guard let token = appState.authService.loadToken(), !token.isEmpty,
              let selfUserId = appState.currentUserId, !selfUserId.isEmpty else {
            throw Error.downloadFailed("non autenticato")
        }

        // Build a fresh provider per fetch — REST-only, no WS overhead.
        let provider = BCryptoBackendProvider(
            config: BackendConfig(serverUrl: appState.serverUrl, accessToken: token)
        )

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
        // Sanitize to keep only filesystem-safe chars (server-issued ids
        // are typically UUID-shaped but we don't trust them blindly).
        let safe = marker.qfile.fileId.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : Character("_") }
        let outURL = cacheDir.appendingPathComponent(String(safe) + ".m4a")
        do {
            try plaintextBytes.write(to: outURL, options: [.atomic])
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
        return outURL
    }

    /// Render the friendly bubble text once the voice note has landed.
    /// Mirrors the sender side ("🎤 Nota vocale (4.2s)") with the
    /// duration carried in the marker.
    static func renderReceivedText(marker: FileTransfer.FileMarker) -> String {
        if let dur = marker.qfile.durationMs, dur > 0 {
            let secs = Double(dur) / 1000.0
            return String(format: "🎤 Nota vocale (%.1fs)", secs)
        }
        return "🎤 Nota vocale"
    }
}


import Foundation
import UIKit
import QAudionEngine

/// E2EE avatar transport (2026-07-30, see
/// `docs/E2EE_AVATAR_TRANSPORT_DESIGN.md` in bcrypto-server).
///
/// FIX (avatar plaintext exposure): this used to upload the plaintext
/// JPEG to the generic `/api/v1/files/upload` endpoint and set the
/// resulting URL as `PublicUser.avatarUrl` on the profile — readable by
/// ANY authenticated account that knew this user's id, no relationship
/// check at all (confirmed against the live server: `handleAvatarServe`
/// gates only on generic auth). Now the plaintext NEVER leaves the
/// device unencrypted: it's cached locally for self-display, and a
/// SEPARATE ciphertext is sent to each currently-known peer, encrypted
/// under THEIR OWN pairwise chain key (`AvatarAnnounceSender` /
/// `PairwiseChainKeyResolver`) — the server only ever sees N opaque
/// blobs, never the image, and a peer with no real PSK yet can't
/// decrypt any of them even if they somehow fetched the bytes.
@MainActor
final class AvatarUploader {

    enum Error: Swift.Error, LocalizedError {
        case notAuthenticated
        case imageEncodingFailed
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not signed in"
            case .imageEncodingFailed: return "Could not encode image"
            case .uploadFailed(let m): return "Upload failed: \(m)"
            }
        }
    }

    /// Where the plaintext self-avatar is cached for local display
    /// (Settings screens) — `Application Support` rather than `Caches`
    /// since this is a durable user choice, not disposable download
    /// state, and shouldn't be purged under disk pressure. Never
    /// uploaded anywhere in this form; only the per-peer ciphertexts
    /// `broadcastAvatarToKnownPeers` produces leave the device.
    static var selfAvatarCacheURL: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let path = base.appendingPathComponent("qaudion/avatars/self.jpg")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Resize + JPEG-encode, cache locally for self-display, bump the
    /// self-avatar version, and broadcast an `avatar_announce` to every
    /// currently-known peer (each encrypted under their own pairwise
    /// chain key — never one shared blob). Returns the LOCAL cache file
    /// URL (never a server URL) so existing callers that render it via
    /// `QAudionAvatar`/`AsyncImage` keep working unchanged.
    func uploadAndApply(image: UIImage) async throws -> URL {
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            throw Error.notAuthenticated
        }
        // `token` only gates the "authenticated" early-throw above —
        // this path no longer calls the network directly (broadcasting
        // goes through AvatarAnnounceSender/ChatMessageSendService,
        // which resolve their own auth).
        _ = token
        // Resize to 512x512 max + JPEG-encode at 0.85 quality.
        let resized = Self.resize(image, to: CGSize(width: 512, height: 512))
        guard let jpegData = resized.jpegData(compressionQuality: 0.85) else {
            throw Error.imageEncodingFailed
        }

        let cacheDir: URL
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            cacheDir = base.appendingPathComponent("qaudion/avatars", isDirectory: true)
            if !FileManager.default.fileExists(atPath: cacheDir.path) {
                try FileManager.default.createDirectory(
                    at: cacheDir, withIntermediateDirectories: true)
            }
        } catch {
            throw Error.uploadFailed("cache dir: \(error.localizedDescription)")
        }
        let selfURL = cacheDir.appendingPathComponent("self.jpg")
        do {
            try jpegData.write(to: selfURL, options: [.atomic])
        } catch {
            throw Error.uploadFailed("local cache write: \(error.localizedDescription)")
        }

        let version = appState.bumpSelfAvatarVersion()
        appState.broadcastAvatarToKnownPeers(jpegBytes: jpegData, version: version)

        return selfURL
    }

    private static func resize(_ image: UIImage, to maxSize: CGSize) -> UIImage {
        let aspectRatio = image.size.width / image.size.height
        var newSize = maxSize
        if aspectRatio > 1 {
            newSize.height = maxSize.width / aspectRatio
        } else {
            newSize.width = maxSize.height * aspectRatio
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

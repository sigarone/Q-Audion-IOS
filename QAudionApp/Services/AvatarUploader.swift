import Foundation
import UIKit
import QAudionEngine

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

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// Upload an image, then update the user's profile avatarUrl.
    /// Returns the resulting avatarUrl on success.
    func uploadAndApply(image: UIImage) async throws -> URL {
        guard let token = appState.authService.loadToken(), !token.isEmpty else {
            throw Error.notAuthenticated
        }
        // Resize to 512x512 max + JPEG-encode at 0.85 quality.
        let resized = Self.resize(image, to: CGSize(width: 512, height: 512))
        guard let jpegData = resized.jpegData(compressionQuality: 0.85) else {
            throw Error.imageEncodingFailed
        }

        // `token` only gates the "authenticated" early-throw above.
        _ = token
        // UPLOAD-401 FIX (2026-07-03) — use the refresher-wired provider
        // builder instead of a bare BCryptoBackendProvider(config: .pinned(
        // serverUrl:accessToken:)). The bare provider had neither refresh leg
        // armed, so avatar upload + profile update 401'd permanently once the
        // access token expired mid-session (same class as ChatVoiceNoteSender,
        // see AppState.makeUploadProvider).
        let provider = appState.makeUploadProvider()
        // BCryptoStorageApiImpl.uploadFile(data:filename:) is not part of StorageApi
        // protocol, so we cast to the concrete impl.
        guard let storageImpl = provider.storageApi as? BCryptoStorageApiImpl else {
            throw Error.uploadFailed("storageApi is not BCryptoStorageApiImpl")
        }

        // Upload to /files/upload — returns file_id.
        let fileId: String
        do {
            fileId = try await storageImpl.uploadFile(
                data: jpegData,
                filename: "avatar.jpg"
            )
        } catch {
            throw Error.uploadFailed("storage: \(error.localizedDescription)")
        }

        // Build the avatar URL from the file_id (server convention:
        // GET /api/v1/files/{file_id} returns the binary).
        let avatarUrlString = "\(appState.serverUrl)/api/v1/files/\(fileId)"
        guard let avatarUrl = URL(string: avatarUrlString) else {
            throw Error.uploadFailed("Could not construct avatarUrl from file_id \(fileId)")
        }

        // Update profile.
        do {
            try await provider.accountApi.updateProfile(
                displayName: nil,
                statusMessage: nil,
                avatarUrl: avatarUrl.absoluteString
            )
        } catch {
            throw Error.uploadFailed("profile update: \(error.localizedDescription)")
        }

        return avatarUrl
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

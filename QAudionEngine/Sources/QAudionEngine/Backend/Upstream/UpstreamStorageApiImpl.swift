import Foundation

/// File storage (attachments and backups) via Signal-compatible REST endpoints.
///
/// Signal uses a separate attachment service for file uploads/downloads.
/// Backup data is pre-encrypted by the engine layer before reaching this provider,
/// so the server only ever sees opaque ciphertext blobs.
public final class UpstreamStorageApiImpl: StorageApi {
    private let rest: BCryptoRestClient

    init(rest: BCryptoRestClient) {
        self.rest = rest
    }

    // MARK: - StorageApi

    /// Upload an encrypted backup blob to the Signal-compatible storage endpoint.
    ///
    /// Returns a server-assigned identifier that can be used to retrieve
    /// or delete the backup later.
    public func uploadBackup(data: Data, key: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "key": key,
            "data": data.base64EncodedString()
        ])
        let response = try await rest.post("/v1/storage/backup", body: body)

        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let id = json["id"] as? String else {
            throw BCryptoError.decodingError
        }
        return id
    }

    /// Download an encrypted backup blob by its key.
    ///
    /// Returns the raw ciphertext. Decryption is handled by the engine layer
    /// using the user's backup key.
    public func downloadBackup(key: String) async throws -> Data {
        let data = try await rest.get("/v1/storage/backup/\(key)")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["data"] as? String,
              let decoded = Data(base64Encoded: b64) else {
            throw BCryptoError.decodingError
        }
        return decoded
    }

    /// Delete a backup from the server by its key.
    public func deleteBackup(key: String) async throws {
        _ = try await rest.delete("/v1/storage/backup/\(key)")
    }

    /// List all backup keys stored on the server for the authenticated user.
    public func listBackups() async throws -> [String] {
        let data = try await rest.get("/v1/storage/backups")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = json["keys"] as? [String] else {
            throw BCryptoError.decodingError
        }
        return keys
    }
}

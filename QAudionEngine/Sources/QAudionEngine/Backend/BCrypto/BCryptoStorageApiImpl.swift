import Foundation

public final class BCryptoStorageApiImpl: StorageApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    // MARK: - Backup (matches server /api/v1/backup/*)

    public func uploadBackup(data: Data, key: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["key": key, "data": data.base64EncodedString()])
        let response = try await rest.post("/api/v1/backup/upload", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let id = json["id"] as? String else { throw BCryptoError.decodingError }
        return id
    }

    public func downloadBackup(key: String) async throws -> Data {
        let data = try await rest.get("/api/v1/backup/download/\(key)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["data"] as? String, let decoded = Data(base64Encoded: b64) else { throw BCryptoError.decodingError }
        return decoded
    }

    public func deleteBackup(key: String) async throws {
        _ = try await rest.delete("/api/v1/backup/\(key)")
    }

    public func listBackups() async throws -> [String] {
        let data = try await rest.get("/api/v1/backup/list")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = json["keys"] as? [String] else { throw BCryptoError.decodingError }
        return keys
    }

    // MARK: - File Upload/Download (matches server /api/v1/files/*)

    public func uploadFile(data: Data, filename: String) async throws -> String {
        // W443 — TUS resumable protocol for files > 1 MB; multipart fast-path
        // for small payloads (voice notes ~50–200 KB, thumbnails).
        let tusSizeThreshold = 1_048_576   // 1 MB
        if data.count > tusSizeThreshold {
            let capturedRest = rest
            let tusClient = TusUploadClient(
                session: capturedRest.urlSession,
                serverUrl: capturedRest.serverUrl,
                getToken: { capturedRest.accessToken }
            )
            return try await tusClient.upload(data: data)
        }
        // Existing multipart POST for small payloads.
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = createMultipartBody(boundary: boundary, fieldName: "file",
                                       fileName: filename, data: data)
        let headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        let response = try await rest.post("/api/v1/files/upload", body: body, headers: headers)
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let fileId = json["file_id"] as? String else { throw BCryptoError.decodingError }
        return fileId
    }

    public func downloadFile(fileId: String) async throws -> Data {
        return try await rest.get("/api/v1/files/\(fileId)")
    }

    // MARK: - Client Config

    /// Fetch server-side client configuration.
    /// GET /api/v1/config/client
    public func getClientConfig() async throws -> [String: Any] {
        let data = try await rest.get("/api/v1/config/client")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BCryptoError.decodingError
        }
        return json
    }

    // MARK: - Helpers

    private func createMultipartBody(boundary: String, fieldName: String, fileName: String, data: Data) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

import Foundation

public final class BCryptoStorageApiImpl: StorageApi {
    private let rest: BCryptoRestClient
    init(rest: BCryptoRestClient) { self.rest = rest }

    public func uploadBackup(data: Data, key: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["key": key, "data": data.base64EncodedString()])
        let response = try await rest.post("/api/v1/storage/backup", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let id = json["id"] as? String else { throw BCryptoError.decodingError }
        return id
    }
    public func downloadBackup(key: String) async throws -> Data {
        let data = try await rest.get("/api/v1/storage/backup/\(key)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["data"] as? String, let decoded = Data(base64Encoded: b64) else { throw BCryptoError.decodingError }
        return decoded
    }
    public func deleteBackup(key: String) async throws { _ = try await rest.delete("/api/v1/storage/backup/\(key)") }
    public func listBackups() async throws -> [String] {
        let data = try await rest.get("/api/v1/storage/backups")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = json["keys"] as? [String] else { throw BCryptoError.decodingError }
        return keys
    }
}

import Foundation

public final class OtaDownloadManager {
    private let restClient: BCryptoRestClient?

    public init(restClient: BCryptoRestClient? = nil) { self.restClient = restClient }

    public func downloadModel(name: String, to localPath: URL) async throws {
        guard let rest = restClient else { throw OtaError.noServer }
        let data = try await rest.get("/api/v1/models/\(name)")
        try data.write(to: localPath)
    }

    public func checkForUpdate(currentVersion: String) async throws -> String? {
        guard let rest = restClient else { return nil }
        let data = try await rest.get("/api/v1/models/latest")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return nil }
        return version != currentVersion ? version : nil
    }
}

public enum OtaError: Error { case noServer; case downloadFailed }

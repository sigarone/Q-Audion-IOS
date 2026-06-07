import Foundation

public final class OtaDownloadManager {
    private let restClient: BCryptoRestClient?

    public init(restClient: BCryptoRestClient? = nil) { self.restClient = restClient }

    public func downloadModel(name: String, to localPath: URL) async throws {
        guard let rest = restClient else { throw OtaError.noServer }
        guard OtaDownloadManager.isValidModelName(name) else { throw OtaError.invalidModelName }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let data = try await rest.get("/api/v1/models/\(encodedName)")
        try data.write(to: localPath)
    }

    private static func isValidModelName(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 128
            && !name.contains("..")
            && !name.contains("/")
            && !name.contains("\\")
            && name.range(of: "^[a-zA-Z0-9_\\-\\.]+$", options: .regularExpression) != nil
    }

    public func checkForUpdate(currentVersion: String) async throws -> String? {
        guard let rest = restClient else { return nil }
        let data = try await rest.get("/api/v1/models/latest")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return nil }
        return version != currentVersion ? version : nil
    }
}

public enum OtaError: Error { case noServer; case downloadFailed; case invalidModelName }

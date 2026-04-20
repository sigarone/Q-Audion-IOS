import Foundation

/// System / directory endpoints exposed by the bcrypto server.
///
/// Kept out of the cross-backend `AccountApi` protocol because these
/// endpoints have no upstream (Signal-style) equivalent. Exposed as a
/// lazy property on `BCryptoBackendProvider` for callers that specifically
/// target the bcrypto backend (dial-by-extension, health-check,
/// version-gate).
///
/// Response DTOs match Android `VersionResponse` / `HealthResponse` /
/// `DirectoryEntryDto` (see `DeviceDto.kt` + `ContactsDto.kt`).
public final class BCryptoSystemClient {
    private let rest: BCryptoRestClient

    public init(rest: BCryptoRestClient) { self.rest = rest }

    /// `GET /api/v1/version` → `{ version?, build?, min_supported_client? }`.
    public func getVersion() async throws -> ServerVersion {
        let data = try await rest.get("/api/v1/version")
        return try JSONDecoder().decode(ServerVersion.self, from: data)
    }

    /// `GET /api/v1/health` → `{ status, uptime_sec }`.
    public func getHealth() async throws -> ServerHealth {
        let data = try await rest.get("/api/v1/health")
        return try JSONDecoder().decode(ServerHealth.self, from: data)
    }

    /// `GET /api/v1/directory/by-extension/{n}`. Server returns 404 when
    /// the extension is not assigned — callers receive `nil` (domain-level
    /// "not found") instead of a thrown error. The REST client surfaces the
    /// raw status as `httpError(404)`.
    public func lookupByExtension(_ n: Int64) async throws -> DirectoryEntry? {
        do {
            let data = try await rest.get("/api/v1/directory/by-extension/\(n)")
            return try JSONDecoder().decode(DirectoryEntry.self, from: data)
        } catch let BCryptoError.httpError(code) where code == 404 {
            return nil
        }
    }
}

public struct ServerVersion: Codable, Hashable {
    public let version: String?
    public let build: String?
    public let minSupportedClient: String?

    enum CodingKeys: String, CodingKey {
        case version, build
        case minSupportedClient = "min_supported_client"
    }
}

public struct ServerHealth: Codable, Hashable {
    public let status: String
    public let uptimeSec: Int64

    enum CodingKeys: String, CodingKey {
        case status
        case uptimeSec = "uptime_sec"
    }

    public init(status: String = "ok", uptimeSec: Int64 = 0) {
        self.status = status
        self.uptimeSec = uptimeSec
    }
}

/// Matches Android `DirectoryEntryDto`.
public struct DirectoryEntry: Codable, Hashable {
    public let userId: String
    public let displayName: String
    public let `extension`: Int64
    public let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case `extension`
        case avatarUrl = "avatar_url"
    }
}

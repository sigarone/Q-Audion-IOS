import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// OIDC SSO client matching server's /api/v1/auth/oidc/* endpoints.
/// Supports Authorization Code flow with PKCE for enterprise SSO.
public final class BCryptoOIDCClient {
    private let rest: BCryptoRestClient

    public init(rest: BCryptoRestClient) { self.rest = rest }

    /// Check if OIDC is enabled on the server.
    public func isOIDCEnabled() async throws -> Bool {
        let data = try await rest.get("/api/v1/auth/oidc")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let enabled = json["oidc_enabled"] as? Bool else { return false }
        return enabled
    }

    /// Get the OIDC authorization URL from server.
    /// Returns the URL to open in a browser/ASWebAuthenticationSession.
    public func getAuthorizationURL() async throws -> URL {
        let data = try await rest.get("/api/v1/auth/oidc/authorize")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlString = json["authorize_url"] as? String,
              let url = URL(string: urlString) else {
            throw OIDCError.invalidResponse
        }
        return url
    }

    /// Exchange authorization code for tokens via server callback.
    /// The server handles the OIDC token exchange and returns BCrypto JWT tokens.
    public func handleCallback(code: String, state: String) async throws -> AuthCredentials {
        let dict: [String: Any] = ["code": code, "state": state]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await rest.post("/api/v1/auth/oidc/callback", body: body)
        return try JSONDecoder().decode(AuthCredentials.self, from: data)
    }
}

public enum OIDCError: Error {
    case invalidResponse
    case authenticationFailed
    case notEnabled
}

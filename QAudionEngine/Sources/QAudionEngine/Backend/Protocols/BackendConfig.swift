import Foundation

public struct BackendConfig: Codable {
    public var serverUrl: String
    public var accessToken: String?
    public var refreshToken: String?
    public var userId: String?
    public var deviceId: String?
    public var proxyEnabled: Bool
    public var proxyHost: String?
    public var proxyPort: Int?
    public var proxyType: String?  // "HTTP" or "SOCKS5"
    public var acceptSelfSignedCerts: Bool

    /// SPKI SHA-256 pin (base64) for certificate pinning.
    /// Fetched from /api/v1/security/cert-info.
    public var certPinSha256B64: String?

    /// Enable OIDC SSO authentication.
    public var oidcEnabled: Bool

    public init(serverUrl: String, accessToken: String? = nil, refreshToken: String? = nil,
                userId: String? = nil, deviceId: String? = nil,
                proxyEnabled: Bool = false, proxyHost: String? = nil,
                proxyPort: Int? = nil, proxyType: String? = nil,
                acceptSelfSignedCerts: Bool = false,
                certPinSha256B64: String? = nil, oidcEnabled: Bool = false) {
        self.serverUrl = serverUrl; self.accessToken = accessToken
        self.refreshToken = refreshToken; self.userId = userId; self.deviceId = deviceId
        self.proxyEnabled = proxyEnabled; self.proxyHost = proxyHost
        self.proxyPort = proxyPort; self.proxyType = proxyType
        self.acceptSelfSignedCerts = acceptSelfSignedCerts
        self.certPinSha256B64 = certPinSha256B64; self.oidcEnabled = oidcEnabled
    }
}

import Foundation

public struct BackendConfig: Codable {
    public var serverUrl: String
    public var accessToken: String?
    public var proxyEnabled: Bool
    public var proxyHost: String?
    public var proxyPort: Int?
    public var proxyType: String?  // "HTTP" or "SOCKS5"
    public var acceptSelfSignedCerts: Bool

    public init(serverUrl: String, accessToken: String? = nil, proxyEnabled: Bool = false,
                proxyHost: String? = nil, proxyPort: Int? = nil, proxyType: String? = nil,
                acceptSelfSignedCerts: Bool = false) {
        self.serverUrl = serverUrl; self.accessToken = accessToken; self.proxyEnabled = proxyEnabled
        self.proxyHost = proxyHost; self.proxyPort = proxyPort; self.proxyType = proxyType
        self.acceptSelfSignedCerts = acceptSelfSignedCerts
    }
}

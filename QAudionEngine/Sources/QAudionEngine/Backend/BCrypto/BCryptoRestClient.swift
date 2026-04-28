import Foundation
import CommonCrypto
import os

public final class BCryptoRestClient {
    /// Callback invoked when a protected request returns HTTP 401.
    /// Implementations should call POST /api/v1/auth/refresh with the current
    /// refresh token and return the new (accessToken, refreshToken) pair so
    /// the client can update its config and retry the original request. If
    /// refresh fails the callback should throw — the original request will
    /// then bubble up the 401 as BCryptoError.unauthorized.
    public typealias TokenRefresher = @Sendable () async throws -> (accessToken: String, refreshToken: String?)

    private var config: BackendConfig
    private let session: URLSession
    private var tokenRefresher: TokenRefresher?
    /// Serialises concurrent refresh attempts so we don't fire N /auth/refresh
    /// calls when many in-flight requests simultaneously hit 401.
    private let refreshLock = OSAllocatedUnfairLock<Void>(initialState: ())
    private var refreshInFlight: Task<Bool, Error>?

    public init(config: BackendConfig) {
        self.config = config
        if config.acceptSelfSignedCerts {
            self.session = URLSession(configuration: .default, delegate: SelfSignedCertDelegate(), delegateQueue: nil)
        } else if let pin = config.certPinSha256B64 {
            self.session = URLSession(configuration: .default, delegate: CertPinningDelegate(pinB64: pin), delegateQueue: nil)
        } else {
            self.session = URLSession.shared
        }
    }

    /// Install the callback that knows how to perform a token refresh. The
    /// owning `BCryptoBackendProvider` wires this to `BCryptoAccountApiImpl.refreshToken`
    /// after construction to avoid a circular init-time dependency.
    public func setTokenRefresher(_ refresher: @escaping TokenRefresher) {
        self.tokenRefresher = refresher
    }

    public func get(_ path: String, headers: [String: String] = [:]) async throws -> Data {
        try await request("GET", path: path, body: nil, headers: headers)
    }

    public func post(_ path: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        try await request("POST", path: path, body: body, headers: headers)
    }

    public func put(_ path: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        try await request("PUT", path: path, body: body, headers: headers)
    }

    public func delete(_ path: String, headers: [String: String] = [:]) async throws -> Data {
        try await request("DELETE", path: path, body: nil, headers: headers)
    }

    /// Multipart upload (avatar + fields).
    public func postMultipart(_ path: String, fields: [String: String], fileField: String?, fileData: Data?, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: config.serverUrl + path) else { throw BCryptoError.invalidUrl }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = config.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }

        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        if let field = fileField, let data = fileData {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BCryptoError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    private func request(_ method: String, path: String, body: Data?, headers: [String: String]) async throws -> Data {
        // First attempt with the currently cached access token.
        let (data, status) = try await performRequest(method, path: path, body: body, headers: headers)
        if (200...299).contains(status) {
            return data
        }

        // On 401, try a single refresh-and-retry cycle (if a refresher is installed
        // and we have a refresh token to hand to it). This masks the common case
        // of the 15-minute access token expiring during a long-lived session.
        if status == 401,
           tokenRefresher != nil,
           config.refreshToken != nil,
           // Don't loop on the refresh endpoint itself.
           !path.hasSuffix("/auth/refresh") {
            let refreshed = try await tryRefreshToken()
            if refreshed {
                let (retryData, retryStatus) = try await performRequest(method, path: path, body: body, headers: headers)
                if (200...299).contains(retryStatus) {
                    return retryData
                }
                if retryStatus == 401 { throw BCryptoError.unauthorized }
                throw BCryptoError.httpError(retryStatus)
            }
            throw BCryptoError.unauthorized
        }

        if status == 401 { throw BCryptoError.unauthorized }
        throw BCryptoError.httpError(status)
    }

    private func performRequest(_ method: String, path: String, body: Data?, headers: [String: String]) async throws -> (Data, Int) {
        guard let url = URL(string: config.serverUrl + path) else { throw BCryptoError.invalidUrl }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BCryptoError.httpError(0) }
        return (data, http.statusCode)
    }

    /// Invoke the installed token refresher at most once per batch of concurrent
    /// 401-affected requests. Returns `true` if the refresh succeeded and
    /// `config.accessToken` was updated; `false` if there was no refresher.
    private func tryRefreshToken() async throws -> Bool {
        guard let refresher = tokenRefresher else { return false }

        // Read or create the in-flight task under the lock (non-async closure,
        // so OSAllocatedUnfairLock.withLock is safe here).
        let task: Task<Bool, Error> = refreshLock.withLock {
            if let existing = refreshInFlight { return existing }
            let newTask = Task<Bool, Error> {
                let pair = try await refresher()
                self.config.accessToken = pair.accessToken
                if let newRefresh = pair.refreshToken { self.config.refreshToken = newRefresh }
                return true
            }
            refreshInFlight = newTask
            return newTask
        }

        defer {
            refreshLock.withLock { refreshInFlight = nil }
        }
        return try await task.value
    }

    /// The base server URL from the current configuration.
    public var serverUrl: String { config.serverUrl }

    /// The user ID from the current configuration, if authenticated.
    public var userId: String? { config.userId }

    public func updateConfig(_ newConfig: BackendConfig) { config = newConfig }
}

public enum BCryptoError: Error {
    case invalidUrl
    case httpError(Int)
    case decodingError
    case unauthorized
    case notFound
    case certPinningFailed
    /// Server responded 200 but payload signalled a domain error via a
    /// string field (e.g. recovery-setup `{enrolled:false, error:"..."}`).
    case server(String)
}

// MARK: - Certificate Pinning Delegate

private class CertPinningDelegate: NSObject, URLSessionDelegate {
    private let pinnedSPKIHash: Data?

    init(pinB64: String) {
        self.pinnedSPKIHash = Data(base64Encoded: pinB64)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let serverTrust = challenge.protectionSpace.serverTrust,
              let pinnedHash = pinnedSPKIHash else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Get the server's leaf certificate
        guard SecTrustGetCertificateCount(serverTrust) > 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Use SecTrustCopyCertificateChain for iOS 15+
        if let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
           let serverCert = chain.first {
            let serverCertData = SecCertificateCopyData(serverCert) as Data
            // Hash the SPKI (Subject Public Key Info)
            // For simplicity, hash the whole cert DER and compare
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            serverCertData.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(serverCertData.count), &hash) }
            let serverHash = Data(hash)
            if serverHash == pinnedHash {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Self-Signed Cert Delegate

private class SelfSignedCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
}

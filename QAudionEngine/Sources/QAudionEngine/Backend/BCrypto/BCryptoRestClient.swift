import Foundation
import CommonCrypto

public final class BCryptoRestClient {
    private var config: BackendConfig
    private let session: URLSession

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
        guard let url = URL(string: config.serverUrl + path) else { throw BCryptoError.invalidUrl }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { req.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw BCryptoError.httpError(0)
        }
        // Handle 401 -> unauthorized
        if http.statusCode == 401 { throw BCryptoError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw BCryptoError.httpError(http.statusCode)
        }
        return data
    }

    public func updateConfig(_ newConfig: BackendConfig) { config = newConfig }
}

public enum BCryptoError: Error {
    case invalidUrl
    case httpError(Int)
    case decodingError
    case unauthorized
    case notFound
    case certPinningFailed
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

import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// TLS certificate pinning for BCrypto server connections.
/// Pins the SHA-256 hash of the server certificate's Subject Public Key Info (SPKI)
/// and rejects any connection whose certificate does not match a known pin.
public final class CertificatePinning: NSObject, URLSessionDelegate, @unchecked Sendable {

    /// SHA-256 hashes of pinned SPKI data (base64-encoded).
    /// Include primary + at least one backup pin for key rotation.
    private let pinnedHashes: Set<String>
    private let enforcePinning: Bool

    /// Creates a pinning delegate.
    /// - Parameters:
    ///   - hashes: Base64-encoded SHA-256 hashes of each trusted certificate's SPKI.
    ///   - enforce: When `true` (default), connections to unpinned hosts are rejected.
    public init(hashes: [String] = CryptoConstants.pinnedCertHashes,
                enforce: Bool = CryptoConstants.pinningEnabled) {
        self.pinnedHashes = Set(hashes)
        self.enforcePinning = enforce
        super.init()
    }

    // MARK: - URLSessionDelegate

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Fail-closed: if pinning is disabled but no hashes are configured, reject.
        guard enforcePinning, !pinnedHashes.isEmpty else {
            if !enforcePinning {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        guard validatePinnedCertificates(serverTrust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }

    // MARK: - SPKI hash validation

    private func validatePinnedCertificates(_ trust: SecTrust) -> Bool {
        let certCount = SecTrustGetCertificateCount(trust)
        for index in 0..<certCount {
            guard let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  index < certificate.count else { continue }
            let cert = certificate[index]
            if let spkiHash = spkiSHA256(for: cert), pinnedHashes.contains(spkiHash) {
                return true
            }
        }
        return false
    }

    /// Extracts the Subject Public Key Info from a certificate and returns its
    /// SHA-256 hash as a base64-encoded string.
    private func spkiSHA256(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }

        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        let hash = SHA256.hash(data: keyData)
        return Data(hash).base64EncodedString()
    }

    /// Creates a `URLSession` pre-configured with certificate pinning.
    public func pinnedSession(configuration: URLSessionConfiguration = .ephemeral,
                              delegateQueue: OperationQueue? = nil) -> URLSession {
        return URLSession(configuration: configuration,
                          delegate: self,
                          delegateQueue: delegateQueue)
    }
}

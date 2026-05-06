import Foundation
import CryptoKit

/// Fetches and verifies AASIST deepfake-detection model bundles from
/// `bcrypto-server`. Per server audit, this endpoint is gated behind
/// admin signing — the manifest carries an Ed25519 signature over the
/// other fields, plus SHA-256 of the binary for client-side integrity.
///
/// iOS uses a smaller AASIST model (per Resources/aasist_raw_*.onnx in
/// the engine). This client lets future iOS deepfake-detector code
/// pull updated weights without an app store release.
///
/// Security gate:
/// 1. Fetch manifest → verify Ed25519 signature against pinned trust anchor.
/// 2. Fetch binary → verify SHA-256 matches manifest.sha256.
/// 3. Only then expose to caller.
public final class BCryptoOtaModelClient {

    public struct Manifest: Equatable, Decodable {
        public let modelName: String
        public let version: String
        public let sha256: String
        public let sizeBytes: Int64
        public let downloadUrl: String
        public let signature: String
        public let signingKeyId: String

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case version
            case sha256
            case sizeBytes = "size_bytes"
            case downloadUrl = "download_url"
            case signature
            case signingKeyId = "signing_key_id"
        }
    }

    public enum Error: Swift.Error, LocalizedError {
        case httpError(Int)
        case decodingFailed(String)
        case signatureVerificationFailed
        case sha256Mismatch(expected: String, actual: String)
        case unknownSigningKeyId(String)
        case sizeMismatch(expected: Int64, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .httpError(let c): return "HTTP error \(c)"
            case .decodingFailed(let m): return "Decode failed: \(m)"
            case .signatureVerificationFailed: return "Manifest signature verification failed"
            case .sha256Mismatch(let e, let a): return "Binary SHA-256 mismatch: expected \(e.prefix(16))... got \(a.prefix(16))..."
            case .unknownSigningKeyId(let id): return "Unknown signing key id: \(id) (caller must pin trust anchor)"
            case .sizeMismatch(let e, let a): return "Binary size mismatch: expected \(e), got \(a)"
            }
        }
    }

    private let baseUrl: URL
    private let session: URLSession
    /// Map of signing key id → 32-byte Ed25519 public key. Caller pins
    /// known anchors here. Manifest with an unknown key id is rejected.
    private let trustAnchors: [String: Curve25519.Signing.PublicKey]

    public init(baseUrl: URL,
                session: URLSession = .shared,
                trustAnchors: [String: Curve25519.Signing.PublicKey]) {
        self.baseUrl = baseUrl
        self.session = session
        self.trustAnchors = trustAnchors
    }

    /// Fetch + verify manifest for the desktop AASIST channel.
    public func fetchManifest() async throws -> Manifest {
        let url = baseUrl.appendingPathComponent("api/v1/models/desktop/aasist/manifest")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(http.statusCode)
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw Error.decodingFailed(String(describing: error))
        }

        // Verify Ed25519 signature.
        guard let publicKey = trustAnchors[manifest.signingKeyId] else {
            throw Error.unknownSigningKeyId(manifest.signingKeyId)
        }
        guard let signatureBytes = Data(base64Encoded: manifest.signature) else {
            throw Error.decodingFailed("signature not base64")
        }
        let canonical = try canonicalSignableBytes(of: manifest)
        guard publicKey.isValidSignature(signatureBytes, for: canonical) else {
            throw Error.signatureVerificationFailed
        }

        return manifest
    }

    /// Fetch model binary and verify SHA-256 + size match manifest.
    public func fetchBinary(verifying manifest: Manifest) async throws -> Data {
        let url: URL
        if manifest.downloadUrl.hasPrefix("http") {
            guard let parsed = URL(string: manifest.downloadUrl) else {
                throw Error.decodingFailed("bad download_url")
            }
            url = parsed
        } else {
            url = baseUrl.appendingPathComponent(
                manifest.downloadUrl.hasPrefix("/") ? String(manifest.downloadUrl.dropFirst()) : manifest.downloadUrl
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.httpError(http.statusCode)
        }

        // Size check.
        if Int64(data.count) != manifest.sizeBytes {
            throw Error.sizeMismatch(expected: manifest.sizeBytes, actual: data.count)
        }

        // SHA-256 check.
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == manifest.sha256.lowercased() else {
            throw Error.sha256Mismatch(expected: manifest.sha256, actual: actual)
        }

        return data
    }

    // MARK: - Canonical signable bytes

    /// Computes the canonical UTF-8 JSON of the manifest fields the
    /// signature covers (everything except `signature` itself).
    /// Server signs the same canonical form.
    private func canonicalSignableBytes(of manifest: Manifest) throws -> Data {
        let signableDict: [String: Any] = [
            "model_name": manifest.modelName,
            "version": manifest.version,
            "sha256": manifest.sha256,
            "size_bytes": manifest.sizeBytes,
            "download_url": manifest.downloadUrl,
            "signing_key_id": manifest.signingKeyId
        ]
        return try JSONSerialization.data(withJSONObject: signableDict, options: [.sortedKeys])
    }
}

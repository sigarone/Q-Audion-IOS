import XCTest
import CryptoKit
@testable import QAudionEngine

final class BCryptoOtaModelClientTests: XCTestCase {

    private var session: URLSession!
    private var trustKey: Curve25519.Signing.PrivateKey!
    private var trustAnchors: [String: Curve25519.Signing.PublicKey]!

    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: cfg)
        trustKey = Curve25519.Signing.PrivateKey()
        trustAnchors = ["qaudion-models-2026": trustKey.publicKey]
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func test_fetchManifest_validSignature_succeeds() async throws {
        let (manifestJson, _) = try makeFixtureManifest()
        StubProtocol.handler = { _ in
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             manifestJson)
        }

        let client = BCryptoOtaModelClient(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
            baseUrl: URL(string: "https://test")!,
            session: session,
            trustAnchors: trustAnchors
        )
        let manifest = try await client.fetchManifest()
        XCTAssertEqual(manifest.modelName, "aasist_raw_base_int8")
    }

    func test_fetchManifest_unknownSigningKeyId_throws() async throws {
        let trustKey2 = Curve25519.Signing.PrivateKey()
        let badAnchors = ["unrelated-id": trustKey2.publicKey]

        let (manifestJson, _) = try makeFixtureManifest()
        StubProtocol.handler = { _ in
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             manifestJson)
        }

        let client = BCryptoOtaModelClient(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
            baseUrl: URL(string: "https://test")!,
            session: session,
            trustAnchors: badAnchors
        )
        do {
            _ = try await client.fetchManifest()
            XCTFail("Should have thrown")
        } catch BCryptoOtaModelClient.Error.unknownSigningKeyId {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_fetchManifest_invalidSignature_throws() async throws {
        // Sign with a DIFFERENT key but claim the trust-anchor ID.
        let (_, manifest) = try makeFixtureManifest()
        let evilKey = Curve25519.Signing.PrivateKey()
        let canonical = try canonicalSignableBytes(of: manifest)
        let badSig = try evilKey.signature(for: canonical).base64EncodedString()
        let tampered = BCryptoOtaModelClient.Manifest(
            modelName: manifest.modelName, version: manifest.version,
            sha256: manifest.sha256, sizeBytes: manifest.sizeBytes,
            downloadUrl: manifest.downloadUrl, signature: badSig,
            signingKeyId: manifest.signingKeyId
        )
        let json = try JSONEncoder().encode(tampered)

        StubProtocol.handler = { _ in
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let client = BCryptoOtaModelClient(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
            baseUrl: URL(string: "https://test")!,
            session: session,
            trustAnchors: trustAnchors
        )
        do {
            _ = try await client.fetchManifest()
            XCTFail("Should have thrown")
        } catch BCryptoOtaModelClient.Error.signatureVerificationFailed {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_fetchBinary_sha256Match_succeeds() async throws {
        let binary = Data((0..<1024).map { UInt8($0 & 0xFF) })
        let sha = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()

        let (_, manifest) = try makeFixtureManifest(binary: binary, overrideSha: sha)
        StubProtocol.handler = { req in
            if req.url?.path.contains("download") == true {
                // req.url is guaranteed non-nil: client always builds requests via
                // URLRequest(url:) from baseUrl.appendingPathComponent(...).
                // swiftlint:disable:next force_unwrapping
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, binary)
            }
            // req.url is guaranteed non-nil (see above); status/url are always valid here.
            // swiftlint:disable:next force_unwrapping
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }

        let client = BCryptoOtaModelClient(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
            baseUrl: URL(string: "https://test")!,
            session: session,
            trustAnchors: trustAnchors
        )
        let data = try await client.fetchBinary(verifying: manifest)
        XCTAssertEqual(data, binary)
    }

    func test_fetchBinary_sha256Mismatch_throws() async throws {
        let realBinary = Data((0..<512).map { UInt8($0 & 0xFF) })
        // Manifest claims a DIFFERENT binary's hash.
        let fakeSha = String(repeating: "0", count: 64)
        let (_, manifest) = try makeFixtureManifest(binary: realBinary, overrideSha: fakeSha)

        StubProtocol.handler = { _ in
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             realBinary)
        }

        let client = BCryptoOtaModelClient(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
            baseUrl: URL(string: "https://test")!,
            session: session,
            trustAnchors: trustAnchors
        )
        do {
            _ = try await client.fetchBinary(verifying: manifest)
            XCTFail("Should have thrown")
        } catch BCryptoOtaModelClient.Error.sha256Mismatch {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeFixtureManifest(
        binary: Data = Data((0..<1024).map { UInt8($0 & 0xFF) }),
        overrideSha: String? = nil
    ) throws -> (json: Data, manifest: BCryptoOtaModelClient.Manifest) {
        let sha = overrideSha ?? SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let template = BCryptoOtaModelClient.Manifest(
            modelName: "aasist_raw_base_int8",
            version: "v1.2.3",
            sha256: sha,
            sizeBytes: Int64(binary.count),
            downloadUrl: "/api/v1/models/desktop/aasist/download",
            signature: "",
            signingKeyId: "qaudion-models-2026"
        )
        let canonical = try canonicalSignableBytes(of: template)
        let signature = try trustKey.signature(for: canonical).base64EncodedString()
        let signed = BCryptoOtaModelClient.Manifest(
            modelName: template.modelName,
            version: template.version,
            sha256: template.sha256,
            sizeBytes: template.sizeBytes,
            downloadUrl: template.downloadUrl,
            signature: signature,
            signingKeyId: template.signingKeyId
        )
        let json = try JSONEncoder().encode(signed)
        return (json, signed)
    }

    private func canonicalSignableBytes(of m: BCryptoOtaModelClient.Manifest) throws -> Data {
        let signableDict: [String: Any] = [
            "model_name": m.modelName,
            "version": m.version,
            "sha256": m.sha256,
            "size_bytes": m.sizeBytes,
            "download_url": m.downloadUrl,
            "signing_key_id": m.signingKeyId
        ]
        return try JSONSerialization.data(withJSONObject: signableDict, options: [.sortedKeys])
    }
}

// Stub URLProtocol
private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        guard let h = StubProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (resp, data) = h(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let d = data { client?.urlProtocol(self, didLoad: d) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

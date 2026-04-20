import XCTest
@testable import QAudionEngine

/// Wire-format guard for `POST /api/v1/device/publickey` and
/// `GET /api/v1/kms/pending`. Shapes must match Android
/// `DevicePublicKeyRequest` + `KmsPendingResponse`/`KmsKeyDto`
/// (see `core/core-data/.../dto/DeviceDto.kt` + `KmsDto.kt`).
///
/// Original drift: `docs/progress/PHASE1_REST_AUDIT.md` §3.9 / §3.10.
final class BCryptoKmsWireFormatTests: XCTestCase {

    override func setUp() {
        super.setUp()
        KmsStubURLProtocol.reset()
        URLProtocol.registerClass(KmsStubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(KmsStubURLProtocol.self)
        super.tearDown()
    }

    // MARK: - registerPublicKey

    func testRegisterPublicKeyOmitsDeviceIdAndDefaultsToX25519() async throws {
        KmsStubURLProtocol.stubResponse = (200, Data("{}".utf8))
        let client = BCryptoKmsClient(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        try await client.registerPublicKey(publicKey: Data([0x01, 0x02, 0x03, 0x04]))

        let body = try XCTUnwrap(KmsStubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertNil(json["device_id"], "server derives device id from auth token — iOS must not send it")
        XCTAssertEqual(json["public_key"] as? String, Data([0x01, 0x02, 0x03, 0x04]).base64EncodedString())
        XCTAssertEqual(json["key_type"] as? String, "x25519")
    }

    func testRegisterPublicKeyHonoursExplicitKeyType() async throws {
        KmsStubURLProtocol.stubResponse = (200, Data("{}".utf8))
        let client = BCryptoKmsClient(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        try await client.registerPublicKey(publicKey: Data([0xaa]), keyType: "ml-kem-1024")

        let body = try XCTUnwrap(KmsStubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["key_type"] as? String, "ml-kem-1024")
    }

    // MARK: - getPendingKeys

    func testGetPendingKeysDecodesKeysEnvelopeWithFullDto() async throws {
        let payload = #"""
        {"keys":[{
          "key_id":"k-1",
          "key_name":"voice-group-42",
          "fingerprint":"ab:cd:ef",
          "status":"pending",
          "encrypted_package":"UEFDSw==",
          "ephemeral_pubkey":"RVBIRU0=",
          "nonce":"Tk9OQ0U=",
          "created_at":"2026-04-20T10:00:00Z"
        }]}
        """#
        KmsStubURLProtocol.stubResponse = (200, Data(payload.utf8))
        let client = BCryptoKmsClient(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        let keys = try await client.getPendingKeys()
        XCTAssertEqual(keys.count, 1)
        let k = keys[0]
        XCTAssertEqual(k.keyId, "k-1")
        XCTAssertEqual(k.keyName, "voice-group-42")
        XCTAssertEqual(k.fingerprint, "ab:cd:ef")
        XCTAssertEqual(k.status, "pending")
        XCTAssertEqual(k.encryptedPackage, "UEFDSw==")
        XCTAssertEqual(k.ephemeralPubkey, "RVBIRU0=")
        XCTAssertEqual(k.nonce, "Tk9OQ0U=")
        XCTAssertEqual(k.createdAt, "2026-04-20T10:00:00Z")
    }

    func testGetPendingKeysEmptyEnvelope() async throws {
        KmsStubURLProtocol.stubResponse = (200, Data(#"{"keys":[]}"#.utf8))
        let client = BCryptoKmsClient(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))
        let keys = try await client.getPendingKeys()
        XCTAssertTrue(keys.isEmpty)
    }
}

// MARK: - URLProtocol stub

private final class KmsStubURLProtocol: URLProtocol {
    static var stubResponse: (status: Int, body: Data) = (200, Data())
    static var lastRequestBody: Data?

    static func reset() {
        stubResponse = (200, Data())
        lastRequestBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let body = request.httpBody {
            Self.lastRequestBody = body
        } else if let stream = request.httpBodyStream {
            Self.lastRequestBody = Self.readStream(stream)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.stubResponse.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubResponse.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: bufferSize)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

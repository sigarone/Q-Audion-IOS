import XCTest
@testable import QAudionEngine

/// Wire-format guard for the `/api/v1/register` and `/api/v1/auth/login`
/// payloads. These fields must match the Android `BCryptoApi.kt` contract
/// byte-for-byte — server treats both endpoints' phone field as an opaque
/// identifier under the `phone_number` key, while the value sent IS the
/// SHA-256 hash of the normalised E.164 phone.
///
/// See `docs/progress/PHASE1_REST_AUDIT.md` §3.1 / §3.2 for the original
/// drift findings.
final class BCryptoAuthWireFormatTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        super.tearDown()
    }

    // MARK: - register

    func testRegisterSendsHashUnderPhoneNumberKey() async throws {
        StubURLProtocol.stubResponse = (200, Data(#"{"user_id":"u-123"}"#.utf8))
        let rest = BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"))
        let api = BCryptoAccountApiImpl(rest: rest)

        let userId = try await api.register(
            phoneNumber: "+14155552671",
            password: "s3cret!",
            inviteCode: nil,
            displayName: nil
        )
        XCTAssertEqual(userId, "u-123")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // The wire key must be `phone_number` (not `phone_hash`).
        XCTAssertNil(json["phone_hash"], "register must not send `phone_hash` — server expects `phone_number`")
        let phoneField = try XCTUnwrap(json["phone_number"] as? String)

        // The value must be the SHA-256 hash of the normalised E.164 phone,
        // not the raw phone number.
        XCTAssertNotEqual(phoneField, "+14155552671", "register must not send raw phone on the wire")
        let expectedHash = try PhoneHash.hash("+14155552671")
        XCTAssertEqual(phoneField, expectedHash)

        // Password must be present and match input.
        XCTAssertEqual(json["password"] as? String, "s3cret!")
    }

    func testRegisterOmitsOptionalFieldsWhenNil() async throws {
        StubURLProtocol.stubResponse = (200, Data(#"{"user_id":"u-123"}"#.utf8))
        let api = BCryptoAccountApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        _ = try await api.register(phoneNumber: "+14155552671", password: "pw", inviteCode: nil, displayName: nil)

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["invite_code"])
        XCTAssertNil(json["display_name"])
    }

    func testRegisterIncludesInviteCodeAndDisplayNameWhenProvided() async throws {
        StubURLProtocol.stubResponse = (200, Data(#"{"user_id":"u-123"}"#.utf8))
        let api = BCryptoAccountApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        _ = try await api.register(
            phoneNumber: "+14155552671",
            password: "pw",
            inviteCode: "INVITE-42",
            displayName: "Alice"
        )
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["invite_code"] as? String, "INVITE-42")
        XCTAssertEqual(json["display_name"] as? String, "Alice")
    }

    // MARK: - login

    func testLoginSendsPhoneHashUnderPhoneNumberKey() async throws {
        let credsJson = #"""
        {"access_token":"a","refresh_token":"r","expires_in":900,"user_id":"u","device_id":"d"}
        """#
        StubURLProtocol.stubResponse = (200, Data(credsJson.utf8))
        let api = BCryptoAccountApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        let hash = try PhoneHash.hash("+14155552671")
        let creds = try await api.login(phoneHash: hash, password: "pw", deviceName: "iPhone")
        XCTAssertEqual(creds.userId, "u")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["phone_hash"], "login must not send `phone_hash` — server expects `phone_number`")
        XCTAssertEqual(json["phone_number"] as? String, hash)
        XCTAssertEqual(json["password"] as? String, "pw")
        XCTAssertEqual(json["device_name"] as? String, "iPhone")
    }
}

// MARK: - URLProtocol stub

/// URLProtocol subclass that intercepts every request sent through URLSession
/// (including `URLSession.shared` used by BCryptoRestClient's default init
/// path) and returns a canned response. Captures the last request body so
/// tests can assert the serialised payload byte-for-byte.
private final class StubURLProtocol: URLProtocol {
    static var stubResponse: (status: Int, body: Data) = (200, Data())
    static var lastRequestBody: Data?
    static var lastRequestPath: String?

    static func reset() {
        stubResponse = (200, Data())
        lastRequestBody = nil
        lastRequestPath = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession strips httpBody on non-stream requests when it hands them
        // to the protocol — use httpBodyStream fallback to read the bytes.
        if let body = request.httpBody {
            Self.lastRequestBody = body
        } else if let stream = request.httpBodyStream {
            Self.lastRequestBody = Self.readStream(stream)
        }
        Self.lastRequestPath = request.url?.path

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

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
        let rest = BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"), testURLProtocolClasses: [StubURLProtocol.self])
        let api = BCryptoAccountApiImpl(rest: rest)

        let userId = try await api.register(
            phoneNumber: "+14155552671",
            password: "s3cret!",
            inviteCode: nil,
            displayName: nil,
            ageDeclared: false
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
        let api = BCryptoAccountApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"), testURLProtocolClasses: [StubURLProtocol.self]))

        _ = try await api.register(phoneNumber: "+14155552671", password: "pw", inviteCode: nil, displayName: nil, ageDeclared: false)

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["invite_code"])
        XCTAssertNil(json["display_name"])
    }

    func testRegisterIncludesInviteCodeAndDisplayNameWhenProvided() async throws {
        StubURLProtocol.stubResponse = (200, Data(#"{"user_id":"u-123"}"#.utf8))
        let api = BCryptoAccountApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"), testURLProtocolClasses: [StubURLProtocol.self]))

        _ = try await api.register(
            phoneNumber: "+14155552671",
            password: "pw",
            inviteCode: "INVITE-42",
            displayName: "Alice",
            ageDeclared: false
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
        let api = BCryptoAccountApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"), testURLProtocolClasses: [StubURLProtocol.self]))

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

    // MARK: - register/extension (interno + email, invite code)

    private func makeRest() -> BCryptoRestClient {
        BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"), testURLProtocolClasses: [StubURLProtocol.self])
    }

    private func makeApi() -> BCryptoAccountApiImpl {
        BCryptoAccountApiImpl(rest: makeRest())
    }

    func testRegisterExtensionOnlySendsInviteCodeEmailAndPlatform() async throws {
        let okJson = #"""
        {"user_id":"u","device_id":"d","access_token":"a","refresh_token":"r","expires_in":900,"extension":1001,"email_pending_verification":true}
        """#
        StubURLProtocol.stubResponse = (200, Data(okJson.utf8))

        let result = try await makeApi().registerExtensionOnly(
            displayName: "Alice",
            email: "alice@example.com",
            inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ",
            ageDeclared: false
        )
        XCTAssertEqual(result.userId, "u")
        XCTAssertEqual(StubURLProtocol.lastRequestPath, "/api/v1/auth/register/extension")

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["invite_code"] as? String, "QA1-7K3M9-PXTVY-R2HN5-ZZ")
        XCTAssertEqual(json["email"] as? String, "alice@example.com")
        XCTAssertEqual(json["display_name"] as? String, "Alice")
        XCTAssertEqual(json["platform"] as? String, "ios")
    }

    func testRegisterExtensionOnlyOmitsDisplayNameWhenNil() async throws {
        StubURLProtocol.stubResponse = (403, Data(#"{"error":"invite code required"}"#.utf8))
        _ = try? await makeApi().registerExtensionOnly(displayName: nil, email: "a@b.co", inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ", ageDeclared: false)

        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["display_name"])
        XCTAssertEqual(json["invite_code"] as? String, "QA1-7K3M9-PXTVY-R2HN5-ZZ")
    }

    func testRegisterExtensionOnly403RequiredThrowsInviteCodeRequired() async {
        StubURLProtocol.stubResponse = (403, Data(#"{"error":"invite code required"}"#.utf8))
        do {
            _ = try await makeApi().registerExtensionOnly(displayName: nil, email: "a@b.co", inviteCode: "", ageDeclared: false)
            XCTFail("expected BCryptoInviteCodeError")
        } catch {
            XCTAssertEqual(error as? BCryptoInviteCodeError, BCryptoInviteCodeError(reason: .required))
        }
    }

    func testRegisterExtensionOnly403InvalidThrowsInviteCodeInvalid() async {
        StubURLProtocol.stubResponse = (403, Data(#"{"error":"invalid or expired invite code"}"#.utf8))
        do {
            _ = try await makeApi().registerExtensionOnly(displayName: nil, email: "a@b.co", inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ", ageDeclared: false)
            XCTFail("expected BCryptoInviteCodeError")
        } catch {
            XCTAssertEqual(error as? BCryptoInviteCodeError, BCryptoInviteCodeError(reason: .invalid))
        }
    }

    func testRegisterExtensionOnlyUnrelated403StaysHttpError() async {
        StubURLProtocol.stubResponse = (403, Data(#"{"error":"forbidden"}"#.utf8))
        do {
            _ = try await makeApi().registerExtensionOnly(displayName: nil, email: "a@b.co", inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ", ageDeclared: false)
            XCTFail("expected BCryptoError.httpError(403)")
        } catch BCryptoError.httpError(let status) {
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRegisterExtensionOnly429StaysHttpError() async {
        StubURLProtocol.stubResponse = (429, Data(#"{"error":"too many attempts"}"#.utf8))
        do {
            _ = try await makeApi().registerExtensionOnly(displayName: nil, email: "a@b.co", inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ", ageDeclared: false)
            XCTFail("expected BCryptoError.httpError(429)")
        } catch BCryptoError.httpError(let status) {
            XCTAssertEqual(status, 429)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testVerifyOtp403WithOtpBranchMessageThrowsInviteCodeRequired() async {
        // The OTP register branch words the same condition "invite_code required".
        StubURLProtocol.stubResponse = (403, Data(#"{"error":"invite_code required"}"#.utf8))
        do {
            _ = try await makeApi().verifyOtp(phoneNumber: "+14155552671", code: "123456", purpose: .register,
                                              deviceName: "iPhone", inviteCode: nil, displayName: nil, ageDeclared: false)
            XCTFail("expected BCryptoInviteCodeError")
        } catch {
            XCTAssertEqual(error as? BCryptoInviteCodeError, BCryptoInviteCodeError(reason: .required))
        }
    }

    func testVerifyOtp403InvalidThrowsInviteCodeInvalid() async {
        StubURLProtocol.stubResponse = (403, Data(#"{"error":"invalid or expired invite code"}"#.utf8))
        do {
            _ = try await makeApi().verifyOtp(phoneNumber: "+14155552671", code: "123456", purpose: .register,
                                              deviceName: "iPhone", inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ", displayName: nil,
                                              ageDeclared: false)
            XCTFail("expected BCryptoInviteCodeError")
        } catch {
            XCTAssertEqual(error as? BCryptoInviteCodeError, BCryptoInviteCodeError(reason: .invalid))
        }
    }

    func testVerifyOtpUnrelated403StaysHttpError() async {
        StubURLProtocol.stubResponse = (403, Data(#"{"error":"forbidden"}"#.utf8))
        do {
            _ = try await makeApi().verifyOtp(phoneNumber: "+14155552671", code: "123456", purpose: .login,
                                              deviceName: "iPhone", inviteCode: nil, displayName: nil, ageDeclared: false)
            XCTFail("expected BCryptoError.httpError(403)")
        } catch BCryptoError.httpError(let status) {
            XCTAssertEqual(status, 403)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Age declaration (register, otp/verify, register/extension)

    private let okAuthJson = #"""
    {"user_id":"u","device_id":"d","access_token":"a","refresh_token":"r","expires_in":900,"extension":1001}
    """#

    private func lastBodyJson() throws -> [String: Any] {
        let body = try XCTUnwrap(StubURLProtocol.lastRequestBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// What the server accepts in `terms_version`: 1 to 32 letters, digits, `.`, `_` and `-`.
    private func isAcceptedTermsVersion(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return (1...32).contains(value.count) && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Ticked box: both keys travel, `age_declaration` as the JSON boolean `true` and `terms_version` in a form the
    /// server reads.
    private func assertDeclared(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let declaration = json["age_declaration"]
        XCTAssertNotNil(declaration, "age_declaration is missing", file: file, line: line)
        if let number = declaration as? NSNumber {
            XCTAssertTrue(CFGetTypeID(number) == CFBooleanGetTypeID(), "age_declaration is not a JSON boolean", file: file, line: line)
            XCTAssertTrue(number.boolValue, "age_declaration is not true", file: file, line: line)
        } else {
            XCTFail("age_declaration is not a boolean", file: file, line: line)
        }
        let version = json["terms_version"] as? String
        XCTAssertNotNil(version, "terms_version is missing", file: file, line: line)
        XCTAssertTrue(isAcceptedTermsVersion(version ?? ""), "terms_version is not in the form the server accepts", file: file, line: line)
    }

    /// Box not ticked: neither key is sent. Not `age_declaration: false`, which the server refuses with a 400.
    private func assertNotDeclared(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(json["age_declaration"], "age_declaration must be absent", file: file, line: line)
        XCTAssertNil(json["terms_version"], "terms_version must be absent", file: file, line: line)
    }

    func testRegisterExtensionOnlyTickedSendsDeclarationAndTermsVersion() async throws {
        StubURLProtocol.stubResponse = (200, Data(okAuthJson.utf8))
        _ = try await makeApi().registerExtensionOnly(displayName: nil, email: "a@b.co",
                                                      inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ", ageDeclared: true)
        XCTAssertEqual(StubURLProtocol.lastRequestPath, "/api/v1/auth/register/extension")
        let json = try lastBodyJson()
        assertDeclared(json)
        // The declaration does not displace the fields the request already carried.
        XCTAssertEqual(json["email"] as? String, "a@b.co")
        XCTAssertEqual(json["invite_code"] as? String, "QA1-7K3M9-PXTVY-R2HN5-ZZ")
    }

    func testRegisterExtensionOnlyNotTickedSendsNeitherKey() async throws {
        StubURLProtocol.stubResponse = (200, Data(okAuthJson.utf8))
        _ = try await makeApi().registerExtensionOnly(displayName: nil, email: "a@b.co",
                                                      inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ", ageDeclared: false)
        assertNotDeclared(try lastBodyJson())
    }

    func testVerifyOtpRegisterTickedSendsDeclarationAndTermsVersion() async throws {
        StubURLProtocol.stubResponse = (200, Data(okAuthJson.utf8))
        _ = try await makeApi().verifyOtp(phoneNumber: "+14155552671", code: "123456", purpose: .register,
                                          deviceName: "iPhone", inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ",
                                          displayName: nil, ageDeclared: true)
        XCTAssertEqual(StubURLProtocol.lastRequestPath, "/api/v1/auth/otp/verify")
        let json = try lastBodyJson()
        XCTAssertEqual(json["purpose"] as? String, "register")
        assertDeclared(json)
        XCTAssertEqual(json["code"] as? String, "123456")
    }

    func testVerifyOtpRegisterNotTickedSendsNeitherKey() async throws {
        StubURLProtocol.stubResponse = (200, Data(okAuthJson.utf8))
        _ = try await makeApi().verifyOtp(phoneNumber: "+14155552671", code: "123456", purpose: .register,
                                          deviceName: "iPhone", inviteCode: "QA1-7K3M9-PXTVY-R2HN5-ZZ",
                                          displayName: nil, ageDeclared: false)
        assertNotDeclared(try lastBodyJson())
    }

    /// A login never carries the declaration, even if a caller hands one in.
    func testVerifyOtpLoginNeverSendsTheDeclaration() async throws {
        StubURLProtocol.stubResponse = (200, Data(okAuthJson.utf8))
        _ = try await makeApi().verifyOtp(phoneNumber: "+14155552671", code: "123456", purpose: .login,
                                          deviceName: "iPhone", inviteCode: nil, displayName: nil, ageDeclared: true)
        let json = try lastBodyJson()
        XCTAssertEqual(json["purpose"] as? String, "login")
        assertNotDeclared(json)
    }

    func testRegisterTickedSendsDeclarationAndTermsVersion() async throws {
        StubURLProtocol.stubResponse = (200, Data(#"{"user_id":"u-123"}"#.utf8))
        _ = try await makeApi().register(phoneNumber: "+14155552671", password: "pw", inviteCode: nil,
                                         displayName: nil, ageDeclared: true)
        XCTAssertEqual(StubURLProtocol.lastRequestPath, "/api/v1/register")
        let json = try lastBodyJson()
        assertDeclared(json)
        XCTAssertEqual(json["password"] as? String, "pw")
    }

    func testRegisterNotTickedSendsNeitherKey() async throws {
        StubURLProtocol.stubResponse = (200, Data(#"{"user_id":"u-123"}"#.utf8))
        _ = try await makeApi().register(phoneNumber: "+14155552671", password: "pw", inviteCode: nil,
                                         displayName: nil, ageDeclared: false)
        assertNotDeclared(try lastBodyJson())
    }

    // MARK: - Age declaration (register/sovereign)

    private let okSovereignJson = #"{"user_id":"u-1","challenge":"00ff"}"#

    func testRegisterSovereignTickedSendsDeclarationAndTermsVersion() async throws {
        StubURLProtocol.stubResponse = (200, Data(okSovereignJson.utf8))
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://test.local", displayName: "Anna")
        let result = try await manager.registerWithServer(identity: identity, rest: makeRest(), ageDeclared: true)
        XCTAssertEqual(result.userId, "u-1")
        XCTAssertEqual(StubURLProtocol.lastRequestPath, "/api/v1/register/sovereign")
        let json = try lastBodyJson()
        assertDeclared(json)
        // The declaration does not displace the fields the request already carried.
        XCTAssertEqual(json["display_name"] as? String, "Anna")
        XCTAssertEqual(json["server_url"] as? String, "https://test.local")
        XCTAssertEqual((json["signing_pub_key"] as? String)?.count, 64)
    }

    func testRegisterSovereignNotTickedSendsNeitherKey() async throws {
        StubURLProtocol.stubResponse = (200, Data(okSovereignJson.utf8))
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://test.local", displayName: nil)
        _ = try await manager.registerWithServer(identity: identity, rest: makeRest(), ageDeclared: false)
        XCTAssertEqual(StubURLProtocol.lastRequestPath, "/api/v1/register/sovereign")
        assertNotDeclared(try lastBodyJson())
    }

    /// A caller that says nothing about the declaration (the engine's demo UI) declares nothing.
    func testRegisterSovereignWithoutTheArgumentSendsNeitherKey() async throws {
        StubURLProtocol.stubResponse = (200, Data(okSovereignJson.utf8))
        let manager = SovereignIdentityManager()
        let identity = manager.generateIdentity(serverUrl: "https://test.local", displayName: nil)
        _ = try await manager.registerWithServer(identity: identity, rest: makeRest())
        assertNotDeclared(try lastBodyJson())
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
            // swiftlint:disable:next force_unwrapping - test-only stub intercepts only requests this test suite itself created against a hardcoded valid https://test.local base URL; request.url is always present.
            url: request.url!,
            statusCode: Self.stubResponse.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
            // swiftlint:disable:next force_unwrapping - HTTPURLResponse init with a literal "HTTP/1.1" version and small literal header dict never fails in practice; test-only stub.
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

import XCTest
@testable import QAudionEngine

private final class FixedInstallIdStorage: InstallIdStorage {
    var value: String? = "0b6f3c1e-2d4a-4b8e-9c10-5a7e8f9d0a1b"
    func read() -> String? { value }
    func write(_ value: String) { self.value = value }
    func delete() { value = nil }
}

/// Every sign-in request body carries `install_id`.
final class SignInInstallIdWireFormatTests: XCTestCase {
    private let expected = "0b6f3c1e-2d4a-4b8e-9c10-5a7e8f9d0a1b"

    override func setUp() {
        super.setUp()
        InstallIdStubURLProtocol.reset()
        URLProtocol.registerClass(InstallIdStubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(InstallIdStubURLProtocol.self)
        super.tearDown()
    }

    private func makeApi() -> BCryptoAccountApiImpl {
        let rest = BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local"), testURLProtocolClasses: [InstallIdStubURLProtocol.self])
        return BCryptoAccountApiImpl(rest: rest, installId: InstallIdStore(storage: FixedInstallIdStorage()))
    }

    private func lastJson() throws -> [String: Any] {
        let body = try XCTUnwrap(InstallIdStubURLProtocol.lastRequestBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private let authJson = Data(#"{"user_id":"u","access_token":"a","refresh_token":"r","expires_in":900}"#.utf8)

    func testLoginSendsInstallId() async throws {
        InstallIdStubURLProtocol.stubResponse = (200, authJson)
        _ = try? await makeApi().login(phoneHash: "h", password: "p", deviceName: "d")
        XCTAssertEqual(try lastJson()["install_id"] as? String, expected)
    }

    func testExtensionLoginSendsInstallId() async throws {
        InstallIdStubURLProtocol.stubResponse = (200, authJson)
        _ = try? await makeApi().loginWithExtension(extension: 1234, password: "p", deviceName: "d")
        XCTAssertEqual(try lastJson()["install_id"] as? String, expected)
    }

    func testRecoveryVerifySendsInstallId() async throws {
        InstallIdStubURLProtocol.stubResponse = (200, authJson)
        _ = try? await makeApi().recoveryVerify(identifier: "i", recoverySecret: "s", deviceName: "d")
        XCTAssertEqual(try lastJson()["install_id"] as? String, expected)
    }

    func testOtpVerifySendsInstallId() async throws {
        InstallIdStubURLProtocol.stubResponse = (200, authJson)
        _ = try? await makeApi().verifyOtp(phoneNumber: "+14155552671", code: "123456", purpose: .login, deviceName: "d",
                                           displayName: nil, ageDeclared: false, termsAcceptance: nil)
        XCTAssertEqual(try lastJson()["install_id"] as? String, expected)
    }
}

private final class InstallIdStubURLProtocol: URLProtocol {
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

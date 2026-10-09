import XCTest
@testable import QAudionEngine

/// Wire format of `PUT /api/v1/profile`: a field is present only when its
/// argument is non-nil, and an empty string is sent as an empty string.
final class BCryptoUpdateProfileWireFormatTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UpdateProfileStubURLProtocol.reset()
    }

    private func makeApi() -> BCryptoAccountApiImpl {
        let rest = BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://test.local"),
            testURLProtocolClasses: [UpdateProfileStubURLProtocol.self]
        )
        return BCryptoAccountApiImpl(rest: rest)
    }

    private func sentJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(UpdateProfileStubURLProtocol.lastRequestBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testEmptyStatusIsSentAsEmptyString() async throws {
        try await makeApi().updateProfile(displayName: nil, statusMessage: "", avatarUrl: nil)

        let json = try sentJSON()
        XCTAssertEqual(UpdateProfileStubURLProtocol.lastMethod, "PUT")
        XCTAssertTrue(json.keys.contains("status_message"))
        XCTAssertEqual(json["status_message"] as? String, "")
        XCTAssertNil(json["display_name"])
        XCTAssertNil(json["avatar_url"])
    }

    func testNilStatusKeyIsOmitted() async throws {
        try await makeApi().updateProfile(displayName: "Alice", statusMessage: nil, avatarUrl: nil)

        let json = try sentJSON()
        XCTAssertFalse(json.keys.contains("status_message"))
        XCTAssertEqual(json["display_name"] as? String, "Alice")
    }

    func testNonEmptyStatusIsSent() async throws {
        try await makeApi().updateProfile(displayName: nil, statusMessage: "Ciao", avatarUrl: nil)

        XCTAssertEqual(try sentJSON()["status_message"] as? String, "Ciao")
    }
}

// MARK: - URLProtocol stub

private final class UpdateProfileStubURLProtocol: URLProtocol {
    static var lastRequestBody: Data?
    static var lastMethod: String?

    static func reset() {
        lastRequestBody = nil
        lastMethod = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastMethod = request.httpMethod
        if let body = request.httpBody {
            Self.lastRequestBody = body
        } else if let stream = request.httpBodyStream {
            Self.lastRequestBody = Self.readStream(stream)
        }
        // swiftlint:disable:next force_unwrapping - test-only stub; request.url is always present for requests built against the literal base URL.
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
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

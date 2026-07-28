import XCTest
@testable import QAudionEngine

/// Wire-format guard for `POST /api/v1/contacts/sync` and
/// `GET /api/v1/contacts/blocked`. The shapes must match Android
/// `SyncContactsRequest` / `BlockedContactsResponse` byte-for-byte
/// (see `core/core-data/.../dto/ContactsDto.kt`).
///
/// Original drift findings: `docs/progress/PHASE1_REST_AUDIT.md` §3.4 / §3.5.
final class BCryptoContactsWireFormatTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ContactsStubURLProtocol.reset()
        URLProtocol.registerClass(ContactsStubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ContactsStubURLProtocol.self)
        super.tearDown()
    }

    // MARK: - syncContacts

    func testSyncContactsSendsContactsArrayUnderContactsKey() async throws {
        ContactsStubURLProtocol.stubResponse = (200, Data("{}".utf8))
        let api = BCryptoContactsApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        try await api.syncContacts(entries: [
            SyncContactEntry(contactUserId: "u-1", displayName: "Alice", localAlias: "Al"),
            SyncContactEntry(contactUserId: "u-2"),
        ])

        let body = try XCTUnwrap(ContactsStubURLProtocol.lastRequestBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Must not use the legacy `phone_hashes` key — server expects `contacts`.
        XCTAssertNil(json["phone_hashes"], "syncContacts must not send `phone_hashes`")
        let contacts = try XCTUnwrap(json["contacts"] as? [[String: Any]])
        XCTAssertEqual(contacts.count, 2)

        XCTAssertEqual(contacts[0]["contact_user_id"] as? String, "u-1")
        XCTAssertEqual(contacts[0]["display_name"] as? String, "Alice")
        XCTAssertEqual(contacts[0]["local_alias"] as? String, "Al")

        XCTAssertEqual(contacts[1]["contact_user_id"] as? String, "u-2")
        XCTAssertNil(contacts[1]["display_name"])
        XCTAssertNil(contacts[1]["local_alias"])
    }

    // MARK: - getBlockedContacts

    func testGetBlockedContactsDecodesBlockedArray() async throws {
        let payload = #"""
        {"blocked":[{"user_id":"u-42","blocked_at":"2026-04-20T10:00:00Z"},{"user_id":"u-77"}]}
        """#
        ContactsStubURLProtocol.stubResponse = (200, Data(payload.utf8))
        let api = BCryptoContactsApiImpl(rest: BCryptoRestClient(config: BackendConfig(serverUrl: "https://test.local")))

        let result = try await api.getBlockedContacts()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].userId, "u-42")
        XCTAssertEqual(result[0].blockedAt, "2026-04-20T10:00:00Z")
        XCTAssertEqual(result[1].userId, "u-77")
        XCTAssertNil(result[1].blockedAt)
    }
}

// MARK: - URLProtocol stub

private final class ContactsStubURLProtocol: URLProtocol {
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

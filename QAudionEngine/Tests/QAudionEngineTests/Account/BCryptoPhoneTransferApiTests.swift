import XCTest
@testable import QAudionEngine

final class BCryptoPhoneTransferApiTests: XCTestCase {

    override func tearDown() {
        PhoneTransferStubProtocol.responseHandler = nil
        PhoneTransferStubProtocol.recorded = []
        super.tearDown()
    }

    private func makeApi() -> BCryptoPhoneTransferApi {
        let config = BackendConfig(serverUrl: "https://server.test", accessToken: "tok")
        let client = BCryptoRestClient(config: config, testURLProtocolClasses: [PhoneTransferStubProtocol.self])
        let api = BCryptoPhoneTransferApi()
        api.getRestClient = { client }
        return api
    }

    private static func respond(_ request: URLRequest, status: Int, body: String = "{}") -> (HTTPURLResponse, Data?) {
        // swiftlint:disable:next force_unwrapping
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, Data(body.utf8))
    }

    func test_fetchPending_readsIdAndExpiry_ignoringCreatedAt() async throws {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 200, body: """
            {"transfers":[{"id":"t-1","created_at":"2026-10-09T10:00:00Z","expires_at":"2026-10-11T10:00:00Z"}]}
            """)
        }
        let list = try await makeApi().fetchPending()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.id, "t-1")
        XCTAssertEqual(list.first?.expiresAt, Date(timeIntervalSince1970: 1_791_712_800))
        XCTAssertEqual(PhoneTransferStubProtocol.recorded.first?.method, "GET")
        XCTAssertEqual(PhoneTransferStubProtocol.recorded.first?.path, "/api/v1/account/phone-transfers")
    }

    func test_fetchPending_keepsAnEntryWhoseExpiryIsInThePast() async throws {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 200, body: "{\"transfers\":[{\"id\":\"old\",\"expires_at\":\"2001-01-01T00:00:00Z\"}]}")
        }
        let list = try await makeApi().fetchPending()
        XCTAssertEqual(list.map(\.id), ["old"], "only the server decides when a transfer is gone")
    }

    func test_fetchPending_emptyList() async throws {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 200, body: "{\"transfers\":[]}")
        }
        let list = try await makeApi().fetchPending()
        XCTAssertTrue(list.isEmpty)
    }

    func test_fetchPending_skipsAnEntryWithAnUnreadableDate() async throws {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 200, body: """
            {"transfers":[{"id":"bad","expires_at":"soon"},{"id":"ok","expires_at":"2026-10-11T10:00:00Z"}]}
            """)
        }
        let list = try await makeApi().fetchPending()
        XCTAssertEqual(list.map(\.id), ["ok"])
    }

    func test_fetchPending_404_isAnEmptyList() async throws {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 404)
        }
        let list = try await makeApi().fetchPending()
        XCTAssertTrue(list.isEmpty)
    }

    func test_fetchPending_serverError_isThrown() async {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 503)
        }
        do {
            _ = try await makeApi().fetchPending()
            XCTFail("expected an error")
        } catch let error as BCryptoError {
            guard case .httpError(503) = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_fetchPending_withoutAClient_isUnauthorized() async {
        let api = BCryptoPhoneTransferApi()
        do {
            _ = try await api.fetchPending()
            XCTFail("expected an error")
        } catch let error as BCryptoError {
            guard case .unauthorized = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_cancel_postsToTheCancelPath() async throws {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 200, body: "{\"status\":\"cancelled\"}")
        }
        try await makeApi().cancel(id: "t-1")
        XCTAssertEqual(PhoneTransferStubProtocol.recorded.count, 1)
        XCTAssertEqual(PhoneTransferStubProtocol.recorded.first?.method, "POST")
        XCTAssertEqual(PhoneTransferStubProtocol.recorded.first?.path, "/api/v1/account/phone-transfers/t-1/cancel")
    }

    func test_cancel_404_isThrown() async {
        PhoneTransferStubProtocol.responseHandler = { request in
            Self.respond(request, status: 404)
        }
        do {
            try await makeApi().cancel(id: "t-1")
            XCTFail("expected an error")
        } catch let error as BCryptoError {
            guard case .httpError(404) = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_cancelPath_escapesTheId() {
        XCTAssertEqual(BCryptoPhoneTransferApi.cancelPath(id: "a/b c"),
                       "/api/v1/account/phone-transfers/a%2Fb%20c/cancel")
    }

    func test_parseDate_acceptsFractionalSecondsAndOffsets() {
        XCTAssertNotNil(BCryptoPhoneTransferApi.parseDate("2026-10-11T10:00:00.250Z"))
        XCTAssertNotNil(BCryptoPhoneTransferApi.parseDate("2026-10-11T10:00:00+02:00"))
        XCTAssertNil(BCryptoPhoneTransferApi.parseDate("11/10/2026"))
    }
}

private final class PhoneTransferStubProtocol: URLProtocol {
    static var responseHandler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    static var recorded: [(method: String, path: String)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        PhoneTransferStubProtocol.recorded.append((request.httpMethod ?? "", request.url?.path ?? ""))
        guard let handler = PhoneTransferStubProtocol.responseHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

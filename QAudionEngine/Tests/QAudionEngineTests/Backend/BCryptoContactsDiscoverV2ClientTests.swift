import XCTest
@testable import QAudionEngine

final class BCryptoContactsDiscoverV2ClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        StubProtocol.responseHandler = nil
        super.tearDown()
    }

    func test_fetchPepper_decodesResponse() async throws {
        StubProtocol.responseHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "{\"pepper\":\"global-pepper-xyz\"}".data(using: .utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { "token123" }
        )
        let pepper = try await client.fetchPepper()
        XCTAssertEqual(pepper, "global-pepper-xyz")
    }

    func test_fetchPepper_emptyPepperThrows() async {
        StubProtocol.responseHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "{\"pepper\":\"\"}".data(using: .utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { nil }
        )
        do {
            _ = try await client.fetchPepper()
            XCTFail("Should have thrown")
        } catch BCryptoContactsDiscoverV2Client.Error.missingPepper {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_discover_decodesWrappedShape() async throws {
        StubProtocol.responseHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "{\"results\":[{\"hash\":\"abc\",\"user_id\":\"u-1\"},{\"hash\":\"def\"}]}".data(using: .utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { "token123" }
        )
        let entries = try await client.discover(hashes: ["abc", "def"])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].userId, "u-1")
        XCTAssertNil(entries[1].userId)
    }

    func test_discover_decodesBareArray() async throws {
        StubProtocol.responseHandler = { _ in
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             "[{\"hash\":\"x\",\"user_id\":\"u-x\"}]".data(using: .utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { nil }
        )
        let entries = try await client.discover(hashes: ["x"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].userId, "u-x")
    }
}

private final class StubProtocol: URLProtocol {
    static var responseHandler: ((URLRequest) -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubProtocol.responseHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (resp, data) = handler(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let data = data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

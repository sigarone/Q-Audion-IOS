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
        // "global-pepper-xyz" in base64 — fetchPepper() decodes it to Data
        let pepperB64 = Data("global-pepper-xyz".utf8).base64EncodedString()
        StubProtocol.responseHandler = { _ in
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"pepper\":\"\(pepperB64)\"}".utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { "token123" }
        )
        let bundle = try await client.fetchPepper()
        XCTAssertEqual(bundle.pepperBytes, Data("global-pepper-xyz".utf8))
        XCTAssertEqual(bundle.alg, "sha256")
    }

    func test_fetchPepper_emptyPepperThrows() async {
        StubProtocol.responseHandler = { _ in
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"pepper\":\"\"}".utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
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
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"results\":[{\"hash\":\"abc\",\"user_id\":\"u-1\"},{\"hash\":\"def\"}]}".utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
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
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("[{\"hash\":\"x\",\"user_id\":\"u-x\"}]".utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            // Hardcoded literal URL string — always parses.
            // swiftlint:disable:next force_unwrapping
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

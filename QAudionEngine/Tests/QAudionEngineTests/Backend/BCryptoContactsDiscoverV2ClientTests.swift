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

    // 2026-07-30 fix (real device evidence: dialing a registered E.164 from
    // the iPhone keypad failed with "decoding failed: typeMismatch expected
    // value type array") — these two tests used to assert a wire shape
    // (`{"results":[{"hash","user_id"}]}` / a bare top-level array) that
    // NEVER matched what `cmd/bcrypto-lite/main.go`'s handleDiscoverContactsV2
    // actually sends (`{"contacts":[{"id","user_id","phone_hash",
    // "display_name","avatar_url","status_message"}]}`) — they gave false
    // confidence in a contract that was wrong from day one. Replaced with
    // the REAL shape, mirroring Android's DiscoveredContactDto exactly.

    func test_discover_decodesRealServerShape() async throws {
        StubProtocol.responseHandler = { _ in
            // Hardcoded literal URL/status — HTTPURLResponse init cannot fail here.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("""
             {"contacts":[
               {"id":"u-1","user_id":"u-1","phone_hash":"ph-1","display_name":"Marta Rinaldi","avatar_url":"https://x/a.png","status_message":"Ciao"},
               {"id":"u-2","user_id":"u-2","phone_hash":"ph-2","display_name":""}
             ]}
             """.utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { "token123" }
        )
        let entries = try await client.discover(alg: "sha256-peppered-v1", hashes: ["ph-1", "ph-2"])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].userId, "u-1")
        XCTAssertEqual(entries[0].displayName, "Marta Rinaldi")
        XCTAssertEqual(entries[0].phoneHash, "ph-1")
        XCTAssertEqual(entries[1].userId, "u-2")
    }

    func test_discover_emptyContactsArray_decodesToEmpty() async throws {
        StubProtocol.responseHandler = { _ in
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("{\"contacts\":[]}".utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { nil }
        )
        let entries = try await client.discover(alg: "sha256-peppered-v1", hashes: ["nope"])
        XCTAssertTrue(entries.isEmpty)
    }

    func test_discover_unexpectedShape_throwsDecodingFailed() async {
        StubProtocol.responseHandler = { _ in
            // A bare array (the OLD, wrong assumption) must NOT silently
            // decode — the real server never sends this shape, so treating
            // it as valid would just reintroduce a different silent bug.
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: URL(string: "https://test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("[{\"user_id\":\"u-x\"}]".utf8))
        }
        let client = BCryptoContactsDiscoverV2Client(
            baseUrl: URL(string: "https://test")!,
            session: session,
            bearerTokenProvider: { nil }
        )
        do {
            _ = try await client.discover(alg: "sha256-peppered-v1", hashes: ["x"])
            XCTFail("Should have thrown decodingFailed")
        } catch BCryptoContactsDiscoverV2Client.Error.decodingFailed {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
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

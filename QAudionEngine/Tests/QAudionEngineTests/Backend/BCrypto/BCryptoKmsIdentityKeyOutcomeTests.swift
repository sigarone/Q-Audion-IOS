import XCTest
@testable import QAudionEngine

/// `BCryptoKmsClient.fetchUserIdentityKeyOutcome` tells "the peer has not
/// published an identity key" (HTTP 404, a final answer) apart from "the
/// request failed" (retriable), which the nil-returning
/// `fetchUserIdentityKey` cannot. The contact-detail safety-number card needs
/// that difference: a failed fetch used to be flattened into "unverified" and
/// shown as an endless "Calcolo del trust in corso…" (bug reports 2548ffa3,
/// 3b24290e).
///
/// Also pins that the nil-returning wrapper (the call handshake's trust source)
/// behaves exactly as before: a key for a key, nil for everything else.
final class BCryptoKmsIdentityKeyOutcomeTests: XCTestCase {

    private let userId = "11111111-2222-3333-4444-555555555555"

    override func tearDown() {
        IdentityKeyStubProtocol.handler = nil
        IdentityKeyStubProtocol.requestedPaths = []
        super.tearDown()
    }

    private func makeClient() -> BCryptoKmsClient {
        let config = BackendConfig(serverUrl: "https://kms.test", accessToken: "tok")
        let rest = BCryptoRestClient(config: config, testURLProtocolClasses: [IdentityKeyStubProtocol.self])
        return BCryptoKmsClient(rest: rest)
    }

    private func respond(status: Int, body: Data = Data("{}".utf8)) {
        IdentityKeyStubProtocol.handler = { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"])
            else { return .failure(URLError(.badServerResponse)) }
            return .response(response, body)
        }
    }

    private func keyBody(_ key: Data, field: String = "ed25519_pub_b64") -> Data {
        Data("{\"\(field)\":\"\(key.base64EncodedString())\"}".utf8)
    }

    // MARK: - Outcome

    func test_outcome_200WithKey_returnsTheKey() async {
        let key = Data((0..<32).map { UInt8($0) })
        respond(status: 200, body: keyBody(key))
        let outcome = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
        XCTAssertEqual(outcome, .key(key))
    }

    func test_outcome_acceptsTheLegacyPublicKeyField() async {
        let key = Data(repeating: 9, count: 32)
        respond(status: 200, body: keyBody(key, field: "public_key_b64"))
        let outcome = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
        XCTAssertEqual(outcome, .key(key))
    }

    func test_outcome_404_isNotPublished_aFinalAnswer() async {
        respond(status: 404)
        let outcome = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
        XCTAssertEqual(outcome, .notPublished)
    }

    func test_outcome_serverError_isFailed_notNotPublished() async {
        for status in [500, 502, 503, 429] {
            respond(status: status)
            let outcome = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
            XCTAssertEqual(outcome, .failed, "HTTP \(status)")
        }
    }

    func test_outcome_transportError_isFailed() async {
        IdentityKeyStubProtocol.handler = { _ in .failure(URLError(.networkConnectionLost)) }
        let outcome = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
        XCTAssertEqual(outcome, .failed)
    }

    func test_outcome_unusableBody_isFailed() async {
        respond(status: 200, body: Data("not json".utf8))
        let garbage = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
        XCTAssertEqual(garbage, .failed)

        respond(status: 200, body: Data("{}".utf8))
        let missing = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
        XCTAssertEqual(missing, .failed)

        respond(status: 200, body: keyBody(Data(repeating: 1, count: 31)))
        let short = await makeClient().fetchUserIdentityKeyOutcome(userId: userId)
        XCTAssertEqual(short, .failed, "a partial key must never be returned")
    }

    func test_outcome_emptyUserId_isFailed_andMakesNoRequest() async {
        respond(status: 200, body: keyBody(Data(repeating: 1, count: 32)))
        let outcome = await makeClient().fetchUserIdentityKeyOutcome(userId: "")
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(IdentityKeyStubProtocol.requestedPaths.isEmpty)
    }

    func test_outcome_deviceId_isAppendedAsQuery() async {
        respond(status: 200, body: keyBody(Data(repeating: 2, count: 32)))
        _ = await makeClient().fetchUserIdentityKeyOutcome(userId: userId, deviceId: "dev 1")
        XCTAssertEqual(IdentityKeyStubProtocol.requestedPaths.last,
                       "/api/v1/users/\(userId)/identity-key?device_id=dev%201")
    }

    // MARK: - The nil-returning wrapper is unchanged

    func test_wrapper_returnsTheKey_andNilForEveryNonKeyOutcome() async {
        let key = Data(repeating: 5, count: 32)
        respond(status: 200, body: keyBody(key))
        let found = await makeClient().fetchUserIdentityKey(userId: userId)
        XCTAssertEqual(found, key)

        respond(status: 404)
        let notPublished = await makeClient().fetchUserIdentityKey(userId: userId)
        XCTAssertNil(notPublished)

        respond(status: 500)
        let failed = await makeClient().fetchUserIdentityKey(userId: userId)
        XCTAssertNil(failed)

        respond(status: 200, body: keyBody(key))
        let perDevice = await makeClient().fetchUserIdentityKey(userId: userId, deviceId: "d")
        XCTAssertEqual(perDevice, key)
    }
}

/// URLProtocol stub for the identity-key endpoint.
private final class IdentityKeyStubProtocol: URLProtocol {
    enum Reply {
        case response(HTTPURLResponse, Data)
        case failure(Error)
    }

    static var handler: ((URLRequest) -> Reply)?
    static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            var path = url.path
            if let query = url.query { path += "?" + query }
            IdentityKeyStubProtocol.requestedPaths.append(path)
        }
        guard let handler = IdentityKeyStubProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch handler(request) {
        case .response(let response, let data):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

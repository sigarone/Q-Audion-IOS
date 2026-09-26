import XCTest
@testable import QAudionEngine

/// Chunked sending of `POST /api/v1/contacts/discover-v2` lookups.
///
/// Same seam as `BCryptoContactsDiscoverV2ClientTests`: a `URLProtocol` stub
/// injected through the client's `URLSession`. The stub also records every
/// request (body hashes included) so the tests can assert how many requests went
/// out and how large each one was.
final class BCryptoContactsDiscoverV2ChunkingTests: XCTestCase {

    typealias Client = BCryptoContactsDiscoverV2Client

    override func setUp() {
        super.setUp()
        DiscoverChunkStubProtocol.reset()
    }

    override func tearDown() {
        DiscoverChunkStubProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient() throws -> Client {
        let url: URL = try XCTUnwrap(URL(string: "https://test"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiscoverChunkStubProtocol.self]
        let session = URLSession(configuration: config)
        return Client(baseUrl: url, session: session, bearerTokenProvider: { "token123" })
    }

    private func makeHashes(_ count: Int) -> [String] {
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append("h\(i)")
        }
        return out
    }

    /// Number of hashes in each request the stub saw, in order.
    private func chunkSizes() -> [Int] {
        var sizes: [Int] = []
        for request in DiscoverChunkStubProtocol.requests() {
            sizes.append(request.hashes.count)
        }
        return sizes
    }

    /// Every hash the stub saw, request after request.
    private func allSentHashes() -> [String] {
        var sent: [String] = []
        for request in DiscoverChunkStubProtocol.requests() {
            sent.append(contentsOf: request.hashes)
        }
        return sent
    }

    private func userIds(_ outcome: Client.DiscoverOutcome) -> [String] {
        var ids: [String] = []
        for entry in outcome.entries {
            ids.append(entry.userId)
        }
        return ids
    }

    // MARK: - Request count and chunk sizes

    func test_emptyList_sendsNoRequest() async throws {
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: [])
        XCTAssertEqual(chunkSizes(), [])
        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertEqual(outcome.totalHashes, 0)
        XCTAssertEqual(outcome.processedHashes, 0)
        XCTAssertEqual(outcome.requestCount, 0)
        XCTAssertTrue(outcome.isComplete)
        XCTAssertNil(outcome.stopReason)
    }

    func test_oneHash_isOneRequestOfOne() async throws {
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(1))
        XCTAssertEqual(chunkSizes(), [1])
        XCTAssertEqual(outcome.requestCount, 1)
        XCTAssertEqual(outcome.processedHashes, 1)
        XCTAssertTrue(outcome.isComplete)
    }

    func test_exactlyOneChunk_isOneRequestOf500() async throws {
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(500))
        XCTAssertEqual(chunkSizes(), [500])
        XCTAssertEqual(outcome.requestCount, 1)
        XCTAssertEqual(outcome.processedHashes, 500)
        XCTAssertTrue(outcome.isComplete)
    }

    func test_oneOverTheLimit_isTwoRequests() async throws {
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(501))
        XCTAssertEqual(chunkSizes(), [500, 1])
        XCTAssertEqual(outcome.requestCount, 2)
        XCTAssertEqual(outcome.processedHashes, 501)
        XCTAssertTrue(outcome.isComplete)
    }

    func test_1200Hashes_areThreeRequestsInOrder() async throws {
        let client = try makeClient()
        let hashes = makeHashes(1200)
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: hashes)
        XCTAssertEqual(chunkSizes(), [500, 500, 200])
        XCTAssertEqual(allSentHashes(), hashes)
        XCTAssertEqual(outcome.totalHashes, 1200)
        XCTAssertEqual(outcome.processedHashes, 1200)
        XCTAssertEqual(outcome.pendingHashes, 0)
        XCTAssertTrue(outcome.unprocessedHashes.isEmpty)
        XCTAssertTrue(outcome.isComplete)
    }

    func test_customChunkSize_isHonoured_andNeverBelowOne() async throws {
        let client = try makeClient()
        _ = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(5), chunkSize: 2)
        XCTAssertEqual(chunkSizes(), [2, 2, 1])

        DiscoverChunkStubProtocol.reset()
        _ = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(3), chunkSize: 0)
        XCTAssertEqual(chunkSizes(), [1, 1, 1])
    }

    /// A caller-supplied size above the server's per-request limit is clamped to it,
    /// so no request ever carries more than `maxHashesPerRequest` hashes.
    func test_oversizedChunkSize_isClampedToTheRequestLimit() async throws {
        let client = try makeClient()
        _ = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(1200), chunkSize: 100_000)
        XCTAssertEqual(chunkSizes(), [500, 500, 200])
    }

    // MARK: - Wire format

    func test_wireFormat_isUnchanged() async throws {
        let client = try makeClient()
        let hashes = makeHashes(3)
        _ = try await client.discoverChunked(alg: "sha256-peppered-v1", hashes: hashes)
        let requests = DiscoverChunkStubProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        guard let request = requests.first else { return }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/contacts/discover-v2")
        XCTAssertEqual(request.authorization, "Bearer token123")
        XCTAssertEqual(request.contentType, "application/json")
        XCTAssertEqual(request.bodyKeys, ["alg", "hashes"])
        XCTAssertEqual(request.alg, "sha256-peppered-v1")
        XCTAssertEqual(request.hashes, hashes)
    }

    func test_discover_isOneRequestForASmallList() async throws {
        let client = try makeClient()
        let hashes = makeHashes(2)
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let entries = try await client.discover(alg: "sha256", hashes: hashes)
        XCTAssertEqual(chunkSizes(), [2])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.userId, "u-h0")
    }

    // MARK: - Results merged in order

    func test_results_areMergedInRequestOrder() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(1200))
        XCTAssertEqual(userIds(outcome), ["u-h0", "u-h500", "u-h1000"])
    }

    func test_discover_returnsTheConcatenatedResults() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let client = try makeClient()
        let entries = try await client.discover(alg: "sha256", hashes: makeHashes(1200))
        XCTAssertEqual(chunkSizes(), [500, 500, 200])
        var ids: [String] = []
        for entry in entries {
            ids.append(entry.userId)
        }
        XCTAssertEqual(ids, ["u-h0", "u-h500", "u-h1000"])
    }

    // MARK: - HTTP 429

    func test_429_stopsTheLoop_andKeepsTheProgress() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            if index == 1 {
                return DiscoverChunkStubProtocol.rateLimitedReply(retryAfter: "7")
            }
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(1200))

        // The third chunk is never sent.
        XCTAssertEqual(chunkSizes(), [500, 500])
        XCTAssertEqual(outcome.requestCount, 2)
        // What chunk 1 returned is kept.
        XCTAssertEqual(userIds(outcome), ["u-h0"])
        XCTAssertEqual(outcome.processedHashes, 500)
        XCTAssertEqual(outcome.pendingHashes, 700)
        // The rate-limited chunk and the chunk that was never sent, in request order.
        XCTAssertEqual(outcome.unprocessedHashes.count, 700)
        XCTAssertEqual(outcome.unprocessedHashes.first, "h500")
        XCTAssertEqual(outcome.unprocessedHashes.last, "h1199")
        XCTAssertFalse(outcome.isComplete)
        XCTAssertTrue(outcome.wasRateLimited)
        let expected: Client.DiscoverStopReason? = .rateLimited(retryAfterSeconds: 7)
        XCTAssertEqual(outcome.stopReason, expected)
        XCTAssertEqual(outcome.retryAfterSeconds ?? -1, 7, accuracy: 0.0001)
    }

    func test_429_withoutRetryAfter_reportsNoWait() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            if index == 1 {
                return DiscoverChunkStubProtocol.rateLimitedReply(retryAfter: nil)
            }
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(600))
        XCTAssertTrue(outcome.wasRateLimited)
        XCTAssertNil(outcome.retryAfterSeconds)
        XCTAssertEqual(outcome.processedHashes, 500)
        XCTAssertEqual(outcome.pendingHashes, 100)
    }

    func test_429_onTheFirstChunk_isReportedNotThrown() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.rateLimitedReply(retryAfter: "60")
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(1200))
        XCTAssertEqual(chunkSizes(), [500])
        XCTAssertTrue(outcome.entries.isEmpty)
        XCTAssertEqual(outcome.processedHashes, 0)
        XCTAssertEqual(outcome.pendingHashes, 1200)
        XCTAssertTrue(outcome.wasRateLimited)
        XCTAssertEqual(outcome.retryAfterSeconds ?? -1, 60, accuracy: 0.0001)
    }

    func test_discover_stillThrowsOn429() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            if index == 1 {
                return DiscoverChunkStubProtocol.rateLimitedReply(retryAfter: "7")
            }
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let client = try makeClient()
        do {
            _ = try await client.discover(alg: "sha256", hashes: makeHashes(1200))
            XCTFail("discover(alg:hashes:) must throw on a 429")
        } catch Client.Error.httpError(let code) {
            XCTAssertEqual(code, 429)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(chunkSizes(), [500, 500])
    }

    // MARK: - Other failures

    func test_failureOfTheFirstChunk_isThrown() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.errorReply(status: 500)
        }
        let client = try makeClient()
        do {
            _ = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(600))
            XCTFail("Should have thrown")
        } catch Client.Error.httpError(let code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(chunkSizes(), [500])
    }

    func test_failureAfterAnAnsweredChunk_keepsTheProgress() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            if index == 1 {
                return DiscoverChunkStubProtocol.errorReply(status: 500)
            }
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(1200))
        XCTAssertEqual(chunkSizes(), [500, 500])
        XCTAssertEqual(userIds(outcome), ["u-h0"])
        XCTAssertEqual(outcome.processedHashes, 500)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertFalse(outcome.wasRateLimited)
        guard let reason = outcome.stopReason else {
            XCTFail("Expected a stop reason")
            return
        }
        if case .failed(let message) = reason {
            XCTAssertTrue(message.contains("500"), "message was: " + message)
        } else {
            XCTFail("Expected .failed, got a different reason")
        }
    }

    // MARK: - Old and new server answers

    func test_oldServerAnswer_withoutTheNewFields_decodes() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.okReply(sent)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(600))
        XCTAssertEqual(outcome.entries.count, 2)
        XCTAssertEqual(outcome.processedHashes, 600)
        XCTAssertFalse(outcome.serverTruncated)
        XCTAssertNil(outcome.stopReason)
        XCTAssertTrue(outcome.isComplete)
    }

    func test_newServerAnswer_completePass_decodes() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            let extra: String = #","truncated":false,"processed":\#(sent.count)"#
            return DiscoverChunkStubProtocol.okReply(sent, extra: extra)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(600))
        XCTAssertEqual(outcome.entries.count, 2)
        XCTAssertEqual(outcome.processedHashes, 600)
        XCTAssertFalse(outcome.serverTruncated)
        XCTAssertTrue(outcome.isComplete)
    }

    func test_newServerAnswer_truncated_isReportedAsPartial() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            let extra: String = #","truncated":true,"processed":100"#
            return DiscoverChunkStubProtocol.okReply(sent, extra: extra)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(300))
        XCTAssertEqual(chunkSizes(), [300])
        XCTAssertEqual(outcome.entries.count, 1)
        XCTAssertEqual(outcome.processedHashes, 100)
        XCTAssertEqual(outcome.pendingHashes, 200)
        // The server processed the first 100 hashes of the chunk.
        XCTAssertEqual(outcome.unprocessedHashes.count, 200)
        XCTAssertEqual(outcome.unprocessedHashes.first, "h100")
        XCTAssertEqual(outcome.unprocessedHashes.last, "h299")
        XCTAssertTrue(outcome.serverTruncated)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertNil(outcome.stopReason)
    }

    func test_truncatedWithoutProcessed_confirmsNothingOfThatChunk() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.okReply(sent, extra: #","truncated":true"#)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(300))
        XCTAssertTrue(outcome.serverTruncated)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.processedHashes, 0)
        XCTAssertEqual(outcome.pendingHashes, 300)
        // The contacts the server did return are still kept.
        XCTAssertEqual(outcome.entries.count, 1)
    }

    func test_processed_isClampedToWhatWasSent() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            if index == 0 {
                return DiscoverChunkStubProtocol.okReply(sent, extra: #","processed":9999"#)
            }
            return DiscoverChunkStubProtocol.okReply(sent, extra: #","processed":-5"#)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(510))
        XCTAssertEqual(chunkSizes(), [500, 10])
        // 500 (clamped down from 9999) + 0 (clamped up from -5).
        XCTAssertEqual(outcome.processedHashes, 500)
        XCTAssertEqual(outcome.pendingHashes, 10)
    }

    func test_unknownAndMistypedFields_neverFailTheDecode() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            let text: String = #"""
            {"contacts":[{"user_id":"u-1","phone_hash":"ph-1","future_field":123}],
             "truncated":"maybe","processed":"lots","budget":{"remaining":5},"note":null}
            """#
            return StubReply(status: 200, headers: [:], body: Data(text.utf8))
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(3))
        XCTAssertEqual(userIds(outcome), ["u-1"])
        // The mistyped values are ignored, as if the server had not sent them.
        XCTAssertFalse(outcome.serverTruncated)
        XCTAssertEqual(outcome.processedHashes, 3)
        XCTAssertTrue(outcome.isComplete)
    }

    func test_nullNewFields_areTreatedAsAbsent() async throws {
        DiscoverChunkStubProtocol.setProvider { (index: Int, sent: [String]) -> StubReply in
            return DiscoverChunkStubProtocol.okReply(sent, extra: #","truncated":null,"processed":null"#)
        }
        let client = try makeClient()
        let outcome = try await client.discoverChunked(alg: "sha256", hashes: makeHashes(4))
        XCTAssertFalse(outcome.serverTruncated)
        XCTAssertEqual(outcome.processedHashes, 4)
        XCTAssertTrue(outcome.isComplete)
    }
}

// MARK: - URLProtocol stub

private struct RecordedDiscoverRequest {
    let method: String
    let path: String
    let authorization: String?
    let contentType: String?
    let bodyKeys: [String]
    let alg: String?
    let hashes: [String]
}

private struct StubReply {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class DiscoverChunkStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedRequests: [RecordedDiscoverRequest] = []
    private static var storedProvider: ((Int, [String]) -> StubReply)?

    // MARK: State

    static func reset() {
        lock.lock()
        storedRequests = []
        storedProvider = nil
        lock.unlock()
    }

    static func setProvider(_ provider: @escaping (Int, [String]) -> StubReply) {
        lock.lock()
        storedProvider = provider
        lock.unlock()
    }

    static func requests() -> [RecordedDiscoverRequest] {
        lock.lock()
        let copy: [RecordedDiscoverRequest] = storedRequests
        lock.unlock()
        return copy
    }

    private static func currentProvider() -> ((Int, [String]) -> StubReply)? {
        lock.lock()
        let provider: ((Int, [String]) -> StubReply)? = storedProvider
        lock.unlock()
        return provider
    }

    /// Appends the request and returns its zero-based index.
    private static func record(_ item: RecordedDiscoverRequest) -> Int {
        lock.lock()
        let index: Int = storedRequests.count
        storedRequests.append(item)
        lock.unlock()
        return index
    }

    // MARK: Replies

    /// 200 with one contact per request, keyed on the request's first hash
    /// (`u-<hash>`), so the merged order of several chunks can be asserted.
    static func okReply(_ hashes: [String], extra: String = "") -> StubReply {
        var item: String = ""
        if let first = hashes.first {
            item = #"{"user_id":"u-\#(first)","phone_hash":"\#(first)"}"#
        }
        let text: String = #"{"contacts":[\#(item)]\#(extra)}"#
        return StubReply(status: 200, headers: [:], body: Data(text.utf8))
    }

    static func rateLimitedReply(retryAfter: String?) -> StubReply {
        var headers: [String: String] = [:]
        if let value = retryAfter {
            headers["Retry-After"] = value
        }
        let text: String = #"{"error":"discovery rate limit exceeded"}"#
        return StubReply(status: 429, headers: headers, body: Data(text.utf8))
    }

    static func errorReply(status: Int) -> StubReply {
        let text: String = #"{"error":"boom"}"#
        return StubReply(status: status, headers: [:], body: Data(text.utf8))
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands the body to a URLProtocol as `httpBodyStream`, not `httpBody`.
        let bodyData: Data = DiscoverChunkStubProtocol.bodyData(of: request)
        var alg: String?
        var hashes: [String] = []
        var keys: [String] = []
        let parsed: Any? = try? JSONSerialization.jsonObject(with: bodyData)
        if let object = parsed as? [String: Any] {
            keys = object.keys.sorted()
            alg = object["alg"] as? String
            hashes = (object["hashes"] as? [String]) ?? []
        }
        let item = RecordedDiscoverRequest(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            bodyKeys: keys,
            alg: alg,
            hashes: hashes
        )
        let index: Int = DiscoverChunkStubProtocol.record(item)

        var reply: StubReply = DiscoverChunkStubProtocol.okReply([])
        if let provider = DiscoverChunkStubProtocol.currentProvider() {
            reply = provider(index, hashes)
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: reply.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -2))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        var data = Data()
        stream.open()
        defer { stream.close() }
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

import XCTest
@testable import QAudionEngine

/// Item A-iOS + G (2026-09-30 file-transfer plan, phase 1a).
///
/// Two things pinned here:
///   - **G — node selection for file endpoints**: `getFileEndpoint` /
///     `postToPrimary` must always hit the certificate-pinned primary this
///     client was CONSTRUCTED with, never wherever `updateConfig` has since
///     moved `config.serverUrl` — the scenario is `ServerSelector` (app
///     layer, not exercised here) failing general traffic over to a
///     DR/failover node that has no shared file storage and 402s a tus
///     create. A plain `get`/`post` call is asserted to keep following the
///     CURRENT `serverUrl` (unchanged behaviour) so this suite also catches
///     a regression that accidentally widens the pin to every request.
///   - **A-iOS — retry-with-backoff**: `getFileEndpoint` retries a
///     transient 429/5xx up to `maxAttempts` times, honouring `Retry-After`,
///     instead of failing on the first attempt
///     (`ChatFileAttachmentReceiver`'s single whole-file GET, before this
///     phase, never retried at all).
final class BCryptoRestClientFileEndpointTests: XCTestCase {

    override func tearDown() {
        FileEndpointStubProtocol.responseHandler = nil
        FileEndpointStubProtocol.recordedHosts = []
        super.tearDown()
    }

    private func makeClient(serverUrl: String) -> BCryptoRestClient {
        let config = BackendConfig(serverUrl: serverUrl, accessToken: "tok")
        return BCryptoRestClient(config: config, testURLProtocolClasses: [FileEndpointStubProtocol.self])
    }

    // MARK: - G: node selection for file endpoints

    func test_getFileEndpoint_targetsPinnedPrimary_notAFailedOverServerUrl() async throws {
        let client = makeClient(serverUrl: "https://primary.test")
        // Simulate ServerSelector moving general traffic to a DR/failover
        // node — `primaryServerUrl` was captured at construction and must
        // not follow this.
        client.updateConfig(BackendConfig(serverUrl: "https://failover.test", accessToken: "tok"))

        FileEndpointStubProtocol.responseHandler = { request in
            (Self.okResponse(for: request), Data("ciphertext".utf8))
        }

        let data = try await client.getFileEndpoint("/api/v1/files/tus/abc")
        XCTAssertEqual(data, Data("ciphertext".utf8))
        XCTAssertEqual(FileEndpointStubProtocol.recordedHosts, ["primary.test"],
                        "file download must never reach the failed-over host")
    }

    func test_postToPrimary_targetsPinnedPrimary_notAFailedOverServerUrl() async throws {
        let client = makeClient(serverUrl: "https://primary.test")
        client.updateConfig(BackendConfig(serverUrl: "https://failover.test", accessToken: "tok"))

        FileEndpointStubProtocol.responseHandler = { request in
            (Self.okResponse(for: request), Data("{}".utf8))
        }

        _ = try await client.postToPrimary("/api/v1/files/issue-token", body: Data())
        XCTAssertEqual(FileEndpointStubProtocol.recordedHosts, ["primary.test"],
                        "issue-token must never reach the failed-over host")
    }

    func test_plainGet_stillFollowsCurrentServerUrl_afterUpdateConfig() async throws {
        // Regression guard: every OTHER request on this client (calling,
        // accounts, contacts, …) must keep riding whatever the selector has
        // set `serverUrl` to — only the file-endpoint helpers above pin to
        // the primary.
        let client = makeClient(serverUrl: "https://primary.test")
        client.updateConfig(BackendConfig(serverUrl: "https://failover.test", accessToken: "tok"))

        FileEndpointStubProtocol.responseHandler = { request in
            (Self.okResponse(for: request), Data("{}".utf8))
        }

        _ = try await client.get("/api/v1/profile")
        XCTAssertEqual(FileEndpointStubProtocol.recordedHosts, ["failover.test"])
    }

    // MARK: - A-iOS: retry-with-backoff on the download GET

    func test_getFileEndpoint_retriesTransient503_thenSucceeds() async throws {
        let client = makeClient(serverUrl: "https://primary.test")
        var attempt = 0
        FileEndpointStubProtocol.responseHandler = { request in
            attempt += 1
            if attempt < 3 {
                // Small Retry-After so the test's own backoff wait stays fast.
                return (Self.response(for: request, status: 503, headers: ["Retry-After": "0.01"]), nil)
            }
            return (Self.okResponse(for: request), Data("ciphertext".utf8))
        }

        let data = try await client.getFileEndpoint("/api/v1/files/tus/abc", maxAttempts: 4)
        XCTAssertEqual(data, Data("ciphertext".utf8))
        XCTAssertEqual(attempt, 3, "must retry exactly twice before the 3rd attempt succeeds")
    }

    func test_getFileEndpoint_retries429_honouringRetryAfter_thenSucceeds() async throws {
        let client = makeClient(serverUrl: "https://primary.test")
        var attempt = 0
        FileEndpointStubProtocol.responseHandler = { request in
            attempt += 1
            if attempt == 1 {
                return (Self.response(for: request, status: 429, headers: ["Retry-After": "0.01"]), nil)
            }
            return (Self.okResponse(for: request), Data("ok".utf8))
        }

        let data = try await client.getFileEndpoint("/api/v1/files/tus/abc")
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(attempt, 2)
    }

    func test_getFileEndpoint_exhaustsRetries_throwsHttpErrorWithLastStatus() async throws {
        let client = makeClient(serverUrl: "https://primary.test")
        var attempt = 0
        FileEndpointStubProtocol.responseHandler = { request in
            attempt += 1
            return (Self.response(for: request, status: 503, headers: ["Retry-After": "0.01"]), nil)
        }

        do {
            _ = try await client.getFileEndpoint("/api/v1/files/tus/abc", maxAttempts: 2)
            XCTFail("expected httpError to be thrown after exhausting retries")
        } catch let error as BCryptoError {
            guard case .httpError(let code) = error else {
                XCTFail("expected .httpError, got \(error)")
                return
            }
            XCTAssertEqual(code, 503)
        }
        XCTAssertEqual(attempt, 2, "must not retry beyond maxAttempts")
    }

    func test_getFileEndpoint_nonRetryableStatus_failsOnFirstAttempt() async throws {
        // 404 (e.g. a purged tus record) is not in the retryable set — must
        // not burn the retry budget on a status no retry will ever fix.
        let client = makeClient(serverUrl: "https://primary.test")
        var attempt = 0
        FileEndpointStubProtocol.responseHandler = { request in
            attempt += 1
            return (Self.response(for: request, status: 404, headers: [:]), nil)
        }

        do {
            _ = try await client.getFileEndpoint("/api/v1/files/tus/abc", maxAttempts: 4)
            XCTFail("expected httpError to be thrown")
        } catch let error as BCryptoError {
            guard case .httpError(let code) = error else {
                XCTFail("expected .httpError, got \(error)")
                return
            }
            XCTAssertEqual(code, 404)
        }
        XCTAssertEqual(attempt, 1, "a non-retryable status must not be retried")
    }

    // MARK: - retryDelayNanos (pure function, no networking)

    func test_retryDelayNanos_honoursNumericRetryAfterHeader() {
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: "2", attempt: 0), 2_000_000_000)
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: "0.5", attempt: 3), 500_000_000)
    }

    func test_retryDelayNanos_capsHugeRetryAfterAt30Seconds() {
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: "9999", attempt: 0), 30_000_000_000)
    }

    func test_retryDelayNanos_fallsBackToEscalatingSchedule_whenHeaderMissingOrUnusable() {
        // Missing header.
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: nil, attempt: 0), 1_000_000_000)
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: nil, attempt: 1), 2_000_000_000)
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: nil, attempt: 2), 4_000_000_000)
        // Attempt beyond the schedule's length clamps to the last entry.
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: nil, attempt: 99), 4_000_000_000)
        // An HTTP-date (this server never actually sends one) is not
        // numeric — falls back rather than crashing or blocking forever.
        XCTAssertEqual(
            BCryptoRestClient.retryDelayNanos(afterHeader: "Sun, 06 Nov 1994 08:49:37 GMT", attempt: 0),
            1_000_000_000)
        // A non-positive value is not a usable delay.
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: "0", attempt: 0), 1_000_000_000)
        XCTAssertEqual(BCryptoRestClient.retryDelayNanos(afterHeader: "-1", attempt: 0), 1_000_000_000)
    }

    // MARK: - Stub response helpers

    private static func okResponse(for request: URLRequest) -> HTTPURLResponse {
        response(for: request, status: 200, headers: [:])
    }

    private static func response(for request: URLRequest, status: Int, headers: [String: String]) -> HTTPURLResponse {
        // Safe: `request.url` is guaranteed non-nil once dispatched via
        // URLSession, and a literal in-range status code makes this
        // HTTPURLResponse initializer infallible here.
        // swiftlint:disable:next force_unwrapping
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}

/// Mirrors `TusStubProtocol` (`TusUploadClientTests.swift`) — same shape,
/// named distinctly so a failure's stack trace is unambiguous about which
/// suite it came from. Also records each request's host so tests can
/// assert on file-endpoint node selection without a real network.
private final class FileEndpointStubProtocol: URLProtocol {
    static var responseHandler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    static var recordedHosts: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let host = request.url?.host {
            FileEndpointStubProtocol.recordedHosts.append(host)
        }
        guard let handler = FileEndpointStubProtocol.responseHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (resp, data) = handler(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let data { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

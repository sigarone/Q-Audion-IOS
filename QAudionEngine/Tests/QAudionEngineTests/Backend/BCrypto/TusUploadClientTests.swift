import XCTest
@testable import QAudionEngine

/// W446 — upload progress reporting. Verifies `TusUploadClient.upload`
/// invokes `onProgress` once per chunk PATCH, with monotonically
/// increasing `bytesUploaded` and a stable `totalBytes`, matching the
/// tus.io wire flow documented at the top of `TusUploadClient.swift`
/// (POST create + N PATCH chunks, each echoing the new `Upload-Offset`).
final class TusUploadClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TusStubProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        TusStubProtocol.responseHandler = nil
        super.tearDown()
    }

    func test_upload_reportsMonotonicProgressAcrossChunks() async throws {
        // 3 chunks of 10 bytes each (chunkSize=10, 30 bytes total) so the
        // upload loop round-trips 3 PATCH calls after the initial POST.
        let totalBytes = 30
        let chunkSize = 10
        let fileId = "abc-123"

        TusStubProtocol.responseHandler = { request in
            if request.httpMethod == "POST" {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "/api/v1/files/tus/\(fileId)"]
                )!
                return (resp, nil)
            }
            // PATCH: echo back the new offset = Upload-Offset header (the
            // offset this chunk STARTS at) + the body length, exactly like
            // the tus core spec §11 the client relies on.
            let startOffset = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "0") ?? 0
            let bodyLen = request.httpBodyLength
            let newOffset = startOffset + bodyLen
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Upload-Offset": String(newOffset)]
            )!
            return (resp, nil)
        }

        let client = TusUploadClient(
            session: session,
            serverUrl: "https://test",
            getToken: { "token123" },
            chunkSize: chunkSize
        )

        var progressCalls: [(bytesUploaded: Int64, totalBytes: Int64)] = []
        let data = Data(repeating: 0x41, count: totalBytes)
        let returnedFileId = try await client.upload(data: data) { uploaded, total in
            progressCalls.append((uploaded, total))
        }

        XCTAssertEqual(returnedFileId, fileId)

        // 3 chunks -> 3 progress callbacks.
        XCTAssertEqual(progressCalls.count, 3)

        // totalBytes is stable across every callback.
        XCTAssertTrue(progressCalls.allSatisfy { $0.totalBytes == Int64(totalBytes) })

        // bytesUploaded is strictly increasing and ends at totalBytes.
        let uploadedValues = progressCalls.map { $0.bytesUploaded }
        XCTAssertEqual(uploadedValues, [10, 20, 30])
        for i in 1..<uploadedValues.count {
            XCTAssertGreaterThan(uploadedValues[i], uploadedValues[i - 1],
                                  "bytesUploaded must be monotonically increasing")
        }
        XCTAssertEqual(uploadedValues.last, Int64(totalBytes))
    }

    func test_upload_withNilOnProgress_stillSucceeds() async throws {
        // Default `onProgress: nil` must keep compiling AND working —
        // this is the additive-change contract every existing caller
        // relies on.
        let fileId = "def-456"
        TusStubProtocol.responseHandler = { request in
            if request.httpMethod == "POST" {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "/api/v1/files/tus/\(fileId)"]
                )!
                return (resp, nil)
            }
            let startOffset = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "0") ?? 0
            let bodyLen = request.httpBodyLength
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Upload-Offset": String(startOffset + bodyLen)]
            )!
            return (resp, nil)
        }

        let client = TusUploadClient(
            session: session,
            serverUrl: "https://test",
            getToken: { nil },
            chunkSize: 512 * 1024
        )
        let data = Data(repeating: 0x42, count: 100)
        let returnedFileId = try await client.upload(data: data)
        XCTAssertEqual(returnedFileId, fileId)
    }

    func test_upload_singleChunk_reportsOneCallback() async throws {
        // Payload smaller than chunkSize -> exactly one PATCH round trip.
        let fileId = "single-1"
        TusStubProtocol.responseHandler = { request in
            if request.httpMethod == "POST" {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "/api/v1/files/tus/\(fileId)"]
                )!
                return (resp, nil)
            }
            let bodyLen = request.httpBodyLength
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Upload-Offset": String(bodyLen)]
            )!
            return (resp, nil)
        }

        let client = TusUploadClient(
            session: session,
            serverUrl: "https://test",
            getToken: { "tok" },
            chunkSize: 1024
        )
        var calls: [(Int64, Int64)] = []
        let data = Data(repeating: 0x43, count: 50)
        _ = try await client.upload(data: data) { uploaded, total in
            calls.append((uploaded, total))
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].0, 50)
        XCTAssertEqual(calls[0].1, 50)
    }

    func test_upload_callsOnCreated_beforeChunkLoopStarts() async throws {
        // W-TUSRESUME: `onCreated` must fire exactly once, with the
        // minted fileId, and (implicitly, since it's invoked synchronously
        // right after `create()`) before any PATCH round-trip.
        let fileId = "created-1"
        var patchCallCount = 0
        TusStubProtocol.responseHandler = { request in
            if request.httpMethod == "POST" {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "/api/v1/files/tus/\(fileId)"]
                )!
                return (resp, nil)
            }
            patchCallCount += 1
            let bodyLen = request.httpBodyLength
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Upload-Offset": String(bodyLen)]
            )!
            return (resp, nil)
        }

        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }, chunkSize: 1024
        )
        var onCreatedFileIds: [String] = []
        var patchCallCountAtOnCreated = -1
        let data = Data(repeating: 0x44, count: 10)
        _ = try await client.upload(data: data, onCreated: { created in
            onCreatedFileIds.append(created)
            patchCallCountAtOnCreated = patchCallCount
        })

        XCTAssertEqual(onCreatedFileIds, [fileId])
        XCTAssertEqual(patchCallCountAtOnCreated, 0, "onCreated must fire before any PATCH")
    }

    // MARK: - W-TUSRESUME: head()

    func test_head_success_returnsOffsetAndLength() async throws {
        TusStubProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Upload-Offset": "42", "Upload-Length": "100"]
            )!
            return (resp, nil)
        }
        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }
        )
        let result = try await client.head(fileId: "some-id")
        XCTAssertEqual(result.offset, 42)
        XCTAssertEqual(result.totalLength, 100)
    }

    func test_head_404_throwsUploadNotFound() async throws {
        TusStubProtocol.responseHandler = { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
            )!
            return (resp, nil)
        }
        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }
        )
        do {
            _ = try await client.head(fileId: "purged-id")
            XCTFail("expected uploadNotFound to be thrown")
        } catch let error as TusUploadClient.TusError {
            guard case .uploadNotFound(let fileId) = error else {
                XCTFail("expected .uploadNotFound, got \(error)")
                return
            }
            XCTAssertEqual(fileId, "purged-id")
        }
    }

    func test_head_genericFailure_throwsHeadFailed() async throws {
        TusStubProtocol.responseHandler = { request in
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (resp, nil)
        }
        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }
        )
        do {
            _ = try await client.head(fileId: "some-id")
            XCTFail("expected headFailed to be thrown")
        } catch let error as TusUploadClient.TusError {
            guard case .headFailed(let code) = error else {
                XCTFail("expected .headFailed, got \(error)")
                return
            }
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - W-TUSRESUME: resume()

    func test_resume_startsMidFile_skipsCreate_completesRemainder() async throws {
        // 30-byte file, chunkSize 10 -> resuming from offset 10 should
        // PATCH exactly 2 chunks (bytes 10..<20, 20..<30) and never hit
        // POST /files/tus (create is skipped entirely on resume).
        let fileId = "resume-1"
        var sawCreateCall = false
        var patchedOffsets: [Int] = []
        TusStubProtocol.responseHandler = { request in
            if request.httpMethod == "POST" {
                sawCreateCall = true
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "/api/v1/files/tus/\(fileId)"]
                )!
                return (resp, nil)
            }
            let startOffset = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "0") ?? 0
            patchedOffsets.append(startOffset)
            let bodyLen = request.httpBodyLength
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Upload-Offset": String(startOffset + bodyLen)]
            )!
            return (resp, nil)
        }

        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }, chunkSize: 10
        )
        let data = Data(repeating: 0x45, count: 30)
        var progressCalls: [(Int64, Int64)] = []
        let returnedFileId = try await client.resume(
            fileId: fileId, data: data, fromOffset: 10
        ) { uploaded, total in
            progressCalls.append((uploaded, total))
        }

        XCTAssertEqual(returnedFileId, fileId)
        XCTAssertFalse(sawCreateCall, "resume() must never call create()")
        XCTAssertEqual(patchedOffsets, [10, 20])
        XCTAssertEqual(progressCalls.map { $0.0 }, [20, 30])
        XCTAssertTrue(progressCalls.allSatisfy { $0.1 == 30 })
    }

    func test_resume_fromOffsetEqualToDataCount_sendsNoChunks() async throws {
        // Already fully uploaded per HEAD's report -> resume() should be
        // a no-op chunk-loop-wise (loop condition `offset < data.count`
        // never true) and just return the fileId.
        var patchCallCount = 0
        TusStubProtocol.responseHandler = { request in
            patchCallCount += 1
            let resp = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }, chunkSize: 10
        )
        let data = Data(repeating: 0x46, count: 30)
        let returnedFileId = try await client.resume(fileId: "complete-1", data: data, fromOffset: 30)
        XCTAssertEqual(returnedFileId, "complete-1")
        XCTAssertEqual(patchCallCount, 0)
    }

    func test_resume_404OnPatch_throwsUploadNotFound() async throws {
        // Simulates the 24h-retention-purge case surfacing mid-resume:
        // the fileId existed long enough for HEAD to (hypothetically)
        // succeed earlier, but by the time resume's PATCH lands the
        // record is gone.
        TusStubProtocol.responseHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }
        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }, chunkSize: 10
        )
        let data = Data(repeating: 0x47, count: 10)
        do {
            _ = try await client.resume(fileId: "gone-1", data: data, fromOffset: 0)
            XCTFail("expected uploadNotFound to be thrown")
        } catch let error as TusUploadClient.TusError {
            guard case .uploadNotFound(let fileId) = error else {
                XCTFail("expected .uploadNotFound, got \(error)")
                return
            }
            XCTAssertEqual(fileId, "gone-1")
        }
    }

    // MARK: - W-TUSRESUME: tier-2 per-chunk retry
    //
    // Both tests below exercise `patchWithRetry`'s `Task.sleep`-based
    // backoff — the only place production code actually suspends on a
    // real timer. On the GitHub Actions iOS Simulator runner (not the
    // sibling macOS "test" job, which never reproduces this) that timer
    // resumption has been observed to hang indefinitely rather than the
    // expected ~1.5s total backoff, eventually tripping Xcode's own
    // "QUARANTINED DUE TO HIGH LOGGING VOLUME" safety valve and then
    // sitting until GitHub's ~1h job timeout force-cancels the whole
    // workflow — confirmed via the raw job log across 10+ consecutive CI
    // runs going back days, unrelated to any code change. `withTimeout`
    // below bounds each test to a few seconds so a recurrence fails fast
    // with a clear diagnostic instead of burning an hour of CI on every
    // push. This is a CI-environment mitigation, not a production fix —
    // `patchWithRetry`'s own retry loop is already provably bounded
    // (`maxChunkAttempts`, no unbounded `while(true)`).

    func test_chunkRetry_succeedsOnThirdAttempt() async throws {
        // First 2 PATCH attempts for the chunk fail with a transient 500;
        // the 3rd (last allowed, maxChunkAttempts=3) succeeds. Verifies
        // tier-2 retries the SAME chunk rather than giving up early or
        // advancing past a failed chunk.
        let fileId = "retry-1"
        var patchAttempts = 0
        TusStubProtocol.responseHandler = { request in
            if request.httpMethod == "POST" {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "/api/v1/files/tus/\(fileId)"]
                )!
                return (resp, nil)
            }
            patchAttempts += 1
            if patchAttempts < 3 {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (resp, nil)
            }
            let bodyLen = request.httpBodyLength
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 204, httpVersion: nil,
                headerFields: ["Upload-Offset": String(bodyLen)]
            )!
            return (resp, nil)
        }

        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }, chunkSize: 1024
        )
        let data = Data(repeating: 0x48, count: 20)
        let returnedFileId = try await withTimeout(seconds: 10) {
            try await client.upload(data: data)
        }
        XCTAssertEqual(returnedFileId, fileId)
        XCTAssertEqual(patchAttempts, 3, "should retry exactly twice before the 3rd attempt succeeds")
    }

    func test_chunkRetry_exhaustsAfterMaxAttempts_propagatesLastError() async throws {
        // All PATCH attempts fail with 500 -> after maxChunkAttempts (3)
        // tries, the error propagates to the caller instead of retrying
        // forever or silently succeeding.
        var patchAttempts = 0
        TusStubProtocol.responseHandler = { request in
            if request.httpMethod == "POST" {
                let resp = HTTPURLResponse(
                    url: request.url!, statusCode: 201, httpVersion: nil,
                    headerFields: ["Location": "/api/v1/files/tus/exhaust-1"]
                )!
                return (resp, nil)
            }
            patchAttempts += 1
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, nil)
        }

        let client = TusUploadClient(
            session: session, serverUrl: "https://test", getToken: { "tok" }, chunkSize: 1024
        )
        let data = Data(repeating: 0x49, count: 20)
        do {
            _ = try await withTimeout(seconds: 10) {
                try await client.upload(data: data)
            }
            XCTFail("expected patchFailed to propagate after exhausting retries")
        } catch let error as TusUploadClient.TusError {
            guard case .patchFailed(let code) = error else {
                XCTFail("expected .patchFailed, got \(error)")
                return
            }
            XCTAssertEqual(code, 500)
        }
        XCTAssertEqual(patchAttempts, TusUploadClient.maxChunkAttempts)
    }
}

// MARK: - Test timeout helper

private struct TestTimeoutError: Error, LocalizedError {
    var errorDescription: String? { "test operation exceeded its timeout" }
}

/// Races `operation` against a plain `Task.sleep` deadline so a hang in
/// the operation (rather than a normal failure) surfaces as a fast,
/// diagnosable `TestTimeoutError` instead of hanging the whole test run.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - Stub URLProtocol

/// Mirrors `StubProtocol` from `BCryptoContactsDiscoverV2ClientTests` —
/// same shape (both `private`, so there's no cross-file symbol
/// collision either way); named distinctly here just to keep grep/stack
/// traces unambiguous about which test file a failure came from.
private final class TusStubProtocol: URLProtocol {
    static var responseHandler: ((URLRequest) -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = TusStubProtocol.responseHandler else {
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

private extension URLRequest {
    /// `TusUploadClient.patch` always sets `req.httpBody = bytes`
    /// directly (never `httpBodyStream`), so `httpBody` is reliably
    /// populated on the intercepted request — this just centralizes the
    /// nil-coalescing so the response handlers above stay concise.
    var httpBodyLength: Int {
        httpBody?.count ?? 0
    }
}

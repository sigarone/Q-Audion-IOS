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

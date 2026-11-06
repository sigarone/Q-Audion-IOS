import XCTest
@testable import QAudionEngine

final class TusResumePlanTests: XCTestCase {

    func test_serverHoldsNothingYet_continuesFromZero() {
        XCTAssertEqual(TusUploadClient.ResumePlan.decide(serverOffset: 0, serverLength: 30, dataCount: 30), .continueAt(0))
    }

    func test_serverHoldsPartOfIt_continuesFromItsOffset() {
        XCTAssertEqual(TusUploadClient.ResumePlan.decide(serverOffset: 20, serverLength: 30, dataCount: 30), .continueAt(20))
    }

    func test_serverHoldsEverything_isComplete() {
        XCTAssertEqual(TusUploadClient.ResumePlan.decide(serverOffset: 30, serverLength: 30, dataCount: 30), .complete)
    }

    func test_uploadCreatedForOtherBytes_startsOver() {
        XCTAssertEqual(TusUploadClient.ResumePlan.decide(serverOffset: 10, serverLength: 31, dataCount: 30), .startOver)
        XCTAssertEqual(TusUploadClient.ResumePlan.decide(serverOffset: 40, serverLength: 30, dataCount: 30), .startOver)
        XCTAssertEqual(TusUploadClient.ResumePlan.decide(serverOffset: -1, serverLength: 30, dataCount: 30), .startOver)
    }
}

final class TusResumeFlowTests: XCTestCase {

    private final class Stub: URLProtocol {
        static var handler: ((URLRequest) -> HTTPURLResponse)?
        static var seen: [(method: String, offset: String?)] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Stub.seen.append((request.httpMethod ?? "", request.value(forHTTPHeaderField: "Upload-Offset")))
            guard let handler = Stub.handler else {
                client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
                return
            }
            client?.urlProtocol(self, didReceive: handler(request), cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeClient() -> TusUploadClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return TusUploadClient(session: URLSession(configuration: config), serverUrl: "https://test",
                               getToken: { nil }, chunkSize: 10)
    }

    private static func response(_ request: URLRequest, _ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        // swiftlint:disable:next force_unwrapping
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    override func setUp() {
        super.setUp()
        Stub.seen = []
    }

    override func tearDown() {
        Stub.handler = nil
        super.tearDown()
    }

    func test_resumeSendsOnlyTheMissingBytesAndCreatesNothing() async throws {
        Stub.handler = { request in
            switch request.httpMethod {
            case "HEAD":
                return Self.response(request, 200, ["Upload-Offset": "20", "Upload-Length": "30"])
            case "PATCH":
                let start = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "0") ?? 0
                return Self.response(request, 204, ["Upload-Offset": String(start + 10)])
            default:
                return Self.response(request, 500)
            }
        }
        let id = try await makeClient().upload(data: Data(repeating: 0x41, count: 30), filename: "c.log", resumeFileId: "f1")
        XCTAssertEqual(id, "f1")
        XCTAssertEqual(Stub.seen.map(\.method), ["HEAD", "PATCH"])
        XCTAssertEqual(Stub.seen.last?.offset, "20")
    }

    func test_resumeOfACompleteUploadSendsNothing() async throws {
        Stub.handler = { request in
            Self.response(request, 200, ["Upload-Offset": "30", "Upload-Length": "30"])
        }
        let id = try await makeClient().upload(data: Data(repeating: 0x41, count: 30), resumeFileId: "f1")
        XCTAssertEqual(id, "f1")
        XCTAssertEqual(Stub.seen.map(\.method), ["HEAD"])
    }

    func test_purgedUploadStartsOverWithANewOne() async throws {
        Stub.handler = { request in
            switch request.httpMethod {
            case "HEAD": return Self.response(request, 404)
            case "POST": return Self.response(request, 201, ["Location": "/api/v1/files/tus/new-id"])
            default:
                let start = Int(request.value(forHTTPHeaderField: "Upload-Offset") ?? "0") ?? 0
                return Self.response(request, 204, ["Upload-Offset": String(start + 10)])
            }
        }
        let id = try await makeClient().upload(data: Data(repeating: 0x41, count: 20), resumeFileId: "old")
        XCTAssertEqual(id, "new-id")
        XCTAssertEqual(Stub.seen.map(\.method), ["HEAD", "POST", "PATCH", "PATCH"])
    }

    func test_headServerErrorIsThrownAndNothingElseIsSent() async {
        Stub.handler = { request in Self.response(request, 502) }
        do {
            _ = try await makeClient().upload(data: Data(repeating: 0x41, count: 20), resumeFileId: "f1")
            XCTFail("expected an error")
        } catch TusUploadClient.TusError.headFailed(let code) {
            XCTAssertEqual(code, 502)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(Stub.seen.map(\.method), ["HEAD"])
    }
}

import XCTest
@testable import QAudionEngine

/// 2026-10-19 — the crash of 18-19 Oct: SIGSEGV while destroying the `AuthRefreshRequest` in
/// `BCryptoRestClient.refreshSession`. The app resumed with an expired access token, six or seven
/// requests got 401 at once, all joined the same refresh, and every one of them wrote the new
/// pair into the client's `config` while other tasks were reading it. `config` had no lock, so
/// concurrent String writes corrupted reference counts.
///
/// These tests drive the real path with a stub server (stale token -> 401, fresh token -> 200):
/// many requests get 401 together and recover through one refresh, while other tasks read the
/// tokens or replace the whole configuration. Every request must recover and the client must end
/// on the fresh pair. Each scenario runs several rounds, because a race does not show on every run.
final class BCryptoRestClientConcurrentRefreshTests: XCTestCase {

    private static let rounds = 20
    private static let concurrentRequests = 12

    override func tearDown() {
        ConcurrentRefreshStubProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> BCryptoRestClient {
        let client = BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://auth.test", accessToken: "A0", refreshToken: "R0"),
            testURLProtocolClasses: [ConcurrentRefreshStubProtocol.self])
        client.authCoordinator = AuthRefreshCoordinator()
        client.credentialStore = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        client.setTokenRefresher { _ in
            // Long enough for every 401 of the burst to join this one flight.
            try await Task.sleep(nanoseconds: 100_000_000)
            return AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
        }
        return client
    }

    private func serveFreshTokenOnly() {
        ConcurrentRefreshStubProtocol.handler = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer A1" ? 200 : 401
        }
    }

    func test_aBurstOf401sRecoversThroughOneRefreshWhileTheTokensAreRead() async {
        serveFreshTokenOnly()
        for round in 0..<Self.rounds {
            let client = makeClient()
            let recovered = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                for index in 0..<Self.concurrentRequests {
                    group.addTask {
                        do {
                            _ = try await client.get("/api/v1/resource\(index)")
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                for _ in 0..<4 {
                    group.addTask {
                        for _ in 0..<500 {
                            _ = client.accessToken
                            _ = client.refreshToken
                            _ = client.serverUrl
                        }
                        return true
                    }
                }
                var results: [Bool] = []
                for await result in group { results.append(result) }
                return results
            }
            XCTAssertTrue(recovered.allSatisfy { $0 }, "round \(round): every request recovers")
            XCTAssertEqual(client.accessToken, "A1", "round \(round)")
            XCTAssertEqual(client.refreshToken, "R1", "round \(round)")
        }
    }

    func test_aBurstOf401sRecoversWhileTheConfigurationIsReplaced() async {
        serveFreshTokenOnly()
        let fresh = BackendConfig(serverUrl: "https://auth.test", accessToken: "A1", refreshToken: "R1")
        for round in 0..<Self.rounds {
            let client = makeClient()
            let recovered = await withTaskGroup(of: Bool.self) { group -> [Bool] in
                for index in 0..<Self.concurrentRequests {
                    group.addTask {
                        do {
                            _ = try await client.get("/api/v1/resource\(index)")
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                // What the provider does when it broadcasts a new pair to every client.
                for _ in 0..<2 {
                    group.addTask {
                        for _ in 0..<200 { client.updateConfig(fresh) }
                        return true
                    }
                }
                var results: [Bool] = []
                for await result in group { results.append(result) }
                return results
            }
            XCTAssertTrue(recovered.allSatisfy { $0 }, "round \(round): every request recovers")
            XCTAssertEqual(client.accessToken, "A1", "round \(round)")
            XCTAssertEqual(client.refreshToken, "R1", "round \(round)")
        }
    }
}

/// Answers every request with the status the handler picks, and an empty body.
private final class ConcurrentRefreshStubProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Int)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = ConcurrentRefreshStubProtocol.handler, let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: handler(request), httpVersion: "HTTP/1.1",
                                         headerFields: [:]) else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

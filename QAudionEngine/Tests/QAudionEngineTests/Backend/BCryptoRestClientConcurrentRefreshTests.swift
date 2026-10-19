import XCTest
@testable import QAudionEngine

/// 2026-10-19 — the crash of 18-19 Oct: SIGSEGV while destroying the `AuthRefreshRequest` in
/// `BCryptoRestClient.refreshSession`. The app resumed with an expired access token, six or seven
/// requests got 401 at once and joined the same refresh, and every one of them wrote the new pair
/// into the client's config, and through `onTokensApplied` into the provider's, while other tasks
/// were reading them. Neither config had a lock, so concurrent String writes corrupted reference
/// counts.
///
/// The tokens here are long and built at runtime: short literals are stored inline, without a heap
/// object or a reference count, and could never show the bug. Each scenario runs several rounds,
/// because a race does not show on every run.
final class BCryptoRestClientConcurrentRefreshTests: XCTestCase {

    private static let rounds = 20
    private static let concurrentRequests = 12

    override func tearDown() {
        ConcurrentRefreshStubProtocol.handler = nil
        super.tearDown()
    }

    /// A token long enough to live on the heap, distinct for every call.
    private static func token(_ tag: String) -> String {
        tag + "." + String(repeating: "x", count: 120) + "." + UUID().uuidString
    }

    private struct Pair {
        let access: String
        let refresh: String
        static func make(_ tag: String) -> Pair {
            Pair(access: BCryptoRestClientConcurrentRefreshTests.token("A" + tag),
                 refresh: BCryptoRestClientConcurrentRefreshTests.token("R" + tag))
        }
    }

    /// The stub server accepts only the fresh access token; anything else gets 401.
    private func serve(onlyAccess fresh: String) {
        let expected = "Bearer " + fresh
        ConcurrentRefreshStubProtocol.handler = { request in
            request.value(forHTTPHeaderField: "Authorization") == expected ? 200 : 401
        }
    }

    private func makeClient(stale: Pair, fresh: Pair, stored: Pair) -> BCryptoRestClient {
        let client = BCryptoRestClient(
            config: BackendConfig(serverUrl: "https://auth.test", accessToken: stale.access,
                                  refreshToken: stale.refresh),
            testURLProtocolClasses: [ConcurrentRefreshStubProtocol.self])
        client.authCoordinator = AuthRefreshCoordinator()
        client.credentialStore = InMemoryAuthCredentialStore(access: stored.access, refresh: stored.refresh)
        client.setTokenRefresher { _ in
            // Long enough for every 401 of the burst to join this one flight.
            try await Task.sleep(nanoseconds: 100_000_000)
            return AuthTokenSet(accessToken: fresh.access, refreshToken: fresh.refresh, expiresInSec: 900)
        }
        return client
    }

    private func burst(on client: BCryptoRestClient, alongside extra: [@Sendable () -> Void]) async -> [Bool] {
        await withTaskGroup(of: Bool.self) { group -> [Bool] in
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
            for work in extra {
                group.addTask {
                    work()
                    return true
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    func test_aBurstOf401sRecoversThroughOneRefreshWhileTheTokensAreRead() async {
        for round in 0..<Self.rounds {
            let stale = Pair.make("0"), fresh = Pair.make("1")
            serve(onlyAccess: fresh.access)
            let client = makeClient(stale: stale, fresh: fresh, stored: stale)
            let reader: @Sendable () -> Void = {
                for _ in 0..<500 {
                    _ = client.accessToken
                    _ = client.refreshToken
                    _ = client.serverUrl
                }
            }
            let recovered = await burst(on: client, alongside: Array(repeating: reader, count: 4))
            XCTAssertTrue(recovered.allSatisfy { $0 }, "round \(round): every request recovers")
            XCTAssertEqual(client.accessToken, fresh.access, "round \(round)")
            XCTAssertEqual(client.refreshToken, fresh.refresh, "round \(round)")
        }
    }

    func test_aBurstOf401sRecoversWhileTheProviderBroadcastsTheNewPair() async {
        // As in production after a refresh elsewhere: the store already holds the fresh pair, the
        // provider pushes it to the client, and requests sent with the stale token adopt it.
        for round in 0..<Self.rounds {
            let stale = Pair.make("0"), fresh = Pair.make("1")
            serve(onlyAccess: fresh.access)
            let client = makeClient(stale: stale, fresh: fresh, stored: fresh)
            let freshConfig = BackendConfig(serverUrl: "https://auth.test", accessToken: fresh.access,
                                            refreshToken: fresh.refresh)
            let broadcaster: @Sendable () -> Void = {
                for _ in 0..<200 { client.updateConfig(freshConfig) }
            }
            let recovered = await burst(on: client, alongside: Array(repeating: broadcaster, count: 2))
            XCTAssertTrue(recovered.allSatisfy { $0 }, "round \(round): every request recovers")
            XCTAssertEqual(client.accessToken, fresh.access, "round \(round)")
            XCTAssertEqual(client.refreshToken, fresh.refresh, "round \(round)")
        }
    }

    func test_concurrentApplyTokenPairLeavesTheProviderOnOneWholePair() async {
        // `applyTokenPair` is what every caller of a joined refresh runs, through
        // `onTokensApplied`, at the same moment.
        for round in 0..<Self.rounds {
            let initial = Pair.make("0")
            let provider = BCryptoBackendProvider(config: BackendConfig(
                serverUrl: "https://auth.test", accessToken: initial.access, refreshToken: initial.refresh))
            let pairs = (1...8).map { Pair.make(String($0)) }
            await withTaskGroup(of: Void.self) { group in
                for pair in pairs {
                    group.addTask {
                        for _ in 0..<50 {
                            provider.applyTokenPair(access: pair.access, refresh: pair.refresh, persist: false)
                        }
                    }
                }
                for _ in 0..<4 {
                    group.addTask {
                        for _ in 0..<500 {
                            let config = provider.config
                            _ = config.accessToken
                            _ = config.refreshToken
                        }
                    }
                }
            }
            let final = provider.config
            XCTAssertTrue(pairs.contains { $0.access == final.accessToken && $0.refresh == final.refreshToken },
                          "round \(round): the provider ends on one of the applied pairs, never a mix")
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

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

    /// Sends the burst of requests and runs `extra` alongside it until every request has
    /// finished, so the extra work overlaps the refresh and its writes instead of ending first.
    private func burst(on client: BCryptoRestClient, alongside extra: [@Sendable (StopFlag) -> Void]) async -> [Bool] {
        let stop = StopFlag()
        return await withTaskGroup(of: [Bool].self) { outer -> [Bool] in
            for work in extra {
                outer.addTask {
                    await Self.onDispatchThread { work(stop) }
                    return []
                }
            }
            outer.addTask {
                let results = await withTaskGroup(of: Bool.self) { group -> [Bool] in
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
                    var results: [Bool] = []
                    for await result in group { results.append(result) }
                    return results
                }
                stop.set()
                return results
            }
            var all: [Bool] = []
            for await part in outer { all.append(contentsOf: part) }
            return all
        }
    }

    /// Runs `work` on a dispatch thread. The extra work spins until the requests are done, and
    /// inside Swift's cooperative pool it could hold every thread those requests need.
    private static func onDispatchThread(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                done.resume()
            }
        }
    }

    /// Runs `body` at least `minimum` times and then until `stop` is set, with a ceiling so
    /// a hung request fails the test instead of spinning forever.
    private static func repeatUntil(_ stop: StopFlag, minimum: Int, _ body: () -> Void) {
        var runs = 0
        while runs < minimum || (!stop.isSet && runs < 5_000_000) {
            body()
            runs += 1
        }
    }

    func test_aBurstOf401sRecoversThroughOneRefreshWhileTheTokensAreRead() async {
        for round in 0..<Self.rounds {
            let stale = Pair.make("0"), fresh = Pair.make("1")
            serve(onlyAccess: fresh.access)
            let client = makeClient(stale: stale, fresh: fresh, stored: stale)
            let reader: @Sendable (StopFlag) -> Void = { stop in
                Self.repeatUntil(stop, minimum: 500) {
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
            let broadcaster: @Sendable (StopFlag) -> Void = { stop in
                Self.repeatUntil(stop, minimum: 200) { client.updateConfig(freshConfig) }
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

/// Set once by the task that sees the last request finish, read by the work running alongside.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
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

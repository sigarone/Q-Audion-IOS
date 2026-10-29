import XCTest
@testable import QAudionEngine

/// The signalling socket's backoff must keep growing for a connection that authenticates and is then torn
/// down within seconds, and start over only for one that held.
final class WebSocketReconnectPolicyTests: XCTestCase {

    private let window = WebSocketReconnectPolicy.stabilityWindowSec

    func testTheWindowIsAboutAMinute() {
        XCTAssertEqual(window, 60)
    }

    // MARK: - attempt counter

    func testAttemptIsNotResetWhenTheSocketDiesBeforeTheWindow() {
        var attempt = 0
        var now: TimeInterval = 1_000
        // The production pattern: authenticate, drop 13 s later, again and again.
        for _ in 0..<6 {
            let authenticatedAt = now
            now += 13
            attempt = WebSocketReconnectPolicy.attemptAfterDrop(current: attempt, authenticatedAt: authenticatedAt, now: now)
            attempt += 1
        }
        XCTAssertEqual(attempt, 6, "six short-lived sockets in a row must count as six attempts")
        XCTAssertEqual(WebSocketReconnectPolicy.delay(forAttempt: attempt, jitterFraction: 0), 30,
                       "and the wait reaches the 30 s cap instead of staying near one second")
    }

    func testAttemptIsResetOnceTheSocketHeldForTheWindow() {
        let reset = WebSocketReconnectPolicy.attemptAfterDrop(current: 5, authenticatedAt: 100, now: 100 + window)
        XCTAssertEqual(reset, 0)
        let afterLongSocket = WebSocketReconnectPolicy.attemptAfterDrop(current: 5, authenticatedAt: 100, now: 100 + 3_600)
        XCTAssertEqual(afterLongSocket, 0)
    }

    func testAttemptIsKeptJustBeforeTheWindow() {
        XCTAssertEqual(WebSocketReconnectPolicy.attemptAfterDrop(current: 5, authenticatedAt: 100, now: 100 + window - 0.1), 5)
    }

    func testASocketThatNeverAuthenticatedNeverResetsTheCounter() {
        XCTAssertEqual(WebSocketReconnectPolicy.attemptAfterDrop(current: 3, authenticatedAt: nil, now: 10_000), 3)
    }

    // MARK: - delay curve (unchanged: 1 s doubling to a 30 s cap, +-25 % jitter, floor 0.5 s)

    func testDelayDoublesUpToTheCap() {
        let delays = (1...8).map { WebSocketReconnectPolicy.delay(forAttempt: $0, jitterFraction: 0) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testDelayJitterStaysWithinAQuarterAndAboveTheFloor() {
        XCTAssertEqual(WebSocketReconnectPolicy.delay(forAttempt: 4, jitterFraction: 0.25), 10, accuracy: 0.0001)
        XCTAssertEqual(WebSocketReconnectPolicy.delay(forAttempt: 4, jitterFraction: -0.25), 6, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(WebSocketReconnectPolicy.delay(forAttempt: 1, jitterFraction: -0.25), 0.5)
    }

    // MARK: - immediate paths do not consult the delay

    /// A deliberate reconnect (`forceReconnect()`, `connect()`, a call that needs the socket) never goes
    /// through `delay(forAttempt:)`; only `handleDisconnect`'s timer does. The only thing it takes from the
    /// policy is the counter settle, which can only lower the count.
    func testSettlingTheCounterNeverRaisesIt() {
        for current in [0, 1, 4, 9] {
            for at in [nil, 0.0, 50.0, 100.0] as [TimeInterval?] {
                let out = WebSocketReconnectPolicy.attemptAfterDrop(current: current, authenticatedAt: at, now: 100)
                XCTAssertLessThanOrEqual(out, current)
            }
        }
    }

    // MARK: - drop log line

    func testDropLineCarriesReasonAgeAndAttemptAsPlainTokens() {
        let line = WebSocketReconnectPolicy.disconnectLine(
            domain: NSURLErrorDomain, code: -1005, closeCode: 0, socketAgeSec: 12.6, attempt: 4)
        XCTAssertEqual(line, "[BCryptoWS] ws drop kind=1 code=-1005 status=0 age=13s attempts=4")
    }

    func testDropLineWithoutAnErrorUsesZero() {
        let line = WebSocketReconnectPolicy.disconnectLine(domain: nil, code: 0, closeCode: 1006, socketAgeSec: -3, attempt: 1)
        XCTAssertEqual(line, "[BCryptoWS] ws drop kind=0 code=0 status=1006 age=0s attempts=1")
    }

    func testDomainKindsAreFromAFixedList() {
        XCTAssertEqual(WebSocketReconnectPolicy.domainKind(NSURLErrorDomain), 1)
        XCTAssertEqual(WebSocketReconnectPolicy.domainKind(NSPOSIXErrorDomain), 2)
        XCTAssertEqual(WebSocketReconnectPolicy.domainKind("kCFErrorDomainCFNetwork"), 3)
        XCTAssertEqual(WebSocketReconnectPolicy.domainKind("SomeCustomDomain.with.free.text"), 9)
    }

    // MARK: - refresh debounce

    func testRefreshIsDueWhenNothingCompletedYet() {
        XCTAssertTrue(ReconnectRefreshDebounce().isDue(now: 500))
    }

    func testRefreshIsSkippedInsideTheWindowAndDueAfterIt() {
        var debounce = ReconnectRefreshDebounce()
        debounce.markCompleted(at: 1_000)
        XCTAssertFalse(debounce.isDue(now: 1_013))
        XCTAssertFalse(debounce.isDue(now: 1_059.9))
        XCTAssertTrue(debounce.isDue(now: 1_060))
        XCTAssertTrue(debounce.isDue(now: 2_000))
    }

    func testRefreshIsDueWhenTheClockWentBackwards() {
        var debounce = ReconnectRefreshDebounce()
        debounce.markCompleted(at: 1_000)
        XCTAssertTrue(debounce.isDue(now: 900))
    }

    // MARK: - wiring of the client

    func testAuthenticationKeepsTheBackoffAndClearsTheFailoverCount() {
        let r = WebSocketReconnectPolicy.afterAuthentication(attempt: 4, failoverAttempt: 2, now: 500)
        XCTAssertEqual(r.attempt, 4)
        XCTAssertEqual(r.failoverAttempt, 0)
        XCTAssertEqual(r.authenticatedAt, 500)
        // A socket that dies seconds after authenticating keeps the count; one that held starts over.
        XCTAssertEqual(WebSocketReconnectPolicy.attemptAfterDrop(current: r.attempt, authenticatedAt: r.authenticatedAt, now: 513), 4)
        XCTAssertEqual(WebSocketReconnectPolicy.attemptAfterDrop(current: r.attempt, authenticatedAt: r.authenticatedAt, now: 561), 0)
    }

    /// The client must not put the old reset back in its `authenticated` handler, and both places that settle the
    /// count on a drop (`handleDisconnect`, `forceReconnect`) must go through the policy.
    func testClientDoesNotResetTheBackoffOnAuthentication() throws {
        let source = try clientSource()
        let start = try XCTUnwrap(source.range(of: "if type == \"authenticated\" {"))
        let tail = source[start.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n        if type == \"pong\""))
        let handler = String(tail[..<end.lowerBound])
        XCTAssertFalse(handler.contains("reconnectAttempt = 0"), "authenticated handler resets the backoff")
        XCTAssertTrue(handler.contains("WebSocketReconnectPolicy.afterAuthentication"))
        XCTAssertEqual(source.components(separatedBy: "WebSocketReconnectPolicy.attemptAfterDrop(").count - 1, 2,
                       "handleDisconnect and forceReconnect both settle through the policy")
    }

    private func clientSource() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }   // .../QAudionEngine
        let url = root.appendingPathComponent("Sources/QAudionEngine/Backend/BCrypto/BCryptoWebSocketClient.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

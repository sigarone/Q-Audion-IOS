import XCTest
@testable import QAudionEngine

/// Rules 8 and 9 of `AuthRefreshCoordinator.swift`: the background-time guard around each
/// flight, and the refresh token whose last send was never answered.
final class AuthBackgroundFlightTests: XCTestCase {

    // MARK: - helpers

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _lines: [String] = []
        private var _refreshes = 0
        private var _renews = 0
        private var next = 0

        func begin() -> Int {
            lock.withLock {
                next += 1
                _events.append("begin\(next)")
                return next
            }
        }
        func end(_ token: Int) { lock.withLock { _events.append("end\(token)") } }
        func event(_ e: String) { lock.withLock { _events.append(e) } }
        func log(_ line: String) { lock.withLock { _lines.append(line) } }
        func refreshed() { lock.withLock { _refreshes += 1 } }
        func renewed() { lock.withLock { _renews += 1 } }
        var events: [String] { lock.withLock { _events } }
        var text: String { lock.withLock { _lines.joined(separator: "\n") } }
        var refreshes: Int { lock.withLock { _refreshes } }
        var renews: Int { lock.withLock { _renews } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 2_000_000)
        var now: Date { lock.withLock { t } }
        func advance(by s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    private final class Hang: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let go: Bool = lock.withLock {
                    if released { return true }
                    waiting.append(c)
                    return false
                }
                if go { c.resume() }
            }
        }
        func release() {
            let w: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                let all = waiting
                waiting = []
                return all
            }
            for c in w { c.resume() }
        }
    }

    private func makeCoordinator(clock: Clock = Clock(), deadline: TimeInterval = 60,
                                 guarded: Bool = true) -> (AuthRefreshCoordinator, Recorder) {
        let rec = Recorder()
        let c = AuthRefreshCoordinator(now: { clock.now }, flightDeadlineSec: deadline)
        c.setLogger { _, line in rec.log(line) }
        if guarded { c.setBackgroundGuard(begin: { rec.begin() }, end: { rec.end($0) }) }
        return (c, rec)
    }

    private func request(store: AuthCredentialStore?,
                         refresher: @escaping AuthRefreshRequest.Refresher,
                         renewer: AuthRefreshRequest.Renewer? = nil,
                         forced: Bool = false) -> AuthRefreshRequest {
        AuthRefreshRequest(trigger: forced ? .proactive : .rest401, staleAccessToken: "A0",
                           callerRefreshToken: store == nil ? "R0" : nil,
                           store: store, refresher: refresher, renewer: renewer, ignoreCooldown: forced)
    }

    private let ok = AuthTokenSet(accessToken: "A1", refreshToken: "R1", expiresInSec: 900)
    /// A refresh whose request may have reached the server but was never answered.
    private let unanswered = AuthRecoveryFailure(reason: .refreshNetwork, requestMayHaveReached: true)

    private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - rule 8: the guard

    func test_guardWrapsASuccessfulFlightFromBeforeTheRequestUntilItIsStored() async {
        let (c, rec) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let tokens = ok
        let out = await c.refresh(request(store: store, refresher: { _ in
            rec.event("send")
            return tokens
        }))
        XCTAssertTrue(out.isSuccess)
        XCTAssertEqual(try store.load(), AuthStoredCredentials(access: "A1", refresh: "R1"))
        let seen = await eventually { rec.events.count == 3 }
        XCTAssertTrue(seen, "\(rec.events)")
        XCTAssertEqual(rec.events, ["begin1", "send", "end1"])
    }

    func test_guardIsClosedOnceAFlightFails() async {
        let (c, rec) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let out = await c.refresh(request(store: store, refresher: { _ in throw failure }))
        XCTAssertFalse(out.isSuccess)
        let seen = await eventually { rec.events.count == 2 }
        XCTAssertTrue(seen, "\(rec.events)")
        XCTAssertEqual(rec.events, ["begin1", "end1"])
    }

    func test_guardFollowsTheWorkOfAFlightCutAtItsDeadline() async {
        let (c, rec) = makeCoordinator(deadline: 0.3)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let hang = Hang()
        defer { hang.release() }
        let tokens = ok
        let out = await c.refresh(request(store: store, refresher: { _ in
            await hang.wait()
            return tokens
        }))
        XCTAssertEqual(out.failure?.reason, .flightTimeout)
        XCTAssertEqual(rec.events, ["begin1"], "the request may still be on the wire: the guard stays open")

        hang.release()
        let closed = await eventually { rec.events.contains("end1") }
        XCTAssertTrue(closed, "\(rec.events)")
        XCTAssertEqual(rec.events, ["begin1", "end1"])
    }

    func test_everyFlightGetsItsOwnBeginAndEnd() async {
        let (c, rec) = makeCoordinator()
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = AuthRecoveryFailure(reason: .refreshRejected, status: 401)
        _ = await c.refresh(request(store: store, refresher: { _ in throw failure }))
        c.resetBackoff()
        _ = await c.refresh(request(store: store, refresher: { _ in throw failure }))
        let seen = await eventually { rec.events.count == 4 }
        XCTAssertTrue(seen, "\(rec.events)")
        XCTAssertEqual(rec.events.filter { $0.hasPrefix("begin") }.count, 2)
        XCTAssertEqual(rec.events.filter { $0.hasPrefix("end") }.count, 2)
    }

    // MARK: - rule 9: an unanswered send

    func test_unansweredSendRetriedAfterTenSecondsGoesStraightToRenew() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let tokens = ok

        let first = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            throw failure
        }))
        XCTAssertEqual(first.failure?.reason, .refreshNetwork)
        XCTAssertEqual(rec.refreshes, 1)

        clock.advance(by: 20)   // past the 5 s cooldown and the 10 s limit
        let second = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            return tokens
        }))
        XCTAssertEqual(rec.refreshes, 1, "the unanswered token is not presented again")
        XCTAssertEqual(rec.renews, 1)
        guard case .refreshed(_, let path) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(path, .deviceRenew)
        XCTAssertTrue(rec.text.contains("reason=send_unconfirmed age_s=20 limit_s=8"), rec.text)
    }

    func test_unansweredSendRetriedWithinTenSecondsStillUsesRefresh() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let tokens = ok

        _ = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            throw failure
        }))
        clock.advance(by: 6)   // past the cooldown, inside the limit
        let second = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            return tokens
        }))
        XCTAssertEqual(rec.refreshes, 2)
        XCTAssertEqual(rec.renews, 0)
        guard case .refreshed(_, let path) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(path, .refresh)
        XCTAssertFalse(rec.text.contains("send_unconfirmed"), rec.text)
    }

    func test_aDefinitiveAnswerClearsTheRecord() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let busy = AuthRecoveryFailure(reason: .refreshServerError, status: 500)
        let tokens = ok

        _ = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            throw failure
        }))
        clock.advance(by: 6)
        _ = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            throw busy   // the server answered
        }))
        clock.advance(by: 60)
        let third = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            return tokens
        }))
        XCTAssertEqual(rec.refreshes, 3, "an answered send leaves nothing to distrust")
        XCTAssertEqual(rec.renews, 0)
        XCTAssertTrue(third.isSuccess)
        XCTAssertFalse(rec.text.contains("send_unconfirmed"), rec.text)
    }

    func test_aFailureThatSentNothingLeavesNoRecord() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let offline = AuthRecoveryFailure(reason: .refreshNetwork)
        let tokens = ok

        _ = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            throw offline
        }))
        clock.advance(by: 120)
        let second = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }))
        XCTAssertEqual(rec.refreshes, 2)
        XCTAssertTrue(second.isSuccess)
    }

    /// A 2xx whose body cannot be read: the server rotated the pair, the token is spent.
    func test_anUnreadableSuccessBodyCountsAsAnUnansweredSend() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let tokens = ok
        let bad = AuthFailureClassifier.classifyRefresh(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "body")))
        XCTAssertTrue(bad.requestMayHaveReached)

        _ = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            throw bad
        }))
        clock.advance(by: 20)
        let second = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            return tokens
        }))
        XCTAssertEqual(rec.refreshes, 1)
        XCTAssertEqual(rec.renews, 1)
        XCTAssertTrue(second.isSuccess)
    }

    /// The woken app: the pending request fails long after it was sent.
    func test_aRequestThatFailsAfterTheLimitHealsThroughRenewInTheSameFlight() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let tokens = ok
        let out = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            clock.advance(by: 30)   // suspended, then the old request fails
            throw failure
        }, renewer: {
            rec.renewed()
            return tokens
        }))
        XCTAssertEqual(rec.refreshes, 1)
        XCTAssertEqual(rec.renews, 1)
        guard case .refreshed(_, let path) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(path, .deviceRenew)
        XCTAssertTrue(rec.text.contains("renew_next=1"), rec.text)
    }

    /// A repeat of the same token must not move the anchor of the first send.
    func test_aRepeatedSendDoesNotMoveTheAnchor() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let tokens = ok

        _ = await c.refresh(request(store: store, refresher: { _ in rec.refreshed(); throw failure }))
        clock.advance(by: 6)
        _ = await c.refresh(request(store: store, refresher: { _ in rec.refreshed(); throw failure }, forced: true))
        XCTAssertEqual(rec.refreshes, 2)
        clock.advance(by: 4)   // 10 s after the first send, 4 s after the second
        let third = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            return tokens
        }, forced: true))
        XCTAssertEqual(rec.refreshes, 2, "measured from the first send")
        XCTAssertEqual(rec.renews, 1)
        XCTAssertTrue(third.isSuccess)
    }

    func test_aClientWithoutAStoreIsNeverMadeFinalByAnUnansweredSend() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let failure = unanswered

        _ = await c.refresh(request(store: nil, refresher: { _ in rec.refreshed(); throw failure }))
        clock.advance(by: 20)
        let second = await c.refresh(request(store: nil, refresher: { _ in rec.refreshed(); throw failure }))
        XCTAssertEqual(rec.refreshes, 2, "no renew leg: the refresh is still tried")
        XCTAssertEqual(second.failure?.isFinal, false)
        XCTAssertEqual(second.failure?.reason, .refreshNetwork)
    }

    /// While the renew leg is cooling down, an old unanswered token is still better than nothing.
    func test_whenRenewIsCoolingDownTheRefreshIsStillTried() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let tokens = ok
        let renewRejected = AuthRecoveryFailure(reason: .renewRejected, status: 401)

        _ = await c.refresh(request(store: store, refresher: { _ in rec.refreshed(); throw failure }))
        clock.advance(by: 20)
        let second = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            throw renewRejected   // spends the renew budget: cooldown starts
        }))
        XCTAssertEqual(rec.refreshes, 1)
        XCTAssertEqual(rec.renews, 1)
        XCTAssertFalse(second.isSuccess)

        clock.advance(by: 10)
        let third = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            return tokens
        }, forced: true))
        XCTAssertEqual(rec.refreshes, 2)
        XCTAssertEqual(rec.renews, 1, "the renew cooldown holds")
        XCTAssertTrue(third.isSuccess)
    }

    /// With the renew leg cooling down, a refresh that fails late keeps the network ladder instead of parking on the renew cooldown.
    func test_aLateFailureWhileRenewIsCoolingDownKeepsTheNetworkRetry() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let renewRejected = AuthRecoveryFailure(reason: .renewRejected, status: 401)

        _ = await c.refresh(request(store: store, refresher: { _ in rec.refreshed(); throw failure }))
        clock.advance(by: 20)
        _ = await c.refresh(request(store: store, refresher: { _ in rec.refreshed(); throw failure }, renewer: {
            rec.renewed()
            throw renewRejected   // spends the renew budget: cooldown starts
        }))
        XCTAssertEqual(rec.renews, 1)

        clock.advance(by: 10)
        let third = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            clock.advance(by: 15)   // a request timeout
            throw failure
        }, renewer: {
            rec.renewed()
            return self.ok
        }, forced: true))
        XCTAssertEqual(rec.refreshes, 2)
        XCTAssertEqual(rec.renews, 1, "the renew cooldown holds")
        XCTAssertEqual(third.failure?.reason, .refreshNetwork)
    }

    func test_resetBackoffClearsTheRecord() async {
        let clock = Clock()
        let (c, rec) = makeCoordinator(clock: clock, guarded: false)
        let store = InMemoryAuthCredentialStore(access: "A0", refresh: "R0")
        let failure = unanswered
        let tokens = ok

        _ = await c.refresh(request(store: store, refresher: { _ in rec.refreshed(); throw failure }))
        c.resetBackoff()
        clock.advance(by: 20)
        let second = await c.refresh(request(store: store, refresher: { _ in
            rec.refreshed()
            return tokens
        }, renewer: {
            rec.renewed()
            return tokens
        }))
        XCTAssertEqual(rec.refreshes, 2)
        XCTAssertEqual(rec.renews, 0)
        XCTAssertTrue(second.isSuccess)
    }

    func test_classifierFlagsOnlyRequestsThatMayHaveReachedTheServer() {
        for code in [URLError.timedOut, .networkConnectionLost, .cancelled, .badServerResponse] {
            XCTAssertTrue(AuthFailureClassifier.classifyRefresh(URLError(code)).requestMayHaveReached, "\(code)")
        }
        XCTAssertTrue(AuthFailureClassifier.classifyRefresh(CancellationError()).requestMayHaveReached)
        XCTAssertTrue(AuthFailureClassifier.classifyRefresh(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))).requestMayHaveReached)
        for code in [URLError.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertFalse(AuthFailureClassifier.classifyRefresh(URLError(code)).requestMayHaveReached, "\(code)")
        }
        XCTAssertFalse(AuthFailureClassifier.classifyRefresh(BCryptoError.unauthorized).requestMayHaveReached)
    }
}

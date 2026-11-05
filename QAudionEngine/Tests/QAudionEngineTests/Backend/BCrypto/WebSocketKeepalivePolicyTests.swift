import XCTest
@testable import QAudionEngine

final class WebSocketKeepalivePolicyTests: XCTestCase {

    typealias Policy = WebSocketKeepalivePolicy

    /// Runs the policy the way the client does (one decision per tick) for a socket that went silent right
    /// after an inbound frame at t=0, and returns the time of the dead verdict.
    private func verdictTime(ping: TimeInterval, pong: TimeInterval, limit: TimeInterval) -> TimeInterval? {
        let tick = Policy.tickInterval(ping: ping, pongTimeout: pong)
        var lastPing: TimeInterval = 0
        var now: TimeInterval = 0
        while now < limit {
            now += tick
            switch Policy.decide(now: now, lastInbound: 0, lastPingSent: lastPing, pingInterval: ping, pongTimeout: pong) {
            case .sendPing: lastPing = now
            case .declareDead: return now
            case .wait: break
            }
        }
        return nil
    }

    func test_tickIsFinerThanThePingIntervalButNeverBelowFiveSeconds() {
        XCTAssertEqual(Policy.tickInterval(ping: 20, pongTimeout: 30), 5)
        XCTAssertEqual(Policy.tickInterval(ping: 60, pongTimeout: 120), 20)
        XCTAssertEqual(Policy.tickInterval(ping: 3, pongTimeout: 120), 3)
    }

    func test_idleSocketGetsAPingAfterTheInterval() {
        XCTAssertEqual(Policy.decide(now: 100, lastInbound: 100, lastPingSent: 100, pingInterval: 60, pongTimeout: 120), .wait)
        XCTAssertEqual(Policy.decide(now: 160, lastInbound: 100, lastPingSent: 100, pingInterval: 60, pongTimeout: 120), .sendPing)
    }

    func test_answeredPingIsNotOutstanding() {
        XCTAssertEqual(Policy.decide(now: 400, lastInbound: 399, lastPingSent: 380, pingInterval: 60, pongTimeout: 120), .wait)
    }

    func test_cellularTimingDeclaresDeadWithinPingPlusPongPlusOneTick() {
        let at = verdictTime(ping: 60, pong: 120, limit: 600)
        XCTAssertNotNil(at)
        XCTAssertLessThanOrEqual(at ?? .infinity, 60 + 120 + 20)
        XCTAssertLessThan(at ?? .infinity, 575, "far below the 575 s seen on a device")
    }

    func test_wifiTimingDeclaresDeadWithinAMinute() {
        let at = verdictTime(ping: 20, pong: 30, limit: 300)
        XCTAssertNotNil(at)
        XCTAssertLessThanOrEqual(at ?? .infinity, 20 + 30 + 5)
    }

    func test_noSecondPingWhileOneIsOutstanding() {
        XCTAssertEqual(Policy.decide(now: 40, lastInbound: 0, lastPingSent: 20, pingInterval: 20, pongTimeout: 30), .wait)
        XCTAssertEqual(Policy.decide(now: 50, lastInbound: 0, lastPingSent: 20, pingInterval: 20, pongTimeout: 30), .declareDead)
    }

    /// The verdict is measured from the first unanswered ping: for both real profiles it falls exactly
    /// `pingInterval + pongTimeout` after the last inbound frame.
    func test_deadSocketVerdictIsExactlyPingPlusPongForBothProfiles() {
        XCTAssertEqual(verdictTime(ping: 20, pong: 30, limit: 300), 50)
        XCTAssertEqual(verdictTime(ping: 60, pong: 120, limit: 600), 180)
    }

    /// A pong that arrives before the deadline keeps the socket alive and restarts the cycle.
    func test_latePongBeforeTheDeadlineKeepsTheSocketAlive() {
        for (ping, pong) in [(20.0, 30.0), (60.0, 120.0)] {
            let tick = Policy.tickInterval(ping: ping, pongTimeout: pong)
            var lastInbound: TimeInterval = 0
            var lastPing: TimeInterval = 0
            var now: TimeInterval = 0
            var answeredAt: TimeInterval?
            while now < 3 * (ping + pong) {
                now += tick
                if let at = answeredAt, now >= at { lastInbound = at; answeredAt = nil }
                switch Policy.decide(now: now, lastInbound: lastInbound, lastPingSent: lastPing, pingInterval: ping, pongTimeout: pong) {
                case .sendPing:
                    lastPing = now
                    answeredAt = now + pong - tick
                case .declareDead:
                    XCTFail("declared dead at (now) although every pong arrived before its deadline")
                    return
                case .wait: break
                }
            }
        }
    }

    func test_longSilenceWithoutAnyPingIsStillDead() {
        XCTAssertEqual(Policy.decide(now: 1000, lastInbound: 0, lastPingSent: 990, pingInterval: 60, pongTimeout: 120), .declareDead)
    }

    /// Re-timing the keepalive (Wi-Fi to cellular and back) must not move the silence clock: the verdict uses
    /// the real time of the last inbound frame, whatever the cadence is at that moment.
    func test_changingCadenceDoesNotPostponeTheVerdict() {
        XCTAssertEqual(Policy.decide(now: 200, lastInbound: 0, lastPingSent: 60, pingInterval: 20, pongTimeout: 30), .declareDead)
        XCTAssertEqual(Policy.decide(now: 170, lastInbound: 0, lastPingSent: 150, pingInterval: 60, pongTimeout: 120), .wait,
                       "inside the relaxed cellular window")
        XCTAssertEqual(Policy.decide(now: 170, lastInbound: 0, lastPingSent: 150, pingInterval: 20, pongTimeout: 30), .declareDead,
                       "back on Wi-Fi the same 170 s of silence is dead, not a fresh start")
    }
}

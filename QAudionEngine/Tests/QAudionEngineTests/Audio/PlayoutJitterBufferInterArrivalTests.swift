import XCTest
@testable import QAudionEngine

/// W-HBTELEM (2026-09-21) — `PlayoutJitterBuffer.recentInterArrivalMaxMs`, the read-only
/// view behind the `iat_max_ms` heartbeat attribute: the largest gap between two
/// consecutive arrivals over a recent window. It reads the lateness ring the adaptive
/// target already keeps, so it must agree with the arrivals that were pushed and add
/// nothing to the arrival path. Time is an injected monotonic clock: nothing sleeps.
final class PlayoutJitterBufferInterArrivalTests: XCTestCase {

    private final class Clock {
        var seconds: Double = 1.0
        func advanceMs(_ ms: Double) { seconds += ms / 1000.0 }
    }

    private func buffer(_ clock: Clock) -> PlayoutJitterBuffer {
        PlayoutJitterBuffer(nowSeconds: { clock.seconds })
    }

    private func voiceFrame() -> Data {
        var d = Data(count: 960 * 2)
        d.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<960 { p[i] = i % 2 == 0 ? 8000 : -8000 }
        }
        return d
    }

    /// Push `count` frames, advancing the clock by `gapMs` BEFORE each push, and keep the
    /// queue shallow so overruns never enter the picture.
    private func pushCadence(_ jb: PlayoutJitterBuffer, _ clock: Clock, count: Int, gapMs: Double) {
        for _ in 0..<count {
            clock.advanceMs(gapMs)
            jb.push(voiceFrame())
            if jb.depth > 4 { _ = jb.popWithDriftCatchup() }
        }
    }

    private var cadenceMs: Double { Double(AudioConstants.frameDurationMs) }

    func test_isNilUntilThereAreTwoArrivals() {
        let clock = Clock()
        let jb = buffer(clock)
        XCTAssertNil(jb.recentInterArrivalMaxMs(windowMs: 5_000))
        jb.push(voiceFrame())
        XCTAssertNil(jb.recentInterArrivalMaxMs(windowMs: 5_000), "one arrival has no gap yet")
        clock.advanceMs(cadenceMs)
        jb.push(voiceFrame())
        XCTAssertNotNil(jb.recentInterArrivalMaxMs(windowMs: 5_000))
    }

    func test_aSteadyStreamReadsItsOwnCadence() {
        let clock = Clock()
        let jb = buffer(clock)
        jb.push(voiceFrame())
        pushCadence(jb, clock, count: 60, gapMs: cadenceMs)
        XCTAssertEqual(jb.recentInterArrivalMaxMs(windowMs: 5_000), AudioConstants.frameDurationMs)
    }

    func test_reportsTheLargestGapInTheWindow() {
        let clock = Clock()
        let jb = buffer(clock)
        jb.push(voiceFrame())
        pushCadence(jb, clock, count: 30, gapMs: cadenceMs)
        pushCadence(jb, clock, count: 1, gapMs: 200)      // the stall
        pushCadence(jb, clock, count: 30, gapMs: cadenceMs)
        XCTAssertEqual(jb.recentInterArrivalMaxMs(windowMs: 5_000), 200)
    }

    func test_earlyArrivalsDoNotMakeTheMaximumSmallerThanTheCadence() {
        let clock = Clock()
        let jb = buffer(clock)
        jb.push(voiceFrame())
        pushCadence(jb, clock, count: 20, gapMs: 5)
        XCTAssertEqual(jb.recentInterArrivalMaxMs(windowMs: 5_000), AudioConstants.frameDurationMs)
    }

    func test_aGapOlderThanTheWindowIsForgotten() {
        let clock = Clock()
        let jb = buffer(clock)
        jb.push(voiceFrame())
        pushCadence(jb, clock, count: 1, gapMs: 200)      // the stall
        pushCadence(jb, clock, count: 100, gapMs: cadenceMs)
        // 100 arrivals after the stall span far more than a 1 s window at any frame duration...
        XCTAssertEqual(jb.recentInterArrivalMaxMs(windowMs: 1_000), AudioConstants.frameDurationMs)
        // ...but well inside a 5 s one.
        XCTAssertEqual(jb.recentInterArrivalMaxMs(windowMs: 5_000), 200)
    }

    func test_aWindowShorterThanOneFrameStillLooksAtTheNewestArrival() {
        let clock = Clock()
        let jb = buffer(clock)
        jb.push(voiceFrame())
        pushCadence(jb, clock, count: 1, gapMs: 300)
        XCTAssertEqual(jb.recentInterArrivalMaxMs(windowMs: 1), 300)
    }

    func test_theReadDoesNotDisturbTheBuffer() {
        let clock = Clock()
        let jb = buffer(clock)
        jb.push(voiceFrame())
        pushCadence(jb, clock, count: 10, gapMs: cadenceMs)
        let pushedBefore = jb.pushed
        let depthBefore = jb.depth
        _ = jb.recentInterArrivalMaxMs(windowMs: 5_000)
        XCTAssertEqual(jb.pushed, pushedBefore)
        XCTAssertEqual(jb.depth, depthBefore)
    }
}

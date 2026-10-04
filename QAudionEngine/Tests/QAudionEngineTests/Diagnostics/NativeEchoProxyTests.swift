import XCTest
@testable import QAudionEngine

/// CALL-METRICS (2026-10-04) -- the native-path echo-suspect proxy. It is a proxy (level of the microphone while the
/// far end plays versus while it is silent), never an ERLE.
final class NativeEchoProxyTests: XCTestCase {

    private func feed(_ p: inout NativeEchoProxy, farLoud: Bool, near: Float, frames: Int, startMs: inout Int64) {
        for _ in 0..<frames {
            startMs += 10
            p.noteFar(rms: farLoud ? 0.2 : 0.0, nowMs: startMs)
            p.noteNear(rms: near, nowMs: startMs)
        }
    }

    func test_aMicLouderWhileTheFarEndPlaysIsFlagged() {
        var p = NativeEchoProxy()
        var t: Int64 = 1_000
        feed(&p, farLoud: true, near: 0.06, frames: 200, startMs: &t)     // far end plays, mic hears it back
        t += 1_000                                                         // far end falls silent for good
        feed(&p, farLoud: false, near: 0.004, frames: 200, startMs: &t)   // room noise only
        let w = p.closeWindow()
        XCTAssertGreaterThanOrEqual(w.activeFrames, 50)
        XCTAssertGreaterThanOrEqual(w.idleFrames, 50)
        XCTAssertTrue(w.evaluated)
        XCTAssertTrue(w.suspect)
        XCTAssertEqual(w.farCallbacks, 400)
        XCTAssertEqual(NativeEchoProxy.dbfs(w.activeRms), -24)
    }

    func test_aCleanMicLevelWhileTheFarEndPlaysIsNotFlagged() {
        var p = NativeEchoProxy()
        var t: Int64 = 1_000
        feed(&p, farLoud: true, near: 0.005, frames: 200, startMs: &t)
        t += 1_000
        feed(&p, farLoud: false, near: 0.005, frames: 200, startMs: &t)
        XCTAssertFalse(p.closeWindow().suspect)
    }

    func test_tooFewFramesInABucketIsNeverAJudgement() {
        var p = NativeEchoProxy()
        var t: Int64 = 1_000
        feed(&p, farLoud: true, near: 0.5, frames: 20, startMs: &t)
        t += 1_000
        feed(&p, farLoud: false, near: 0.001, frames: 400, startMs: &t)
        let w = p.closeWindow()
        XCTAssertFalse(w.evaluated)
        XCTAssertFalse(w.suspect)
    }

    func test_anInaudibleActiveBucketIsNotCalledEchoWhateverTheRatio() {
        // 0.006 is 6x the idle floor but still below -40 dBFS.
        XCTAssertFalse(NativeEchoProxy.isSuspect(activeRms: 0.006, idleRms: 0.0, activeFrames: 100, idleFrames: 100))
        XCTAssertTrue(NativeEchoProxy.isSuspect(activeRms: 0.03, idleRms: 0.0, activeFrames: 100, idleFrames: 100),
                      "digital-silence idle is floored at 0.002, so a clearly audible active bucket still counts")
        XCTAssertFalse(NativeEchoProxy.isSuspect(activeRms: 0.03, idleRms: 0.02, activeFrames: 100, idleFrames: 100),
                       "1.5x is room, not echo")
        XCTAssertFalse(NativeEchoProxy.isSuspect(activeRms: nil, idleRms: 0.01, activeFrames: 100, idleFrames: 100))
    }

    func test_theFarEndHoldIsTwoHundredMilliseconds() {
        XCTAssertTrue(NativeEchoProxy.isFarActive(lastLoudFarMs: 1_000, nowMs: 1_200))
        XCTAssertFalse(NativeEchoProxy.isFarActive(lastLoudFarMs: 1_000, nowMs: 1_201))
        XCTAssertFalse(NativeEchoProxy.isFarActive(lastLoudFarMs: 0, nowMs: 5), "never loud = never active")
        XCTAssertFalse(NativeEchoProxy.isFarActive(lastLoudFarMs: 2_000, nowMs: 1_000), "a clock that went back is not active")
    }

    func test_aQuietFarFrameDoesNotRefreshTheActiveStamp() {
        var p = NativeEchoProxy()
        p.noteFar(rms: 0.005, nowMs: 1_000)     // below the loud threshold
        p.noteNear(rms: 0.1, nowMs: 1_010)
        let w = p.closeWindow()
        XCTAssertEqual(w.activeFrames, 0)
        XCTAssertEqual(w.idleFrames, 1)
    }

    func test_ifTheRenderHookNeverFiresTheProbeSaysSo() {
        var p = NativeEchoProxy()
        for i in 0..<300 { p.noteNear(rms: 0.05, nowMs: Int64(1_000 + i * 10)) }
        let w = p.closeWindow()
        XCTAssertEqual(w.farCallbacks, 0)
        XCTAssertEqual(w.activeFrames, 0)
        XCTAssertFalse(w.suspect)
    }

    func test_callReportAddsTheClosedWindowsAndTheOpenOne() {
        var p = NativeEchoProxy()
        var t: Int64 = 1_000
        feed(&p, farLoud: true, near: 0.06, frames: 100, startMs: &t)
        t += 1_000
        feed(&p, farLoud: false, near: 0.004, frames: 100, startMs: &t)
        let w1 = p.closeWindow()
        XCTAssertTrue(w1.suspect)
        feed(&p, farLoud: false, near: 0.004, frames: 30, startMs: &t)     // still-open window
        let c = p.callReport()
        XCTAssertEqual(c.windowsEvaluated, 1)
        XCTAssertEqual(c.windowsSuspect, 1)
        XCTAssertEqual(c.activeFrames, w1.activeFrames)
        XCTAssertEqual(c.idleFrames, w1.idleFrames + 30)
        XCTAssertEqual(c.farCallbacks, w1.farCallbacks + 30)
    }

    func test_rmsIsTheRootOfTheMeanSquareNotTheMeanOfTheRms() {
        // two frames: rms 0.1 and rms 0.3 -> sqrt((0.01 + 0.09) / 2) = 0.2236
        let r = NativeEchoProxy.rms(sumSq: 0.01 + 0.09, frames: 2)
        XCTAssertEqual(r ?? 0, 0.2236, accuracy: 0.0001)
        XCTAssertNil(NativeEchoProxy.rms(sumSq: 0, frames: 0))
    }

    func test_dbfsOfFullScaleHalfScaleAndSilence() {
        XCTAssertEqual(NativeEchoProxy.dbfs(1.0), 0)
        XCTAssertEqual(NativeEchoProxy.dbfs(0.5), -6)
        XCTAssertEqual(NativeEchoProxy.dbfs(0.01), -40)
        XCTAssertNil(NativeEchoProxy.dbfs(0))
        XCTAssertNil(NativeEchoProxy.dbfs(nil))
    }

    func test_frameRmsReadsWebRtcsFloatS16ScaleAsAFractionOfFullScale() {
        let loud = [Float](repeating: 16_384, count: 480)        // half of full scale, constant
        loud.withUnsafeBufferPointer {
            XCTAssertEqual(NativeEchoProxy.rmsOfFloatS16($0), 0.5, accuracy: 0.0001)
        }
        let silent = [Float](repeating: 0, count: 480)
        silent.withUnsafeBufferPointer { XCTAssertEqual(NativeEchoProxy.rmsOfFloatS16($0), 0) }
        let empty: [Float] = []
        empty.withUnsafeBufferPointer { XCTAssertEqual(NativeEchoProxy.rmsOfFloatS16($0), 0) }
    }

    func test_theProbeNeverBlocksAndResetsPerCall() {
        let probe = NativeEchoProbe()
        probe.noteFar(rms: 0.2)
        probe.noteNear(rms: 0.1)
        let w = probe.closeWindow()
        XCTAssertEqual(w.activeFrames + w.idleFrames, 1)
        XCTAssertEqual(probe.callReport().farCallbacks, 1)
        probe.resetForNewCall()
        XCTAssertEqual(probe.callReport().farCallbacks, 0)
        XCTAssertEqual(probe.callReport().activeFrames + probe.callReport().idleFrames, 0)
    }
}

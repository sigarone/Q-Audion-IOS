import XCTest
import Foundation
@testable import QAudionEngine

/// W-VPIOWD (2026-09-25) -- pins the two decisions behind the W-AEC-FIX VP-IO watchdog fix, without a
/// live audio session (same shape as `AudioCaptureNoiseAdaptiveAgcTests`' W-VPIORETRY section).
///
/// THE BUG. The watchdog is a one-shot 1.2 s timer that judged "whatever engine exists when it
/// fires". Call 7727f262 (2026-09-23, iPhone): `audioIO started` at 17:07:10.82, an `.override` route
/// change 0.69 s later triggered a full rebuild (a second start with VP-IO), and the FIRST start's
/// timer then judged the SECOND engine at 0.5 s of age -> "starved" -> bypass for the rest of a
/// six-minute speakerphone call. Two independent causes, two independent fixes:
///
///  * a timer of an older engine generation must do nothing (`starveVerdict`);
///  * an `.override` that leaves the effective route as the engine was built for must not rebuild
///    the engine (`isOverrideNoOp`) -- while a REAL speakerphone toggle, which changes the route,
///    must keep restarting it.
final class VpioWatchdogDecisionsTests: XCTestCase {

    private typealias WD = VpioWatchdogDecisions

    // MARK: - Watchdog verdict

    /// The 7727f262 shape: a timer of generation 1 expires while the current engine (generation 2)
    /// has not delivered yet because it is only 0.5 s old. It must NOT be judged.
    func testAnOlderGenerationNeverJudgesTheCurrentEngine() {
        XCTAssertEqual(WD.starveVerdict(armedGen: 1, currentGen: 2, isRunning: true, firstFrameReceived: false),
                       .stale,
                       "the timer of a replaced engine judged the new engine — the 7727f262 false starve is back")
    }

    /// Stale beats every other state: whatever the current engine is doing, the old timer has no say.
    func testStaleWinsOverEveryOtherState() {
        for running in [true, false] {
            for delivered in [true, false] {
                XCTAssertEqual(WD.starveVerdict(armedGen: 3, currentGen: 5, isRunning: running,
                                                firstFrameReceived: delivered),
                               .stale)
            }
        }
    }

    func testTheCurrentGenerationIsJudgedOnItsOwnState() {
        XCTAssertEqual(WD.starveVerdict(armedGen: 2, currentGen: 2, isRunning: true, firstFrameReceived: false), .starved)
        XCTAssertEqual(WD.starveVerdict(armedGen: 2, currentGen: 2, isRunning: true, firstFrameReceived: true), .delivering)
        XCTAssertEqual(WD.starveVerdict(armedGen: 2, currentGen: 2, isRunning: false, firstFrameReceived: false), .notRunning)
        XCTAssertEqual(WD.starveVerdict(armedGen: 2, currentGen: 2, isRunning: false, firstFrameReceived: true), .notRunning,
                       "an engine that is not running is never judged, even if it delivered once")
    }

    /// The genuine iPad W574f starve must still be caught: one start, nothing replaced it, nothing arrived.
    func testAGenuineStarveOnAStableEngineStillFires() {
        XCTAssertEqual(WD.starveVerdict(armedGen: 1, currentGen: 1, isRunning: true, firstFrameReceived: false), .starved)
    }

    /// Replay of call 7727f262 as the generation counter sees it: start (gen 1) arms timer 1; a rebuild
    /// 0.69 s later is start (gen 2) and arms timer 2. Timer 1 expires first and is ignored; timer 2
    /// expires 1.2 s after the SECOND start and only then may judge the second engine.
    func testCallSevenSevenTwoSevenReplay() {
        var gen = 0
        gen += 1
        let timer1 = gen
        gen += 1
        let timer2 = gen
        XCTAssertEqual(WD.starveVerdict(armedGen: timer1, currentGen: gen, isRunning: true, firstFrameReceived: false),
                       .stale)
        XCTAssertEqual(WD.starveVerdict(armedGen: timer2, currentGen: gen, isRunning: true, firstFrameReceived: false),
                       .starved)
        // ...and had the second engine delivered in its own window, it is kept.
        XCTAssertEqual(WD.starveVerdict(armedGen: timer2, currentGen: gen, isRunning: true, firstFrameReceived: true),
                       .delivering)
    }

    /// `stop()` bumps the generation, so a timer armed for a torn-down engine cannot act on a later one.
    func testAStopSupersedesAnArmedTimer() {
        var gen = 1
        let armed = gen
        gen += 1   // stop()
        XCTAssertEqual(WD.starveVerdict(armedGen: armed, currentGen: gen, isRunning: true, firstFrameReceived: false), .stale)
    }

    // MARK: - `.override` no-op

    private func port(_ type: String, _ uid: String) -> WD.RoutePort {
        return WD.RoutePort(type: type, uid: uid)
    }

    private var receiverRoute: WD.RouteSignature {
        return WD.RouteSignature(inputs: [port("MicrophoneBuiltIn", "Built-In Microphone")],
                                 outputs: [port("Receiver", "Built-In Receiver")],
                                 speaker: false)
    }

    private var speakerRoute: WD.RouteSignature {
        return WD.RouteSignature(inputs: [port("MicrophoneBuiltIn", "Built-In Microphone")],
                                 outputs: [port("Speaker", "Built-In Speaker")],
                                 speaker: true)
    }

    /// The 7727f262 notification: 0.69 s after the start, same ports, same speaker flag (only the mic
    /// data source moved, which the signature does not carry) -> no rebuild.
    func testAnUnchangedRouteJustAfterAStartIsANoOp() {
        XCTAssertTrue(WD.isOverrideNoOp(msSinceStartEnded: 690, built: receiverRoute, current: receiverRoute))
        XCTAssertTrue(WD.isOverrideNoOp(msSinceStartEnded: 690, built: speakerRoute, current: speakerRoute))
        XCTAssertTrue(WD.isOverrideNoOp(msSinceStartEnded: 0, built: speakerRoute, current: speakerRoute))
    }

    /// THE GUARD RAIL: a real speakerphone toggle changes the outputs and the speaker flag, so it is
    /// never a no-op — in either direction, at any moment inside the window.
    func testARealSpeakerToggleIsNeverANoOp() {
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 50, built: receiverRoute, current: speakerRoute),
                       "receiver -> speaker right after start (AppState's W-CALLSPKR re-assert) must still rebuild")
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 690, built: speakerRoute, current: receiverRoute))
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 1_400, built: receiverRoute, current: speakerRoute))
    }

    /// Only the speaker flag differs (same port list): still a change.
    func testTheSpeakerFlagAloneCountsAsAChange() {
        let flagged = WD.RouteSignature(inputs: receiverRoute.inputs, outputs: receiverRoute.outputs, speaker: true)
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 100, built: receiverRoute, current: flagged))
    }

    /// A headset / Bluetooth input appearing, or a uid changing, is a change.
    func testAnInputChangeIsNeverANoOp() {
        let bluetooth = WD.RouteSignature(inputs: [port("BluetoothHFP", "AA-BB-CC")],
                                          outputs: receiverRoute.outputs,
                                          speaker: false)
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 100, built: receiverRoute, current: bluetooth))
        let otherUid = WD.RouteSignature(inputs: [port("MicrophoneBuiltIn", "Other Microphone")],
                                         outputs: receiverRoute.outputs,
                                         speaker: false)
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 100, built: receiverRoute, current: otherUid))
    }

    func testTheOutputListIsComparedInOrderAndInFull() {
        let two = WD.RouteSignature(inputs: receiverRoute.inputs,
                                    outputs: [port("Receiver", "Built-In Receiver"), port("BluetoothA2DPOutput", "AA-BB")],
                                    speaker: false)
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 100, built: receiverRoute, current: two))
    }

    /// The window is measured from the end of the latest start; outside it the pre-existing behaviour
    /// (throttled restart) applies untouched, even for an unchanged route.
    func testTheWindowIsBounded() {
        XCTAssertEqual(WD.overrideSettleWindowMs, 1_500)
        XCTAssertTrue(WD.isOverrideNoOp(msSinceStartEnded: WD.overrideSettleWindowMs,
                                        built: receiverRoute, current: receiverRoute))
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: WD.overrideSettleWindowMs + 1,
                                         built: receiverRoute, current: receiverRoute))
        XCTAssertTrue(WD.isOverrideNoOp(msSinceStartEnded: 40, built: receiverRoute, current: receiverRoute, windowMs: 40))
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 41, built: receiverRoute, current: receiverRoute, windowMs: 40))
    }

    /// Fails OPEN: anything unknown means "restart as before".
    func testUnknownInputsFailOpen() {
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: -1, built: receiverRoute, current: receiverRoute),
                       "no start recorded yet")
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 100, built: nil, current: receiverRoute))
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 100, built: receiverRoute, current: nil))
        XCTAssertFalse(WD.isOverrideNoOp(msSinceStartEnded: 100, built: nil, current: nil))
    }

    // MARK: - Log lines and ledger

    func testStaleLine() {
        XCTAssertEqual(WD.staleLine(gen: 1, cur: 2, firstFrame: false, sinceStartMs: 500),
                       "audioVp ev=stale gen=1 cur=2 ff=0 since_start_ms=500")
        XCTAssertEqual(WD.staleLine(gen: 1, cur: 2, firstFrame: true, sinceStartMs: 500),
                       "audioVp ev=stale gen=1 cur=2 ff=1 since_start_ms=500")
    }

    func testOverrideNoOpLine() {
        XCTAssertEqual(WD.overrideNoOpLine(gen: 1, sinceStartMs: 686), "audioVp ev=noop gen=1 since_start_ms=686")
    }

    /// Same redactor rule as the other `audioVp` lines: after the tag only `key=digits` tokens and the
    /// single `ev=` word.
    func testLinesStayNumeric() {
        let lines: [String] = [
            WD.staleLine(gen: 12, cur: 13, firstFrame: true, sinceStartMs: VpioObservability.maxMs),
            WD.overrideNoOpLine(gen: 12, sinceStartMs: 0)
        ]
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 80)
            let tokens = line.split(separator: " ").map { String($0) }
            XCTAssertEqual(tokens.first, "audioVp")
            for token in tokens.dropFirst() {
                let parts = token.split(separator: "=").map { String($0) }
                XCTAssertEqual(parts.count, 2, "not key=value: " + token)
                guard parts.count == 2 else { continue }
                if parts[0] == "ev" {
                    XCTAssertTrue(["stale", "noop"].contains(parts[1]))
                } else {
                    XCTAssertTrue(parts[1].allSatisfy { $0.isNumber || $0 == "-" }, "not numeric: " + token)
                }
            }
        }
    }

    /// An ignored stale expiry is counted, and is not counted as a restart.
    func testAnIgnoredStaleExpiryIsNotARestart() {
        var l = VpioObservability.Ledger()
        l.noteArmed()
        l.noteStaleExpiry()
        XCTAssertEqual(l.starveStale, 1)
        XCTAssertEqual(l.starveFired, 0)
        let attrs = VpioObservability.diagAttrs(ledger: l, gen: 2, env: nil)
        XCTAssertEqual(attrs["vpio_starve_stale"] as? Int, 1)
        XCTAssertEqual(attrs["vpio_starve_fired"] as? Int, 0)
        XCTAssertNil(attrs["vpio_starve_gen"], "no restart happened, so there is no restart generation to report")
    }
}

import XCTest
@testable import QAudionEngine

/// CALL-METRICS (2026-10-04) -- extremes, route ledger and lines, the sentinel-free heartbeat lines and the native
/// call.audio.diag attribute set. Pure logic, no audio session.
final class CallMetricsTests: XCTestCase {

    // MARK: - field() never prints a sentinel

    func test_aMissingValueIsOmittedNeverPrintedAsMinusOne() {
        XCTAssertEqual(CallMetricsLines.field("lost", -1), "")
        XCTAssertEqual(CallMetricsLines.field("jitter", -1000), "")
        XCTAssertEqual(CallMetricsLines.field("lost", Int64(-1)), "")
        XCTAssertEqual(CallMetricsLines.field("rtt", Int?.none), "")
        XCTAssertEqual(CallMetricsLines.field("plc", Int64?.none), "")
        XCTAssertEqual(CallMetricsLines.field("lost", 0), " lost=0", "a real zero is kept")
        XCTAssertEqual(CallMetricsLines.field("jitter", 7), " jitter=7")
        XCTAssertEqual(CallMetricsLines.field("plc", Int64(93_600)), " plc=93600")
    }

    // MARK: - extremes tracker

    func test_extremesKeepTheMaximumOfTheIntervalNotTheLastValue() {
        var t = IntervalExtremesTracker()
        t.note(rttMs: 8, jitterSec: 0.002, remoteRttSec: 0.020, lostCumulative: 0, concealedCumulative: 0)
        t.note(rttMs: 337, jitterSec: 0.070, remoteRttSec: 0.050, lostCumulative: 0, concealedCumulative: 0)
        t.note(rttMs: 9, jitterSec: 0.003, remoteRttSec: 0.020, lostCumulative: 0, concealedCumulative: 0)
        let e = t.drain()
        XCTAssertEqual(e.samples, 3)
        XCTAssertEqual(e.rttMaxMs, 337)
        XCTAssertEqual(e.jitterMaxMs, 70)
        XCTAssertEqual(e.remoteRttMaxMs, 50)
        XCTAssertEqual(e.lostMax, 0)
        XCTAssertEqual(e.plcMax, 0)
    }

    func test_lossBurstIsTheLargestPerSampleDeltaOfTheCumulativeCounter() {
        var t = IntervalExtremesTracker()
        for lost in [Int64(10), 10, 14, 14, 15] {
            t.note(rttMs: nil, jitterSec: nil, remoteRttSec: nil, lostCumulative: lost, concealedCumulative: nil)
        }
        let e = t.drain()
        XCTAssertEqual(e.lostMax, 4, "10 -> 14 is the biggest single step")
        XCTAssertNil(e.rttMaxMs, "no rtt sample -> omitted, not 0")
    }

    func test_theFirstSampleOfACallHasNoDelta() {
        var t = IntervalExtremesTracker()
        t.note(rttMs: nil, jitterSec: nil, remoteRttSec: nil, lostCumulative: 500, concealedCumulative: 90_000)
        let e = t.drain()
        XCTAssertNil(e.lostMax, "a cumulative counter that starts at 500 is not 500 lost in one second")
        XCTAssertNil(e.plcMax)
    }

    func test_aCounterThatGoesDownRebaselinesInsteadOfAFakeDelta() {
        var t = IntervalExtremesTracker()
        t.note(rttMs: nil, jitterSec: nil, remoteRttSec: nil, lostCumulative: 100, concealedCumulative: 5_000)
        // ICE restart: the stats object is replaced and the counters restart low.
        t.note(rttMs: nil, jitterSec: nil, remoteRttSec: nil, lostCumulative: 3, concealedCumulative: 480)
        t.note(rttMs: nil, jitterSec: nil, remoteRttSec: nil, lostCumulative: 5, concealedCumulative: 960)
        let e = t.drain()
        XCTAssertEqual(e.lostMax, 2)
        XCTAssertEqual(e.plcMax, 480)
    }

    func test_concealmentSpikeIsCapturedEvenWhenTheIntervalEndsQuiet() {
        var t = IntervalExtremesTracker()
        var c: Int64 = 0
        t.note(rttMs: nil, jitterSec: nil, remoteRttSec: nil, lostCumulative: nil, concealedCumulative: c)
        for step in [Int64(0), 93_600, 0, 0, 0] {
            c += step
            t.note(rttMs: nil, jitterSec: nil, remoteRttSec: nil, lostCumulative: nil, concealedCumulative: c)
        }
        XCTAssertEqual(t.drain().plcMax, 93_600)
    }

    func test_sentinelsAndGarbageInputsAreNeverFolded() {
        var t = IntervalExtremesTracker()
        t.note(rttMs: -1, jitterSec: -1, remoteRttSec: -1, lostCumulative: -1, concealedCumulative: -1)
        t.note(rttMs: .nan, jitterSec: .infinity, remoteRttSec: 1e12, lostCumulative: nil, concealedCumulative: nil)
        let e = t.drain()
        XCTAssertEqual(e.samples, 2)
        XCTAssertNil(e.rttMaxMs)
        XCTAssertNil(e.jitterMaxMs)
        XCTAssertNil(e.remoteRttMaxMs)
        XCTAssertNil(e.lostMax)
        XCTAssertNil(e.plcMax)
        XCTAssertEqual(CallMetricsLines.extremesFields(e), " sample=2")
    }

    func test_drainStartsANewIntervalAndTheCallMaximaAccumulate() {
        var t = IntervalExtremesTracker()
        t.note(rttMs: 100, jitterSec: nil, remoteRttSec: nil, lostCumulative: nil, concealedCumulative: nil)
        _ = t.drain()
        t.note(rttMs: 40, jitterSec: nil, remoteRttSec: nil, lostCumulative: nil, concealedCumulative: nil)
        let second = t.drain()
        XCTAssertEqual(second.rttMaxMs, 40, "the second interval does not inherit the first one's maximum")
        XCTAssertEqual(t.callMax.rttMaxMs, 100)
        XCTAssertEqual(t.callMax.samples, 2)
        // A sample taken after the last drain still counts for the call.
        t.note(rttMs: 900, jitterSec: nil, remoteRttSec: nil, lostCumulative: nil, concealedCumulative: nil)
        XCTAssertEqual(t.callMaxIncludingOpenInterval().rttMaxMs, 900)
        XCTAssertEqual(t.callMax.rttMaxMs, 100)
    }

    func test_extremesFieldsAreInAFixedOrder() {
        var e = IntervalExtremes()
        e.samples = 5
        e.rttMaxMs = 12
        e.jitterMaxMs = 3
        e.remoteRttMaxMs = 21
        e.lostMax = 0
        e.plcMax = 960
        XCTAssertEqual(CallMetricsLines.extremesFields(e),
                       " rtt_max=12 jitter_max=3 remote_rtt_max=21 lost_max=0 plc_max=960 sample=5")
    }

    // MARK: - hb=2 / hb=3 lines

    func test_hb2KeepsTheOldFieldNamesAndOrderAndAppendsTheExtremes() {
        var e = IntervalExtremes()
        e.samples = 5
        e.rttMaxMs = 12
        e.lostMax = 1
        let line = CallMetricsLines.hb2(rttMs: 7, jitterBufferMs: 77, targetMs: 80, plc: 0, fecRecv: 44, fecDrop: 45,
                                        nack: 0, remoteLossPermille: 0, remoteRttMs: 20, relayCode: 0,
                                        networkTypeCode: 1, extremes: e)
        XCTAssertEqual(line, "audiosrtp hb=2 rtt=7 jitter_ms=77 target_ms=80 plc=0 fec_recv=44 fec_drop=45 nack=0"
                             + " remote_loss=0 remote_rtt=20 relay=0 network_type=1 rtt_max=12 lost_max=1 sample=5")
    }

    func test_hb2OfTheFirstHeartbeatHasNoSentinelAtAll() {
        let line = CallMetricsLines.hb2(rttMs: -1, jitterBufferMs: -1, targetMs: -1, plc: -1, fecRecv: -1, fecDrop: -1,
                                        nack: -1, remoteLossPermille: -1, remoteRttMs: -1, relayCode: 0,
                                        networkTypeCode: 0, extremes: IntervalExtremes())
        XCTAssertEqual(line, "audiosrtp hb=2 relay=0 network_type=0")
        XCTAssertFalse(line.contains("-1"))
    }

    func test_hb3OnTheNativePathCarriesVpioDuckAndTheEchoProxy() {
        var w = NativeEchoProxy.WindowReport()
        w.activeFrames = 120
        w.idleFrames = 380
        w.farCallbacks = 500
        w.activeRms = 0.0708     // -23 dBFS
        w.idleRms = 0.0089       // -41 dBFS
        w.evaluated = true
        w.suspect = true
        let line = CallMetricsLines.hb3(engine: 1, vpio: true, duck: false, echo: w)
        XCTAssertEqual(line, "audiosrtp hb=3 eng=1 vpio=1 duck=0 echo_active_frames=120 echo_idle_frames=380"
                             + " echo_far_frames=500 echo_active_db=-23 echo_idle_db=-41 echo_suspect=1")
    }

    func test_hb3OmitsTheLevelsOfAnEmptyBucketAndTheWholeEchoBlockOnTheLegacyEngine() {
        var w = NativeEchoProxy.WindowReport()
        w.idleFrames = 500
        w.idleRms = 0.01
        let native = CallMetricsLines.hb3(engine: 1, vpio: true, duck: false, echo: w)
        XCTAssertFalse(native.contains("echo_active_db"), "an empty bucket has no level, not 0 dB and not -200")
        XCTAssertTrue(native.contains("echo_idle_db=-40"))
        XCTAssertTrue(native.contains("echo_far_frames=0"), "frames are always shown, so a blind probe is visible")
        let legacy = CallMetricsLines.hb3(engine: 2, vpio: false, duck: true, echo: nil)
        XCTAssertEqual(legacy, "audiosrtp hb=3 eng=2 vpio=0 duck=1")
    }

    // MARK: - route

    func test_bluetoothProfileSeparatesHandsFreeFromA2dpAndLe() {
        XCTAssertEqual(CallRouteDiagnostics.bluetoothProfile(outputPort: "BluetoothHFP", inputPort: "BluetoothHFP"), 1)
        XCTAssertEqual(CallRouteDiagnostics.bluetoothProfile(outputPort: "BluetoothA2DPOutput", inputPort: "MicrophoneBuiltIn"), 2)
        XCTAssertEqual(CallRouteDiagnostics.bluetoothProfile(outputPort: "BluetoothLE", inputPort: "BluetoothLE"), 3)
        XCTAssertEqual(CallRouteDiagnostics.bluetoothProfile(outputPort: "Receiver", inputPort: "MicrophoneBuiltIn"), 0)
        XCTAssertEqual(CallRouteDiagnostics.bluetoothProfile(outputPort: "BluetoothA2DPOutput", inputPort: "BluetoothHFP"), 1,
                       "an HFP input forces the voice link whatever the output says")
        XCTAssertEqual(CallRouteDiagnostics.bluetoothProfile(outputPort: nil, inputPort: nil), 0)
    }

    func test_routeLineForAHandsFreeSwitchShowsTheSixteenKilohertzMonoLink() {
        let line = CallRouteDiagnostics.routeLine(reason: 1, previousOutputPort: "Receiver", outputPort: "BluetoothHFP",
                                                  inputPort: "BluetoothHFP", sampleRateHz: 16_000,
                                                  outputChannels: 1, inputChannels: 1, volume: 0.5)
        XCTAssertEqual(line, "audioroute why=1 old=1 out=3 in=3 profile=1 sr=16000 out_ch=1 in_ch=1 vol=50")
    }

    func test_routeLineOmitsWhatCannotBeRead() {
        let line = CallRouteDiagnostics.routeLine(reason: 2, previousOutputPort: nil, outputPort: "Speaker",
                                                  inputPort: "MicrophoneBuiltIn", sampleRateHz: 0,
                                                  outputChannels: 0, inputChannels: 0, volume: .nan)
        XCTAssertEqual(line, "audioroute why=2 out=2 in=1 profile=0")
        XCTAssertFalse(line.contains("-1"))
    }

    func test_ledgerCountsChangesNotSamplesAndRemembersTheNarrowestRate() {
        var l = CallRouteLedger()
        XCTAssertFalse(l.note(outputPort: "Receiver", inputPort: "MicrophoneBuiltIn", sampleRateHz: 48_000, isChange: false))
        XCTAssertTrue(l.note(outputPort: "BluetoothHFP", inputPort: "BluetoothHFP", sampleRateHz: 16_000, isChange: true))
        XCTAssertTrue(l.note(outputPort: "Speaker", inputPort: "MicrophoneBuiltIn", sampleRateHz: 48_000, isChange: true))
        XCTAssertEqual(l.changes, 2)
        XCTAssertTrue(l.hfpEver)
        XCTAssertTrue(l.bluetoothEver)
        XCTAssertFalse(l.a2dpEver)
        XCTAssertTrue(l.speakerEver)
        XCTAssertEqual(l.minSampleRateHz, 16_000)
        XCTAssertEqual(l.lastSampleRateHz, 48_000)
        XCTAssertEqual(l.lastOutputPort, "Speaker")
    }

    func test_aForcedSampleIsLoggedOnceButNotCountedAsAChange() {
        var l = CallRouteLedger()
        XCTAssertTrue(l.note(outputPort: "Receiver", inputPort: nil, sampleRateHz: 48_000, isChange: false, force: true))
        XCTAssertEqual(l.changes, 0)
    }

    func test_routeLinesPerCallAreCapped() {
        var l = CallRouteLedger()
        var logged = 0
        for _ in 0..<(CallRouteLedger.maxLines + 25) {
            if l.note(outputPort: "Receiver", inputPort: nil, sampleRateHz: 48_000, isChange: true) { logged += 1 }
        }
        XCTAssertEqual(logged, CallRouteLedger.maxLines)
        XCTAssertEqual(l.changes, CallRouteLedger.maxLines + 25, "the count keeps going after the lines stop")
    }

    // MARK: - state holder

    func test_stateHolderClosesIntervalsAndOffersTheMidCallSlotOnce() {
        let s = CallMetricsState()
        XCTAssertFalse(s.hasHeartbeats)
        s.noteSample(rttMs: 50, jitterSec: nil, remoteRttSec: nil, lostCumulative: nil, concealedCumulative: nil, native: false)
        XCTAssertFalse(s.sawNativeCall)
        s.noteSample(rttMs: 10, jitterSec: nil, remoteRttSec: nil, lostCumulative: nil, concealedCumulative: nil, native: true)
        XCTAssertTrue(s.sawNativeCall, "latches for the call")
        let first = s.closeInterval()
        XCTAssertEqual(first.heartbeat, 1)
        XCTAssertEqual(first.extremes.rttMaxMs, 50)
        XCTAssertTrue(s.hasHeartbeats)
        XCTAssertFalse(s.takeMidCallDiagSlot())
        _ = s.closeInterval()
        _ = s.closeInterval()
        XCTAssertTrue(s.takeMidCallDiagSlot())
        XCTAssertFalse(s.takeMidCallDiagSlot(), "once per call")
        s.reset()
        XCTAssertFalse(s.hasHeartbeats)
        XCTAssertFalse(s.sawNativeCall)
        _ = s.closeInterval(); _ = s.closeInterval(); _ = s.closeInterval()
        XCTAssertTrue(s.takeMidCallDiagSlot(), "a new call gets its own slot")
    }

    // MARK: - native call.audio.diag

    func test_nativeDiagAlwaysCarriesTheEchoFramesAndOmitsWhatWasNotMeasured() {
        let attrs = NativeCallAudioDiag.attrs(final: true, heartbeats: 0, echo: NativeEchoProxy.CallReport(),
                                              callMax: IntervalExtremes(), route: CallRouteLedger(),
                                              vpioConfigured: true)
        XCTAssertEqual(attrs["diag_final"] as? Bool, true)
        XCTAssertEqual(attrs["diag_native"] as? Bool, true)
        XCTAssertEqual(attrs["echo_active_frames"] as? Int64, 0)
        XCTAssertEqual(attrs["echo_idle_frames"] as? Int64, 0)
        XCTAssertNil(attrs["echo_active_rms_pct"], "an empty bucket has no level")
        XCTAssertNil(attrs["rtt_max_ms"])
        XCTAssertNil(attrs["granted_sr"])
        XCTAssertNil(attrs["vpio_ever_active"], "unknown on the native path: never a false that reads as bypassed")
        XCTAssertNil(attrs["vpio_bypassed_ever"])
        XCTAssertEqual(attrs["vpio_cfg"] as? Bool, true)
    }

    func test_nativeDiagUsesTheLegacyEchoNamesAndUnits() {
        var echo = NativeEchoProxy.CallReport()
        echo.activeFrames = 1200
        echo.idleFrames = 5000
        echo.activeRms = 0.0234
        echo.idleRms = 0.0081
        echo.windowsEvaluated = 40
        echo.windowsSuspect = 3
        var ledger = CallRouteLedger()
        ledger.note(outputPort: "BluetoothHFP", inputPort: "BluetoothHFP", sampleRateHz: 16_000, isChange: true)
        var mx = IntervalExtremes()
        mx.rttMaxMs = 730
        mx.jitterMaxMs = 70
        mx.lostMax = 3
        mx.plcMax = 93_600
        let attrs = NativeCallAudioDiag.attrs(final: false, heartbeats: 60, echo: echo, callMax: mx, route: ledger,
                                              vpioConfigured: true)
        XCTAssertEqual(attrs["diag_final"] as? Bool, false)
        XCTAssertEqual(attrs["echo_active_rms_pct"] as? Double, 2.3)
        XCTAssertEqual(attrs["echo_idle_rms_pct"] as? Double, 0.8)
        XCTAssertEqual(attrs["echo_suspect_win"] as? Int, 3)
        XCTAssertEqual(attrs["echo_eval_win"] as? Int, 40)
        XCTAssertEqual(attrs["rtt_max_ms"] as? Int, 730)
        XCTAssertEqual(attrs["plc_max"] as? Int64, 93_600)
        XCTAssertEqual(attrs["route_changes"] as? Int, 1)
        XCTAssertEqual(attrs["bt_hfp_ever"] as? Bool, true)
        XCTAssertEqual(attrs["min_sr"] as? Int, 16_000)
        XCTAssertEqual(attrs["output_route"] as? String, "BluetoothHFP")
    }

    // MARK: - audible concealment (hb=4)

    func test_hb4SplitsTotalConcealmentIntoSilentAndAudibleInMilliseconds() {
        // A quiet peer: the whole 5 s window concealed (240000 samples), all of it while the sender was silent.
        XCTAssertEqual(CallMetricsLines.hb4(concealedDelta: 240_000, silentDelta: 240_000, eventsDelta: 1),
                       "audiosrtp hb=4 plc_silent_ms=5000 plc_audible_ms=0 plc_event=1")
        XCTAssertEqual(CallMetricsLines.hb4(concealedDelta: 4_800, silentDelta: 0, eventsDelta: 3),
                       "audiosrtp hb=4 plc_silent_ms=0 plc_audible_ms=100 plc_event=3")
    }

    func test_hb4OmitsWhatIsMissingOrInconsistent() {
        XCTAssertEqual(CallMetricsLines.hb4(concealedDelta: -1, silentDelta: -1, eventsDelta: 2), "audiosrtp hb=4 plc_event=2")
        XCTAssertEqual(CallMetricsLines.hb4(concealedDelta: 100, silentDelta: 200, eventsDelta: -1), nil)
        XCTAssertNil(CallMetricsLines.hb4(concealedDelta: -1, silentDelta: -1, eventsDelta: -1))
    }
}

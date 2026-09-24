import XCTest
import Foundation
@testable import QAudionEngine

/// W-VPIOOBS (2026-09-25) -- pins the VP-IO observability package: the clock arithmetic, the numeric
/// log lines, the per-call ledger and the `call.audio.diag` attribute set.
///
/// WHY IT EXISTS. On the test iPhone Apple's Voice-Processing I/O never delivered a
/// tap buffer inside the W-AEC-FIX window on 71 of 71 built-in-mic calls, and nothing recorded how long
/// the tap takes when it does deliver, which engine generation a watchdog timer belonged to, or what the
/// hardware / OS / mic mode / port list / tap format looked like. Every number below feeds one of those
/// answers, so a renamed key or a shifted origin would silently make the next telemetry pull unreadable.
///
/// Pure arithmetic and string building only (plus `sysctlbyname`), so it needs no live audio session.
final class VpioObservabilityTests: XCTestCase {

    private typealias Obs = VpioObservability

    // MARK: - elapsedMs

    func testUnsetStampsAreUnknown() {
        XCTAssertEqual(Obs.elapsedMs(from: 0, to: 500), -1)
        XCTAssertEqual(Obs.elapsedMs(from: 500, to: 0), -1)
        XCTAssertEqual(Obs.elapsedMs(from: 0, to: 0), -1)
    }

    func testNormalInterval() {
        XCTAssertEqual(Obs.elapsedMs(from: 1_000, to: 1_412), 412)
    }

    /// A tap buffer can land before `start()` returns; the interval is then 0, never negative.
    func testFrameBeforeTheEndOfStartIsZero() {
        XCTAssertEqual(Obs.elapsedMs(from: 2_000, to: 1_990), 0)
        XCTAssertEqual(Obs.elapsedMs(from: 2_000, to: 2_000), 0)
    }

    /// The log shipper keeps `key=digits` tokens of at most 7 digits; the clamp keeps every value there.
    func testIntervalIsClamped() {
        XCTAssertEqual(Obs.elapsedMs(from: 1_000, to: 5_000_000), Obs.maxMs)
        XCTAssertLessThanOrEqual(String(Obs.maxMs).count, 7)
    }

    // MARK: - Log lines

    func testArmLine() {
        XCTAssertEqual(Obs.armLine(gen: 3, engMs: 12), "audioVp ev=arm gen=3 since_start_ms=0 eng_ms=12")
    }

    func testFirstFrameLine() {
        XCTAssertEqual(Obs.firstFrameLine(gen: 3, ms: 412, engMs: 430), "audioVp ev=ff gen=3 ms=412 eng_ms=430")
    }

    func testFireLine() {
        XCTAssertEqual(Obs.fireLine(gen: 3, sinceStartMs: 1_204, stale: false, engineRunning: true),
                       "audioVp ev=fire gen=3 since_start_ms=1204 stale=0 er=1")
        XCTAssertEqual(Obs.fireLine(gen: 2, sinceStartMs: 810, stale: true, engineRunning: false),
                       "audioVp ev=fire gen=2 since_start_ms=810 stale=1 er=0")
    }

    func testConfigChangeLine() {
        XCTAssertEqual(Obs.configChangeLine(gen: 2, sinceEngineMs: 150), "audioVp ev=cfg gen=2 eng_ms=150")
    }

    /// The shipper's redactor drops a body with free multi-word text and keeps `key=number` tokens and
    /// `ev=<lower-case word>`. Every line must stay in that shape: after the `audioVp` tag, only
    /// `key=digits` tokens (a `-1` for "unknown" is allowed) plus the single `ev=` word.
    func testEveryLineIsNumericAndCompact() {
        let lines: [String] = [
            Obs.armLine(gen: 12, engMs: -1),
            Obs.firstFrameLine(gen: 12, ms: 0, engMs: Obs.maxMs),
            Obs.fireLine(gen: 12, sinceStartMs: 1_204, stale: true, engineRunning: false),
            Obs.configChangeLine(gen: 12, sinceEngineMs: 300)
        ]
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 80, "compact")
            let tokens = line.split(separator: " ").map { String($0) }
            XCTAssertEqual(tokens.first, "audioVp")
            for token in tokens.dropFirst() {
                let parts = token.split(separator: "=").map { String($0) }
                XCTAssertEqual(parts.count, 2, "not key=value: " + token)
                guard parts.count == 2 else { continue }
                if parts[0] == "ev" {
                    XCTAssertTrue(["arm", "ff", "fire", "cfg"].contains(parts[1]), "unknown event word")
                } else {
                    XCTAssertTrue(parts[1].allSatisfy { $0.isNumber || $0 == "-" }, "not numeric: " + token)
                }
            }
        }
    }

    // MARK: - Ledger

    func testTheFirstArmedStartAndTheLatestOneAreKeptApart() {
        var l = Obs.Ledger()
        l.noteArmed()
        l.noteFirstFrame(ms: 412, engMs: 430)
        l.noteArmed()   // e.g. the route-driven retry
        l.noteFirstFrame(ms: 90, engMs: 100)
        XCTAssertEqual(l.armedStarts, 2)
        XCTAssertEqual(l.firstStartFrameMs, 412)
        XCTAssertEqual(l.firstStartFrameEngMs, 430)
        XCTAssertEqual(l.lastStartFrameMs, 90)
    }

    /// The device this was built for: the first start starves, the retry delivers. The first-start
    /// figure must stay "never delivered" and not be overwritten by the retry's.
    func testAStarvedFirstStartStaysUnset() {
        var l = Obs.Ledger()
        l.noteArmed()
        l.noteStarve(gen: 1, sinceStartMs: 1_204, stale: false)
        l.noteArmed()
        l.noteFirstFrame(ms: 60, engMs: 75)
        XCTAssertEqual(l.firstStartFrameMs, -1)
        XCTAssertEqual(l.firstStartFrameEngMs, -1)
        XCTAssertEqual(l.lastStartFrameMs, 60)
        XCTAssertEqual(l.starveFired, 1)
        XCTAssertEqual(l.starveStale, 0)
        XCTAssertEqual(l.lastStarveGen, 1)
        XCTAssertEqual(l.lastStarveMs, 1_204)
    }

    /// A new armed start forgets the previous start's "last" figure, so a start that never delivers
    /// reads -1 and not the earlier start's value.
    func testANewStartResetsTheLastFrameFigure() {
        var l = Obs.Ledger()
        l.noteArmed()
        l.noteFirstFrame(ms: 300, engMs: 310)
        l.noteArmed()
        XCTAssertEqual(l.lastStartFrameMs, -1)
        XCTAssertEqual(l.firstStartFrameMs, 300)
    }

    func testStaleExpiriesAreCountedSeparately() {
        var l = Obs.Ledger()
        l.noteArmed()
        l.noteStarve(gen: 1, sinceStartMs: 690, stale: true)
        XCTAssertEqual(l.starveFired, 1)
        XCTAssertEqual(l.starveStale, 1)
    }

    func testConfigChangesCountOnlyInsideTheFirstTwoSeconds() {
        var l = Obs.Ledger()
        l.noteConfigChange(sinceEngineMs: 0)
        l.noteConfigChange(sinceEngineMs: Obs.configWindowMs)
        l.noteConfigChange(sinceEngineMs: Obs.configWindowMs + 1)
        l.noteConfigChange(sinceEngineMs: -1)
        XCTAssertEqual(l.cfgChanges2s, 2)
        XCTAssertEqual(Obs.configWindowMs, 2_000)
    }

    // MARK: - Attributes

    /// A call in which VP-IO never armed (or the ledger is empty) still says so, and invents nothing.
    func testEmptyLedgerAttrs() {
        let attrs = Obs.diagAttrs(ledger: Obs.Ledger(), gen: 0, env: nil)
        XCTAssertEqual(Set(attrs.keys),
                       Set(["vpio_watchdog_gen", "vpio_starts", "vpio_starve_fired",
                            "vpio_starve_stale", "engine_cfg_changes_2s"]))
        XCTAssertEqual(attrs["vpio_watchdog_gen"] as? Int, 0)
        XCTAssertEqual(attrs["vpio_starts"] as? Int, 0)
        XCTAssertEqual(attrs["vpio_starve_fired"] as? Int, 0)
    }

    func testStarvedCallAttrs() {
        var l = Obs.Ledger()
        l.noteArmed()
        l.noteStarve(gen: 3, sinceStartMs: 1_204, stale: false)
        let attrs = Obs.diagAttrs(ledger: l, gen: 4, env: nil)
        XCTAssertEqual(attrs["vpio_watchdog_gen"] as? Int, 4)
        XCTAssertEqual(attrs["vpio_starts"] as? Int, 1)
        XCTAssertEqual(attrs["vpio_starve_fired"] as? Int, 1)
        XCTAssertEqual(attrs["vpio_starve_gen"] as? Int, 3)
        XCTAssertEqual(attrs["vpio_starve_ms"] as? Int, 1_204)
        XCTAssertNil(attrs["vpio_first_frame_ms"], "a start that never delivered must not report a latency")
        XCTAssertNil(attrs["vpio_first_frame_eng_ms"])
        XCTAssertNil(attrs["vpio_last_frame_ms"])
    }

    func testDeliveringCallAttrs() {
        var l = Obs.Ledger()
        l.noteArmed()
        l.noteFirstFrame(ms: 412, engMs: 430)
        let attrs = Obs.diagAttrs(ledger: l, gen: 1, env: nil)
        XCTAssertEqual(attrs["vpio_first_frame_ms"] as? Int, 412)
        XCTAssertEqual(attrs["vpio_first_frame_eng_ms"] as? Int, 430)
        XCTAssertEqual(attrs["vpio_last_frame_ms"] as? Int, 412)
        XCTAssertNil(attrs["vpio_starve_gen"])
        XCTAssertNil(attrs["vpio_starve_ms"])
    }

    func testEnvironmentAttrsAreShippedWhenReadAndOmittedWhenNot() {
        var env = Obs.Environment()
        env.hwMachine = "iPhone15,2"
        env.osBuild = "23G80"
        env.micMode = 2
        env.inputPorts = "MicrophoneBuiltIn,BluetoothHFP"
        env.preferredInput = "MicrophoneBuiltIn"
        env.tapFmtBefore = "48000/1"
        env.tapFmtAfter = "24000/1"
        let full = Obs.diagAttrs(ledger: Obs.Ledger(), gen: 1, env: env)
        XCTAssertEqual(full["hw_machine"] as? String, "iPhone15,2")
        XCTAssertEqual(full["os_build"] as? String, "23G80")
        XCTAssertEqual(full["mic_mode"] as? Int, 2)
        XCTAssertEqual(full["input_ports"] as? String, "MicrophoneBuiltIn,BluetoothHFP")
        XCTAssertEqual(full["preferred_input"] as? String, "MicrophoneBuiltIn")
        XCTAssertEqual(full["tap_fmt_before"] as? String, "48000/1")
        XCTAssertEqual(full["tap_fmt_after"] as? String, "24000/1")

        var partial = Obs.Environment()
        partial.hwMachine = "iPhone15,2"
        let attrs = Obs.diagAttrs(ledger: Obs.Ledger(), gen: 1, env: partial)
        XCTAssertEqual(attrs["hw_machine"] as? String, "iPhone15,2")
        for key in ["os_build", "mic_mode", "input_ports", "preferred_input", "tap_fmt_before", "tap_fmt_after"] {
            XCTAssertNil(attrs[key], key + " must be omitted when it was not read")
        }
    }

    // MARK: - Environment helpers

    func testSanitizedTokenKeepsModelAndBuildStrings() {
        XCTAssertEqual(Obs.sanitizedToken("iPhone15,2"), "iPhone15,2")
        XCTAssertEqual(Obs.sanitizedToken("23G80"), "23G80")
        XCTAssertEqual(Obs.sanitizedToken("MicrophoneBuiltIn"), "MicrophoneBuiltIn")
        XCTAssertEqual(Obs.sanitizedToken("48000/1"), "48000/1")
    }

    func testSanitizedTokenDropsWhatShouldNotShip() {
        XCTAssertEqual(Obs.sanitizedToken("a b\nc"), "abc")
        XCTAssertNil(Obs.sanitizedToken(""))
        XCTAssertNil(Obs.sanitizedToken("  \n"))
        XCTAssertNil(Obs.sanitizedToken("\u{1F600}"))
    }

    func testSanitizedTokenIsBounded() {
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(Obs.sanitizedToken(long, maxLen: 24)?.count, 24)
        XCTAssertEqual(Obs.sanitizedToken(long)?.count, 40)
    }

    func testTapFormatString() {
        XCTAssertEqual(Obs.tapFormatString(sampleRate: 48_000, channels: 1), "48000/1")
        XCTAssertEqual(Obs.tapFormatString(sampleRate: 24_000.4, channels: 2), "24000/2")
        XCTAssertEqual(Obs.tapFormatString(sampleRate: 0, channels: 0), "0/0")
        XCTAssertEqual(Obs.tapFormatString(sampleRate: Double.nan, channels: 1), "0/1")
        XCTAssertEqual(Obs.tapFormatString(sampleRate: -1, channels: -1), "0/0")
    }

    func testPortsList() {
        XCTAssertEqual(Obs.portsList(["MicrophoneBuiltIn", "BluetoothHFP"]), "MicrophoneBuiltIn,BluetoothHFP")
        XCTAssertNil(Obs.portsList([]))
        XCTAssertNil(Obs.portsList(["", " "]))
        let many = (0..<20).map { "Port" + String($0) }
        XCTAssertEqual(Obs.portsList(many)?.split(separator: ",").count, 8)
    }

    func testSysctlStrings() {
        XCTAssertFalse((Obs.sysctlString("hw.machine") ?? "").isEmpty)
        XCTAssertFalse((Obs.sysctlString("kern.osversion") ?? "").isEmpty)
        XCTAssertNil(Obs.sysctlString("no.such.sysctl.name"))
    }
}

#if canImport(AVFoundation)

/// W-VPIOOBS -- the two wiring facts `CallService` relies on, checked against the real classes without
/// starting an engine.
final class VpioObservabilityWiringTests: XCTestCase {

    /// engine_running_at_end came out false on every record because the latch was set by `stop()`, AFTER
    /// the diag stats were consumed. The latch is a plain per-call value that `consumeAudioDiagStats`
    /// reads and resets.
    func testEngineRunningAtEndIsReadAndResetPerCall() {
        let pipeline = AudioProcessingPipeline()
        pipeline.noteEngineRunningAtEnd(true)
        XCTAssertTrue(pipeline.consumeAudioDiagStats().engineRunningAtEnd)
        XCTAssertFalse(pipeline.consumeAudioDiagStats().engineRunningAtEnd, "must not leak into the next call")
    }

    /// A capture that never started reports "not running at end": the latch reads the live state.
    func testNoteRunningAtEndNowReadsTheLiveState() {
        let pipeline = AudioProcessingPipeline()
        let capture = AudioCapture(audioPipeline: pipeline)
        capture.noteRunningAtEndNow()
        XCTAssertFalse(pipeline.consumeAudioDiagStats().engineRunningAtEnd)
    }

    /// Every `stop()` is a new generation: a watchdog timer armed for an engine that was torn down
    /// must not be mistaken for the current one.
    func testStopAdvancesTheWatchdogGeneration() {
        let capture = AudioCapture(audioPipeline: AudioProcessingPipeline())
        XCTAssertEqual(capture.consumeVpioDiagAttrs()["vpio_watchdog_gen"] as? Int, 0)
        capture.stop()
        capture.stop()
        XCTAssertEqual(capture.consumeVpioDiagAttrs()["vpio_watchdog_gen"] as? Int, 2)
    }
}

#endif

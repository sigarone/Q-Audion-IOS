import XCTest
@testable import QAudionEngine

/// The optional ceiling on the band the native Opus encoder codes while the microphone is a Bluetooth
/// hands-free link: which route and rate give which limit, that the flag gates everything, the numbers-only
/// log line, and the controller that hands a changed limit to the encoder exactly once. Pure logic with an
/// injected native setter and log sink, no WebRTC or AVAudioSession involved.
final class EncoderBandHintTests: XCTestCase {

    /// Records what the controller handed to the "native setter" and to the log; the setter's answer is settable.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var appliedStorage: [Int] = []
        private var linesStorage: [String] = []
        private var acceptStorage: Bool = true

        var applied: [Int] { lock.lock(); defer { lock.unlock() }; return appliedStorage }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return linesStorage }
        var accept: Bool {
            get { lock.lock(); defer { lock.unlock() }; return acceptStorage }
            set { lock.lock(); acceptStorage = newValue; lock.unlock() }
        }

        func record(applied hz: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if acceptStorage { appliedStorage.append(hz) }
            return acceptStorage
        }

        func record(line: String) {
            lock.lock()
            linesStorage.append(line)
            lock.unlock()
        }
    }

    private func makeController(_ recorder: Recorder) -> EncoderBandHintController {
        return EncoderBandHintController(
            apply: { hz in recorder.record(applied: hz) },
            log: { line in recorder.record(line: line) })
    }

    // MARK: - Rules

    func testTheFlagIsOffByDefaultAndHasItsServerName() {
        XCTAssertEqual(EncoderBandHint.flagKey, "calls.bt_hfp_band_hint")
        // Flag off: whatever the route says, nothing is ever capped.
        XCTAssertEqual(EncoderBandHint.target(flagOn: false, limitHz: 8000), EncoderBandHint.noLimit)
        XCTAssertEqual(EncoderBandHint.target(flagOn: false, limitHz: 16000), EncoderBandHint.noLimit)
        XCTAssertEqual(EncoderBandHint.target(flagOn: true, limitHz: 8000), 8000)
        XCTAssertEqual(EncoderBandHint.target(flagOn: true, limitHz: EncoderBandHint.noLimit), EncoderBandHint.noLimit)
    }

    func testAHandsFreeMicrophoneAtEightKilohertzCapsAtNarrowband() {
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 8000), 8000)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 7999.5), 8000)
    }

    func testAHandsFreeMicrophoneAtSixteenKilohertzCapsAtWideband() {
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 16000), 16000)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 12000), 16000)
        // The rate is a Double and the edges are inclusive: just above 8 kHz is no longer a narrowband link.
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 8000.5), 16000)
    }

    func testARateAboveSixteenKilohertzOrAnUnknownOneIsNeverCapped() {
        // The session can report the phone's own rate for a moment while the link is coming up, and other
        // voice links can be wider: a band that may really be there is not cut.
        let none = EncoderBandHint.noLimit
        // Just above the 16 kHz edge (the rate is a Double).
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 16000.5), none)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 24000), none)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 48000), none)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: 0), none)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: -1), none)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: .nan), none)
        XCTAssertEqual(EncoderBandHint.limitHz(inputPort: "BluetoothHFP", sampleRateHz: .infinity), none)
    }

    func testNoInputOtherThanHandsFreeIsEverCapped() {
        // Built-in microphone (also when the OUTPUT is hands-free), wired headset, LE audio, car, nothing.
        let ports: [String?] = ["MicrophoneBuiltIn", "HeadsetMic", "BluetoothLE", "CarAudio", "USBAudio", "LineIn", "", nil]
        for port in ports {
            XCTAssertEqual(EncoderBandHint.limitHz(inputPort: port, sampleRateHz: 8000), EncoderBandHint.noLimit)
            XCTAssertEqual(EncoderBandHint.limitHz(inputPort: port, sampleRateHz: 16000), EncoderBandHint.noLimit)
        }
    }

    func testTheHintsAreTheBandEdgesTheEncoderBucketsBy() {
        XCTAssertEqual(EncoderBandHint.narrowbandHz, 8000)
        XCTAssertEqual(EncoderBandHint.widebandHz, 16000)
        // The native setter reads -1 as "no limit".
        XCTAssertEqual(EncoderBandHint.noLimit, -1)
        XCTAssertEqual(EncoderBandHint.code(forHz: 8000), 1)
        XCTAssertEqual(EncoderBandHint.code(forHz: 16000), 2)
        XCTAssertEqual(EncoderBandHint.code(forHz: -1), 0)
    }

    // MARK: - Log line

    func testTheLogLineIsNumbersOnlyAndWritesNoLimitAsZero() {
        XCTAssertEqual(EncoderBandHint.logLine(hz: 8000, previousHz: -1, sampleRateHz: 8000), "audioroute band=1 old=0 sr=8000")
        XCTAssertEqual(EncoderBandHint.logLine(hz: 16000, previousHz: 8000, sampleRateHz: 16000), "audioroute band=2 old=1 sr=16000")
        // At the end of the call the rate is not read: sr is omitted rather than printed as 0.
        XCTAssertEqual(EncoderBandHint.logLine(hz: -1, previousHz: 16000, sampleRateHz: 0), "audioroute band=0 old=2")
    }

    func testEveryLogTokenFitsTheRedactorsResidualSweep() {
        let lines: [String] = [
            EncoderBandHint.logLine(hz: 8000, previousHz: -1, sampleRateHz: 8000),
            EncoderBandHint.logLine(hz: 16000, previousHz: 8000, sampleRateHz: 16000),
            EncoderBandHint.logLine(hz: -1, previousHz: 16000, sampleRateHz: 0),
            EncoderBandHint.unsupportedLine,
        ]
        for line in lines {
            for token in line.split(separator: " ") where token.contains("=") {
                XCTAssertLessThanOrEqual(token.count, 19, "token too long for the residual sweep: " + token)
            }
        }
    }

    // MARK: - Controller

    func testAChangedLimitReachesTheEncoderOnceAndIsLoggedOnce() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000), 8000)
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000), 8000)
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000), 8000)
        XCTAssertEqual(recorder.applied, [8000])
        XCTAssertEqual(recorder.lines, ["audioroute band=1 old=0 sr=8000"])
        XCTAssertEqual(controller.currentHz, 8000)
    }

    func testALinkThatSettlesOnAnotherRateIsFollowedAndGivenBackWhenTheRouteMovesAway() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 48000)  // still coming up: no limit
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000)
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 16000)
        controller.update(flagOn: true, inputPort: "MicrophoneBuiltIn", sampleRateHz: 48000)
        XCTAssertEqual(recorder.applied, [8000, 16000, -1])
        XCTAssertEqual(recorder.lines, [
            "audioroute band=1 old=0 sr=8000",
            "audioroute band=2 old=1 sr=16000",
            "audioroute band=0 old=2 sr=48000",
        ])
        XCTAssertEqual(controller.currentHz, EncoderBandHint.noLimit)
    }

    func testWithTheFlagOffNothingIsEverHandedToTheEncoder() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.update(flagOn: false, inputPort: "BluetoothHFP", sampleRateHz: 8000)
        controller.update(flagOn: false, inputPort: "BluetoothHFP", sampleRateHz: 16000)
        XCTAssertEqual(recorder.applied, [])
        XCTAssertEqual(recorder.lines, [])
    }

    func testTurningTheFlagOffTakesAnActiveLimitBack() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000)
        controller.update(flagOn: false, inputPort: "BluetoothHFP", sampleRateHz: 8000)
        XCTAssertEqual(recorder.applied, [8000, -1])
        XCTAssertEqual(controller.currentHz, EncoderBandHint.noLimit)
    }

    func testAnEncoderWithoutTheSetterLeavesOneFixedLineAndIsAskedAgain() {
        let recorder = Recorder()
        recorder.accept = false
        let controller = makeController(recorder)
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000), EncoderBandHint.noLimit)
        // The fact that the flag is on but nothing could be applied leaves a trace, once.
        XCTAssertEqual(recorder.lines, ["audioroute nosetter=1"])
        XCTAssertEqual(controller.currentHz, EncoderBandHint.noLimit)
        // Asked again on the next update (the state was not touched), but not reported again.
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 16000), EncoderBandHint.noLimit)
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000), EncoderBandHint.noLimit)
        XCTAssertEqual(recorder.lines, ["audioroute nosetter=1"])
        // The binary now has it (a stand-in for the next call): the same route is handed over then.
        recorder.accept = true
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000), 8000)
        XCTAssertEqual(recorder.applied, [8000])
        XCTAssertEqual(recorder.lines, ["audioroute nosetter=1", "audioroute band=1 old=0 sr=8000"])
    }

    func testAMissingSetterIsNotReportedWhileNothingWouldBeCapped() {
        let recorder = Recorder()
        recorder.accept = false
        let controller = makeController(recorder)
        // Flag off, or a route that gets no ceiling: the setter is never asked, so there is nothing to report.
        controller.update(flagOn: false, inputPort: "BluetoothHFP", sampleRateHz: 8000)
        controller.update(flagOn: true, inputPort: "MicrophoneBuiltIn", sampleRateHz: 48000)
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 48000)
        controller.clear()
        XCTAssertEqual(recorder.lines, [])
    }

    func testTheLinesGoToTheSinkTheAppSetsInsteadOfTheDefault() {
        let defaultRecorder = Recorder()
        let controller = makeController(defaultRecorder)
        let appRecorder = Recorder()
        controller.lineSink = { line in appRecorder.record(line: line) }
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000)
        XCTAssertEqual(defaultRecorder.lines, [])
        XCTAssertEqual(appRecorder.lines, ["audioroute band=1 old=0 sr=8000"])
    }

    func testClearTakesTheLimitBackOnlyWhenOneIsInForce() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        controller.clear()
        XCTAssertEqual(recorder.applied, [])
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 16000)
        controller.clear()
        controller.clear()
        XCTAssertEqual(recorder.applied, [16000, -1])
        XCTAssertEqual(recorder.lines, ["audioroute band=2 old=0 sr=16000", "audioroute band=0 old=2"])
    }

    func testARouteReadOfAStoppedCallIsNotHandedToTheEncoder() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let owner = controller.startObserving()
        controller.stopObserving(owner: owner)
        // The read of the route began while the call was running and reaches the controller after its stop
        // (a hang-up that came in between): the ceiling must not come back, the setter is process-wide.
        let result = controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000, owner: owner)
        XCTAssertEqual(result, EncoderBandHint.noLimit)
        XCTAssertEqual(recorder.applied, [])
        XCTAssertEqual(recorder.lines, [])
        XCTAssertEqual(controller.currentHz, EncoderBandHint.noLimit)
    }

    func testARouteReadOfAReplacedCallIsNotHandedToTheEncoder() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let first = controller.startObserving()
        let second = controller.startObserving()
        // The first call's late read does not speak for the call that replaced it.
        let result = controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000, owner: first)
        XCTAssertEqual(result, EncoderBandHint.noLimit)
        XCTAssertEqual(recorder.applied, [])
        controller.stopObserving(owner: second)
        XCTAssertEqual(recorder.applied, [])
    }

    #if os(iOS)
    func testARouteReadOfTheCurrentCallIsHandedToTheEncoderAndTakenBackAtItsStop() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let owner = controller.startObserving()
        XCTAssertEqual(controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000, owner: owner), 8000)
        controller.stopObserving(owner: owner)
        XCTAssertEqual(recorder.applied, [8000, -1])
        XCTAssertEqual(controller.currentHz, EncoderBandHint.noLimit)
    }
    #endif

    func testAReplacedCallsLateStopDoesNotSwitchOffItsSuccessor() {
        let recorder = Recorder()
        let controller = makeController(recorder)
        let first = controller.startObserving()
        controller.update(flagOn: true, inputPort: "BluetoothHFP", sampleRateHz: 8000)
        let second = controller.startObserving()
        XCTAssertNotEqual(first, second)
        // The first call is torn down after the second one has started: its stop is ignored.
        controller.stopObserving(owner: first)
        XCTAssertEqual(controller.currentHz, 8000)
        // The second call's own stop takes the limit back.
        controller.stopObserving(owner: second)
        XCTAssertEqual(controller.currentHz, EncoderBandHint.noLimit)
        XCTAssertEqual(recorder.applied, [8000, -1])
    }
}

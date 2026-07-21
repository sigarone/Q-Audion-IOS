import XCTest
@testable import QAudionEngine

/// W-TUNEGAP (2026-07-21) — tests for the pure make-up-AGC ceiling selector
/// `AudioCapture.selectMakeUpAgcMaxGain`.
///
/// Regression coverage for a real, live-confirmed bug: commit `04f82f1`
/// (2026-07-12) made the software make-up AGC run in BOTH VP-IO modes
/// (evidence: call c4185402, Apple's own VP-IO AGC alone left the iOS mic at
/// ~11% peak vs Android's ~71%). The SAME DAY, 4 hours later, commit
/// `a542727`'s broader "canonical VP-IO everywhere" refactor silently
/// re-gated the make-up AGC to `!vpioActiveThisEngine` as a side effect,
/// discarding that fix without new evidence. Call `40f6d641` (2026-07-20)
/// reproduced the predicted regression: iOS tx `rms_pct=2%`, far below the
/// 5-15% healthy band.
///
/// No WebRTC/AVAudioEngine import needed: the decision is pure, so it runs
/// on the macOS CI runner (`swift test`) with no simulator or Xcode UI.
final class AudioCaptureAgcGateTests: XCTestCase {

    // THE BUG: under VP-IO, the make-up AGC must still run (bounded ceiling),
    // never fall back to "no boost" (which is what a542727 silently did).
    func testVpioActiveStillBoostsAboveUnity() {
        XCTAssertGreaterThan(AudioCapture.selectMakeUpAgcMaxGain(vpioActive: true), 1.0)
    }

    func testVpioInactiveStillBoostsAboveUnity() {
        XCTAssertGreaterThan(AudioCapture.selectMakeUpAgcMaxGain(vpioActive: false), 1.0)
    }

    // VP-IO already contributes its own AGC, so our software make-up must
    // run with a LOWER ceiling than the VP-IO-off case (bounds any
    // double-AGC interaction) -- never equal, never higher.
    func testVpioCeilingIsLowerThanNonVpioCeiling() {
        let vpioCeiling = AudioCapture.selectMakeUpAgcMaxGain(vpioActive: true)
        let nonVpioCeiling = AudioCapture.selectMakeUpAgcMaxGain(vpioActive: false)
        XCTAssertLessThan(vpioCeiling, nonVpioCeiling)
    }

    // The exact ceilings 04f82f1 shipped and 40f6d641 confirmed are still
    // correct. If evidence justifies changing either, update this test in
    // the SAME commit as the change -- that's the deliberate-edit trail
    // this whole mechanism exists to create.
    func testCeilingsMatchShippedValues() {
        XCTAssertEqual(AudioCapture.selectMakeUpAgcMaxGain(vpioActive: true), 3.0)
        XCTAssertEqual(AudioCapture.selectMakeUpAgcMaxGain(vpioActive: false), 6.0)
    }
}

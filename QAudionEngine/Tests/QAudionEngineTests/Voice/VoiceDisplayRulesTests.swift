import XCTest
import Foundation
@testable import QAudionEngine

/// The display rules written out as scenarios (stage 7 covers the same rules on generated event lists, these name them): dwell
/// and hold at exactly their limits and one nanosecond before, Cannot verify overriding Checking and nothing else, tier 0
/// capping Matches, the display flags false showing Checking (Learning for the call-local check) with the candidate counted as
/// shadow, consent gating everything, and the call-local constants being the ones of `call_local`.
final class VoiceDisplayRulesTests: XCTestCase {
    private let s: Int64 = 1_000_000_000
    private let t0: Int64 = 9_000_000_000_000_000
    private var c: VoiceScoringConstants!

    override func setUpWithError() throws {
        c = try VoiceScoringKat.constants()
    }

    private func verify() -> VoiceCallMachine {
        VoiceCallMachine(constants: c, mode: .verify)
    }

    private func callLocal() -> VoiceCallMachine {
        VoiceCallMachine(constants: c, mode: .callLocal)
    }

    @discardableResult
    private func start(
        _ m: VoiceCallMachine, tier: Int = 1, differs: Bool = true, change: Bool = false,
        contact: VoiceContactState = .enrolled
    ) -> VoiceRecord {
        m.mediaStart(t0)
        return m.setContext(t0) {
            $0.consent = true
            $0.tier = tier
            $0.displayDiffers = differs
            $0.displayChange = change
            $0.contact = contact
        }
    }

    /// Six windows of `x` one second apart from `from`; returns the record of the last.
    @discardableResult
    private func block(_ m: VoiceCallMachine, from: Int64, x: Double) throws -> VoiceRecord {
        var last: VoiceRecord?
        for k in 0..<6 { last = try m.window(from + Int64(k) * s, x: x, certain: true) }
        return last!
    }

    func testTheDwellHoldsAChangeBackUntilExactly10SecondsAfterTheLastChange() throws {
        for exact in [false, true] {
            let m = verify()
            start(m)
            try m.window(t0 + 1 * s, x: 4.0, certain: true)
            let matches = try m.window(t0 + 2 * s, x: 4.0, certain: true)
            XCTAssertEqual(matches.shown, .matches)
            XCTAssertTrue(matches.changed)
            // R falls under t_match: the target is Checking again, allowed 10 s after the change to Matches
            let limit = t0 + 2 * s + 10 * s
            let early = try m.window(limit - 1, x: -4.0, certain: true)
            XCTAssertEqual(early.cand, .checking)
            XCTAssertEqual(early.shown, .matches)
            XCTAssertTrue(early.pending)
            XCTAssertFalse(early.changed)
            let at = exact ? m.tick(limit, speechMs30s: 0) : m.tick(limit + 1, speechMs30s: 0)
            XCTAssertEqual(at.shown, .checking)
            XCTAssertTrue(at.changed)
            XCTAssertFalse(at.pending)
        }
    }

    func testEnteringCheckingFromOffIsImmediateAndStartsNoDwell() throws {
        let m = verify()
        XCTAssertEqual(m.mediaStart(t0).shown, .off)
        let r = m.setContext(t0) {
            $0.consent = true
            $0.tier = 1
        }
        XCTAssertEqual(r.shown, .checking)
        XCTAssertTrue(r.changed)
        // the first change between two states other than Off has no earlier change to wait for
        try m.window(t0 + 1, x: 4.0, certain: true)
        XCTAssertEqual(try m.window(t0 + 2, x: 4.0, certain: true).shown, .matches)
        // leaving to Off is immediate even inside the dwell
        let off = m.setContext(t0 + 3) { $0.consent = false }
        XCTAssertEqual(off.shown, .off)
        XCTAssertTrue(off.changed)
    }

    func testDiffersStaysAtLeast20SecondsAndTheDwellAloneDoesNotReleaseIt() throws {
        for exact in [false, true] {
            let m = verify()
            start(m)
            let differs = try block(m, from: t0 + 1 * s, x: -4.0)
            let shownAt = t0 + 6 * s
            XCTAssertEqual(differs.shown, .differs)
            XCTAssertTrue(differs.changed)
            XCTAssertTrue(differs.differed)
            for k in 1...5 { try m.window(shownAt + Int64(k) * s, x: 4.0, certain: true) }
            // the sixth positive window closes the block: Matches is the target, but the hold is not over
            let closeAt = exact ? shownAt + 20 * s : shownAt + 20 * s - 1
            let closing = try m.window(closeAt, x: 4.0, certain: true)
            XCTAssertEqual(closing.cand, .matches)
            if exact {
                XCTAssertEqual(closing.shown, .matches)
                XCTAssertTrue(closing.changed)
            } else {
                XCTAssertEqual(closing.shown, .differs)
                XCTAssertTrue(closing.pending)
                XCTAssertFalse(closing.changed)
                let tick = m.tick(shownAt + 20 * s, speechMs30s: 0)
                XCTAssertEqual(tick.shown, .matches)
                XCTAssertTrue(tick.changed)
            }
            // the call keeps the sticky flag
            XCTAssertTrue(m.tick(shownAt + 40 * s, speechMs30s: 0).differed)
        }
    }

    func testCannotVerifyAudioNeeds8000MsOfSpeechAndNoScoredWindowInTheLast30Seconds() throws {
        let m = verify()
        start(m)
        let scored = t0 + 1 * s
        try m.window(scored, x: 0.5, certain: true)
        // a window was scored less than 30 s ago: Checking, whatever the speech
        XCTAssertEqual(m.tick(scored + 30 * s - 1, speechMs30s: 8000).shown, .checking)
        // exactly 30 s: outside the lookback; 7999 ms of speech is not enough, 8000 is
        XCTAssertEqual(m.tick(scored + 30 * s, speechMs30s: 7999).shown, .checking)
        let over = m.tick(scored + 30 * s, speechMs30s: 8000)
        XCTAssertEqual(over.shown, .cannotVerify)
        XCTAssertEqual(over.detail, .audio)
        XCTAssertTrue(over.changed)
        // a scored window ends it (after the dwell: it is the second change between two states other than Off)
        let back = try m.window(scored + 40 * s, x: 0.5, certain: true)
        XCTAssertEqual(back.shown, .checking)
    }

    func testCannotVerifyOverridesCheckingOnlyNeverMatchesOrDiffersAndAFaultWinsOverAudio() throws {
        let m = verify()
        start(m)
        try m.window(t0 + 1 * s, x: 4.0, certain: true)
        let matches = try m.window(t0 + 2 * s, x: 4.0, certain: true)
        XCTAssertEqual(matches.shown, .matches)
        let faulted = m.setContext(t0 + 3 * s) { $0.fault = .cpu }
        XCTAssertEqual(faulted.shown, .matches)
        XCTAssertNil(faulted.detail)
        // silence in the lookback does not override Matches either
        XCTAssertEqual(m.tick(t0 + 60 * s, speechMs30s: 20_000).shown, .matches)

        let d = verify()
        start(d)
        let differs = try block(d, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(differs.shown, .differs)
        XCTAssertEqual(d.setContext(t0 + 8 * s) { $0.fault = .model }.shown, .differs)

        let w = verify()
        start(w)
        try w.window(t0 + 1 * s, x: 0.5, certain: true)
        let both = w.setContext(t0 + 100 * s) { $0.fault = .locked }
        XCTAssertEqual(both.shown, .cannotVerify)
        XCTAssertEqual(w.tick(t0 + 101 * s, speechMs30s: 30_000).detail, .locked)

        for f in [VoiceFault.path, .model, .constants, .locked, .cpu] {
            let x = verify()
            start(x)
            let got = x.setContext(t0 + 1) { $0.fault = f }
            XCTAssertEqual(got.shown, .cannotVerify)
            XCTAssertEqual(got.detail?.rawValue, f.rawValue)
        }
    }

    func testTier0CapsMatchesAtCheckingAndStillAllowsDiffers() throws {
        let m = verify()
        start(m, tier: 0)
        try m.window(t0 + 1 * s, x: 4.0, certain: true)
        let r = try m.window(t0 + 2 * s, x: 4.0, certain: true)
        XCTAssertEqual(r.cand, .matches)
        XCTAssertEqual(r.shown, .checking)
        let d = verify()
        start(d, tier: 0)
        XCTAssertEqual(try block(d, from: t0 + 1 * s, x: -4.0).shown, .differs)
        let t1 = verify()
        start(t1, tier: 1)
        try t1.window(t0 + 1 * s, x: 4.0, certain: true)
        XCTAssertEqual(try t1.window(t0 + 2 * s, x: 4.0, certain: true).shown, .matches)
    }

    func testWithTheDisplayFlagsFalseADiffersCandidateShowsCheckingAndIsShadow() throws {
        let m = verify()
        start(m, differs: false)
        let r = try block(m, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(r.cand, .differs)
        XCTAssertEqual(r.shown, .checking)
        XCTAssertTrue(r.shadow)
        XCTAssertFalse(r.differed)
        XCTAssertTrue(r.blocked)
        XCTAssertNil(r.detail)

        let n = verify()
        start(n, contact: .needsRefresh)
        let nr = try block(n, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(nr.shown, .checking)
        XCTAssertTrue(nr.shadow)

        let u = verify()
        start(u)
        u.setContext(t0 + 1) { $0.routeCovered = false }
        let ur = try block(u, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(ur.shown, .checking)
        XCTAssertEqual(ur.detail, .differentSetup)
        XCTAssertTrue(ur.shadow)

        let dev = verify()
        start(dev)
        dev.setContext(t0 + 1) { $0.deviceCovered = false }
        // a device not covered raises the threshold by delta_new and the copy says so
        let dr = try block(dev, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(dr.shown, .differs)
        XCTAssertEqual(dr.detail, .deviceNew)
    }

    func testNothingIsComputedAndNothingShownUntilConsent() throws {
        let m = verify()
        m.mediaStart(t0)
        let r = try block(m, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(r.shown, .off)
        XCTAssertEqual(r.b, 0)
        XCTAssertEqual(r.recentN, 0)
        XCTAssertFalse(r.blocked)
        // withdrawing consent mid-call turns the display Off at once
        let m2 = verify()
        start(m2)
        try m2.window(t0 + 1 * s, x: 4.0, certain: true)
        XCTAssertEqual(m2.setContext(t0 + 2 * s) { $0.consent = false }.shown, .off)
    }

    func testTheCallLocalCheckShowsLearningAndChangedOnlyWithTheFlagAndWithItsOwnConstants() throws {
        let off = callLocal()
        start(off, change: false, contact: .learning)
        let shadow = try block(off, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(shadow.cand, .differs)
        XCTAssertEqual(shadow.shown, .learning)
        XCTAssertTrue(shadow.shadow)

        let on = callLocal()
        start(on, change: true, contact: .learning)
        let changed = try block(on, from: t0 + 1 * s, x: -4.0)
        XCTAssertEqual(changed.shown, .changed)
        XCTAssertTrue(changed.differed)
        XCTAssertFalse(changed.shadow)

        // a call-local machine never reaches Matches
        let m = callLocal()
        start(m, change: true)
        try m.window(t0 + 1 * s, x: 4.0, certain: true)
        let r = try m.window(t0 + 2 * s, x: 4.0, certain: true)
        XCTAssertEqual(r.cand, .checking)
        XCTAssertEqual(r.shown, .learning)
        // T_next is the one of call_local.t_change, with no delta_new
        XCTAssertEqual(r.tNext, c.callLocal.tChange, accuracy: 1e-12)
        m.setContext(t0 + 3 * s) { $0.deviceCovered = false }
        XCTAssertEqual(m.tick(t0 + 4 * s, speechMs30s: 0).tNext, c.callLocal.tChange, accuracy: 1e-12)
    }

    func testDiffersIsShownUpToMaxBlockAndOnlyLoggedAfterIt() throws {
        XCTAssertEqual(c.evidence.maxBlock, 4)
        for (neutralBlocks, shown) in [(3, VoiceShown.differs), (4, VoiceShown.checking)] {
            let m = verify()
            start(m)
            for k in 1...neutralBlocks { try block(m, from: t0 + Int64(k) * 10 * s, x: 0.1) }
            let r = try block(m, from: t0 + 100 * s, x: -4.0)
            XCTAssertEqual(r.closed?.b, neutralBlocks + 1)
            XCTAssertEqual(r.closed?.differs, true)
            XCTAssertEqual(r.cand, .differs)
            XCTAssertEqual(r.shown, shown)
            XCTAssertEqual(r.shadow, shown == .checking)
        }
    }

    func testAResetDiscardsThePartialBlockAndKeepsBRecentAndTheFlagsOfTheLastBlock() throws {
        let m = verify()
        start(m)
        try block(m, from: t0 + 1 * s, x: 0.1)
        let partial = try m.window(t0 + 10 * s, x: 0.1, certain: true)
        XCTAssertEqual(partial.blockN, 1)
        let reset = m.reset(t0 + 11 * s)
        XCTAssertEqual(reset.b, 1)
        XCTAssertEqual(reset.blockN, 0)
        XCTAssertEqual(reset.recentN, 6)
        // the block restarts from empty: five more windows do not close one
        for k in 1...5 { XCTAssertNil(try m.window(t0 + 11 * s + Int64(k) * s, x: 0.1, certain: true).closed) }
        XCTAssertEqual(m.tick(t0 + 20 * s, speechMs30s: 0).blockN, 5)
    }
}

final class VoiceNonFiniteInputTests: XCTestCase {
    func testANonFiniteLlrThrowsAndAccumulatesNothing() throws {
        let c = try VoiceScoringKat.constants()
        for mode in [VoiceCheckMode.verify, .callLocal] {
            let m = VoiceCallMachine(constants: c, mode: mode)
            m.mediaStart(1)
            m.setContext(1) { $0.consent = true }
            for bad in [Double.nan, .infinity, -.infinity] {
                XCTAssertThrowsError(try m.window(2, x: bad, certain: true), "\(bad)") { error in
                    XCTAssertEqual(error as? VoiceScoringError, VoiceScoringError.invalidInput("clipped LLR must be finite"))
                }
            }
            let r = m.tick(3, speechMs30s: 0)
            XCTAssertEqual(r.recentN, 0)
            XCTAssertEqual(r.blockN, 0)
        }
        // without consent the input is still checked: a non-finite value is a bug whatever the state
        let off = VoiceCallMachine(constants: c, mode: .verify)
        off.mediaStart(1)
        XCTAssertThrowsError(try off.window(2, x: .nan, certain: true))
    }
}

import XCTest
@testable import QAudionEngine

/// W-BUSYHOLD (2026-10-04) — the caller must SEE "Occupato" and HEAR the busy tone for a useful time (owner
/// decision: 4000 ms, the same as Android) before the screen closes, and nothing may cut either short.
///
/// Live trace 2026-10-04 07:37 (A36 calling a busy iPhone): on Android a SECOND terminal state of the same call
/// overwrote the busy one and the screen closed at once. On iOS the id gate in front of the handlers
/// (`CallerAcceptLatch.terminalEnvelopeArrived`) already drops a duplicate `call_busy`; what these tests pin is the
/// rest of the chain: the one constant the hold, the tone and the sound's disposal share, and `CallerOutcomeHold`,
/// the value that owns the showing (first terminal wins, a timer closes only its own showing, only the timer and the
/// close button close it). `CallerBusyHoldWiringTests` pins that `AppState` uses it and that no teardown path can
/// reach it.
///
/// Each test says what it fails without: the fix it exists for.
final class CallerBusyHoldTests: XCTestCase {

    private let callA = "c16bc8ca-1111-4111-8111-111111111111"
    private let callB = "db192238-2222-4222-8222-222222222222"

    private func started(
        _ result: CallerOutcomeHold.ShowResult, file: StaticString = #filePath, line: UInt = #line
    ) -> (showing: CallerOutcomeHold.Showing, replaced: CallerOutcomeHold.Closed?)? {
        guard case .started(let showing, let replaced) = result else {
            XCTFail("expected a new showing, got \(result)", file: file, line: line)
            return nil
        }
        return (showing, replaced)
    }

    // MARK: - one constant

    /// The owner decision, and everything that has to agree with it. Fails if the hold goes back to #169's 3 s, or if
    /// the tone, or the sound's disposal, keeps its own copy of the number.
    func testTheBusyHoldIsFourSecondsAndTheToneFillsExactlyThat() {
        XCTAssertEqual(CallerBusyFeedback.holdMs, 4_000, "owner decision: 4000 ms, same as Android")
        XCTAssertEqual(CallerTerminalOutcome.busy.holdMs, CallerBusyFeedback.holdMs)
        XCTAssertEqual(CallerTerminalOutcome.busy.holdSeconds, 4.0)
        XCTAssertEqual(QAudionSynth.busyToneSeconds, CallerBusyFeedback.holdSeconds)
        XCTAssertEqual(QAudionSynth.busyToneRepetitions * CallerBusyFeedback.toneCycleMs, CallerBusyFeedback.holdMs,
                       "whole bursts fill the hold, no partial one")
        XCTAssertEqual(QAudionSynth.renderBusyTone(sampleRate: 8_000).count, 8_000 * 4,
                       "the rendered tone is as long as the hold: the caller hears it for the whole 4000 ms")
    }

    /// #169 disposed the sound id 3.5 s after it started. With a tone as long as the hold that would cut the last
    /// burst; the disposal comes after the end of the tone, never before it.
    func testTheSoundIsDisposedAfterTheEndOfTheToneNeverBefore() {
        let toneMs = Int((QAudionSynth.busyToneSeconds * 1_000).rounded())
        XCTAssertGreaterThan(CallerBusyFeedback.soundDisposeAfterMs, toneMs)
        XCTAssertGreaterThan(CallerBusyFeedback.soundDisposeAfterMs, CallerTerminalOutcome.busy.holdMs)
        XCTAssertEqual(CallerBusyFeedback.soundDisposeAfterMs, CallerBusyFeedback.holdMs + CallerBusyFeedback.soundDisposeGraceMs)
    }

    /// The tone file is written once and reused, and a temporary directory can outlive an app update: the 3 s file of
    /// 1.0.1207 (`qaudion_busy_tone.wav`) must never be picked up for the 4 s tone.
    func testTheToneFileNameCarriesItsLengthSoAStaleFileIsNeverReused() {
        XCTAssertEqual(QAudionCueWav.busyToneFileName, "qaudion_busy_tone_4000ms.wav")
        XCTAssertNotEqual(QAudionCueWav.busyToneFileName, "qaudion_busy_tone.wav")
    }

    // MARK: - the showing

    func testShowStartsAFourSecondHoldAndLogsIt() throws {
        var hold = CallerOutcomeHold()
        let first = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 1_000)))
        XCTAssertNil(first.replaced)
        XCTAssertEqual(first.showing.holdMs, 4_000)
        XCTAssertEqual(first.showing.shownAtMs, 1_000)
        XCTAssertEqual(first.showing.shownLine, "busy feedback shown call=c16bc8ca holdMs=4000")
        XCTAssertEqual(hold.showing, first.showing)
    }

    func testTheHoldTimerClosesItsOwnShowingExactlyAtTheEndOfTheHold() throws {
        var hold = CallerOutcomeHold()
        let first = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 1_000)))
        let closed = try XCTUnwrap(hold.holdElapsed(serial: first.showing.serial, nowMs: 5_000))
        XCTAssertEqual(closed.by, .timeout)
        XCTAssertEqual(closed.heldMs, 4_000)
        XCTAssertEqual(closed.closedLine, "busy feedback closed call=c16bc8ca by=timeout ms=4000")
        XCTAssertNil(hold.showing)
    }

    // MARK: - a duplicate / a second terminal cannot cut it

    /// The first line of defence, in front of the handlers: the id gate lets the FIRST `call_busy` of a call end it and
    /// drops every other terminal envelope of that call (a duplicate `call_busy`, a `call_peer_offline`, whatever the
    /// phase has become), so the duplicate never reaches `showCallerOutcome` at all. Without the reset the gate does at
    /// the first envelope, the duplicate would run the whole teardown and the outcome a second time.
    func testTheIdGateLetsOnlyTheFirstTerminalEnvelopeOfACallEndIt() {
        var latch = CallerAcceptLatch()
        latch.beginOutgoing(callId: callA)
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: .connecting), .endOutgoingCall)
        // the same envelope again (the server answers once per call_offer it receives), 3 ms later
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: .ended), .ignore(.noOutgoingCall))
        // and an unreachable-callee envelope of the same call, whatever phase the call is in by now
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA, phase: .idle), .ignore(.noOutgoingCall))
        XCTAssertEqual(latch.terminalEnvelopeArrived(envelopeCallId: callA.uppercased(), phase: .connecting), .ignore(.noOutgoingCall))
    }

    /// A duplicate `call_busy` of the same call (the server answers once per `call_offer` it gets, and the Android
    /// caller sends two): without `alreadyShown` it would start a new showing, and the timer of the first would find
    /// its serial gone, so the screen would close 1 s late, or, with a tone restart, play the tone twice.
    func testADuplicateCallBusyNeitherRestartsNorCutsTheHold() throws {
        var hold = CallerOutcomeHold()
        let first = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 1_000)))
        XCTAssertEqual(hold.show(.busy, callId: callA, nowMs: 1_040), .alreadyShown, "the duplicate, 40 ms later")
        XCTAssertEqual(hold.show(.busy, callId: callA.uppercased(), nowMs: 2_000), .alreadyShown,
                       "wire ids are compared case-insensitively, as everywhere")
        XCTAssertEqual(hold.showing, first.showing, "same showing, same serial, same clock")
        let closed = try XCTUnwrap(hold.holdElapsed(serial: first.showing.serial, nowMs: 5_000),
                                   "the first timer still closes it: nothing restarted")
        XCTAssertEqual(closed.heldMs, 4_000, "4000 ms from the FIRST showing, not from the duplicate")
    }

    /// The Android defect, as a value: a second terminal state of the same call (here an unreachable-callee outcome
    /// after the busy one) must not take the screen over. Without the guard the outcome becomes `peerOffline`: no
    /// tone, 2.5 s hold, and "Occupato" is gone.
    func testASecondTerminalOfTheSameCallDoesNotOverwriteBusy() throws {
        var hold = CallerOutcomeHold()
        _ = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 1_000)))
        XCTAssertEqual(hold.show(.peerOffline, callId: callA, nowMs: 1_010), .alreadyShown)
        XCTAssertEqual(hold.showing?.outcome, .busy)
        XCTAssertEqual(hold.showing?.holdMs, 4_000)
    }

    // MARK: - a timer closes only its own showing

    /// Without the serial, the timer of a showing the user already closed (a redial) would close the NEXT call's
    /// outcome 1.5 s into its own hold.
    func testATimerOfAnEarlierShowingNeverClosesALaterOne() throws {
        var hold = CallerOutcomeHold()
        let one = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 1_000)))
        XCTAssertNotNil(hold.close(by: .user, nowMs: 1_500))
        let two = try XCTUnwrap(started(hold.show(.busy, callId: callB, nowMs: 2_000)))
        XCTAssertNotEqual(one.showing.serial, two.showing.serial)
        XCTAssertNil(hold.holdElapsed(serial: one.showing.serial, nowMs: 5_000),
                     "the first showing's timer fires at 5000 ms and finds nothing of its own")
        XCTAssertEqual(hold.showing, two.showing, "the second outcome is still on screen")
        XCTAssertEqual(hold.holdElapsed(serial: two.showing.serial, nowMs: 6_000)?.heldMs, 4_000)
    }

    // MARK: - closing it

    /// The close button, and a redial (which is the user acting): closes at once and says how long it was up. The
    /// later timer finds nothing. Without `close` returning the showing, the log line cannot say `by=user ms=…`.
    func testTheUserClosesItEarlyAndTheLaterTimerDoesNothing() throws {
        var hold = CallerOutcomeHold()
        let first = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 1_000)))
        let closed = try XCTUnwrap(hold.close(by: .user, nowMs: 2_200))
        XCTAssertEqual(closed.by, .user)
        XCTAssertEqual(closed.heldMs, 1_200)
        XCTAssertEqual(closed.closedLine, "busy feedback closed call=c16bc8ca by=user ms=1200")
        XCTAssertNil(hold.showing)
        XCTAssertNil(hold.holdElapsed(serial: first.showing.serial, nowMs: 5_000))
        XCTAssertNil(hold.close(by: .user, nowMs: 5_000), "nothing left to close")
    }

    /// An outcome of ANOTHER call while one is up: the one on screen is closed (and logged), never left dangling.
    func testAnotherCallsOutcomeClosesThePreviousOneWithALogLine() throws {
        var hold = CallerOutcomeHold()
        _ = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 1_000)))
        let second = try XCTUnwrap(started(hold.show(.busy, callId: callB, nowMs: 3_000)))
        let replaced = try XCTUnwrap(second.replaced)
        XCTAssertEqual(replaced.by, .replaced)
        XCTAssertEqual(replaced.heldMs, 2_000)
        XCTAssertEqual(replaced.closedLine, "busy feedback closed call=c16bc8ca by=replaced ms=2000")
        XCTAssertEqual(hold.showing?.callId, callB)
    }

    func testAnEmptyCallIdIsNeverTheSameCallAsAnother() throws {
        var hold = CallerOutcomeHold()
        _ = try XCTUnwrap(started(hold.show(.busy, callId: "", nowMs: 1_000)))
        _ = try XCTUnwrap(started(hold.show(.busy, callId: "", nowMs: 1_100)))
    }

    func testAClockThatWentBackwardsNeverGivesANegativeDuration() throws {
        var hold = CallerOutcomeHold()
        let first = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 5_000)))
        XCTAssertEqual(hold.holdElapsed(serial: first.showing.serial, nowMs: 4_000)?.heldMs, 0)
    }

    // MARK: - the other outcome, and the log

    func testTheUnreachableOutcomeKeepsItsOwnHoldAndLabel() throws {
        var hold = CallerOutcomeHold()
        let first = try XCTUnwrap(started(hold.show(.peerOffline, callId: callA, nowMs: 0)))
        XCTAssertEqual(first.showing.holdMs, 2_500)
        XCTAssertEqual(first.showing.shownLine, "unreachable feedback shown call=c16bc8ca holdMs=2500")
        XCTAssertFalse(CallerTerminalOutcome.peerOffline.playsBusyTone)
    }

    /// No PII: the lines carry the first 8 characters of the call id, never the whole id.
    func testTheLogLinesCarryAShortCallIdOnly() throws {
        var hold = CallerOutcomeHold()
        let first = try XCTUnwrap(started(hold.show(.busy, callId: callA, nowMs: 0)))
        let closed = try XCTUnwrap(hold.holdElapsed(serial: first.showing.serial, nowMs: 4_000))
        for line in [first.showing.shownLine, closed.closedLine] {
            XCTAssertTrue(line.contains("call=c16bc8ca "), line)
            XCTAssertFalse(line.contains(callA), line)
            XCTAssertFalse(line.contains("-1111-"), line)
        }
    }
}

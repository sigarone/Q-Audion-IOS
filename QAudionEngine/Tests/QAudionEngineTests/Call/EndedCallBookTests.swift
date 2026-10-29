import XCTest
@testable import QAudionEngine

final class EndedCallBookTests: XCTestCase {

    private func appState() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("QAudionApp/AppState.swift"), encoding: .utf8)
    }

    func testFatalForAnEndedCallIsStaleWhenNoCallIsActive() {
        var ended = EndedCallBook()
        ended.noteEnded("6A8E86CA-1111", nowMs: 1_000)
        XCTAssertEqual(HandshakeFatalDecision.decide(callId: "6a8e86ca-1111", activeCallId: nil, anyCallInFlight: false, ended: ended, nowMs: 2_000), .stale)
    }

    func testFatalForTheActiveCallStillEndsItEvenIfItsIdIsInTheBook() {
        var ended = EndedCallBook()
        ended.noteEnded("abc", nowMs: 1_000)
        XCTAssertEqual(HandshakeFatalDecision.decide(callId: "ABC", activeCallId: "abc", anyCallInFlight: true, ended: ended, nowMs: 2_000), .proceed)
        XCTAssertFalse(ended.isStale(callId: "abc", activeCallId: "abc", anyCallInFlight: true, nowMs: 2_000))
    }

    func testFatalDuringSetupBeforeTheActiveIdIsKnownStillEndsTheCall() {
        let ended = EndedCallBook()
        XCTAssertEqual(HandshakeFatalDecision.decide(callId: "abc", activeCallId: nil, anyCallInFlight: false, ended: ended, nowMs: 0), .proceed)
        XCTAssertEqual(HandshakeFatalDecision.decide(callId: "abc", activeCallId: "", anyCallInFlight: false, ended: ended, nowMs: 0), .proceed)
    }

    func testFatalForAnotherCallIsStale() {
        let ended = EndedCallBook()
        XCTAssertEqual(HandshakeFatalDecision.decide(callId: "old", activeCallId: "new", anyCallInFlight: true, ended: ended, nowMs: 0), .stale)
    }

    func testACallInFlightWithNoActiveIdBoundIsNeverSkipped() {
        var ended = EndedCallBook()
        ended.noteEnded("abc", nowMs: 1_000)
        // only the CallKit id is bound, the answer is in progress: the fatal ends the call, the expiry is not skipped
        XCTAssertEqual(
            HandshakeFatalDecision.decide(callId: "abc", activeCallId: nil, anyCallInFlight: true, ended: ended, nowMs: 2_000),
            .proceed)
        XCTAssertFalse(ended.isStale(callId: "abc", activeCallId: nil, anyCallInFlight: true, nowMs: 2_000))
        XCTAssertFalse(ended.isStale(callId: "abc", activeCallId: "", anyCallInFlight: true, nowMs: 2_000))
        // no call exists at all: the same event is stale
        XCTAssertTrue(ended.isStale(callId: "abc", activeCallId: nil, anyCallInFlight: false, nowMs: 2_000))
    }

    func testAnExpiryForAnEndedCallIsStaleWhileADifferentCallIsActive() {
        var ended = EndedCallBook()
        ended.noteEnded("old", nowMs: 1_000)
        XCTAssertTrue(ended.isStale(callId: "old", activeCallId: "new", anyCallInFlight: true, nowMs: 2_000))
        XCTAssertFalse(ended.isStale(callId: "unknown", activeCallId: "new", anyCallInFlight: true, nowMs: 2_000))
    }

    func testANewCallAdmittedWithAnIdThatWasInTheBookIsNotShielded() {
        var ended = EndedCallBook()
        ended.noteEnded("same", nowMs: 1_000)
        ended.forget("SAME")
        XCTAssertEqual(HandshakeFatalDecision.decide(callId: "same", activeCallId: nil, anyCallInFlight: false, ended: ended, nowMs: 2_000), .proceed)
        XCTAssertFalse(ended.hasEnded("same", nowMs: 2_000))
    }

    func testAnEntryOlderThanTheTtlShieldsNothing() {
        var ended = EndedCallBook()
        ended.noteEnded("old", nowMs: 1_000)
        XCTAssertTrue(ended.hasEnded("old", nowMs: 1_000 + EndedCallBook.ttlMs - 1))
        XCTAssertFalse(ended.hasEnded("old", nowMs: 1_000 + EndedCallBook.ttlMs))
        XCTAssertEqual(
            HandshakeFatalDecision.decide(callId: "old", activeCallId: nil, anyCallInFlight: false, ended: ended, nowMs: 1_000 + EndedCallBook.ttlMs),
            .proceed)
    }

    func testBookIsBoundedByCount() {
        var ended = EndedCallBook()
        for i in 0..<(EndedCallBook.capacity + 5) { ended.noteEnded("call-\(i)", nowMs: 10 + i) }
        XCTAssertFalse(ended.hasEnded("call-0", nowMs: 100))
        XCTAssertTrue(ended.hasEnded("call-\(EndedCallBook.capacity + 4)", nowMs: 100))
        ended.noteEnded(nil, nowMs: 100)
        ended.noteEnded("", nowMs: 100)
        XCTAssertFalse(ended.hasEnded("", nowMs: 100))
    }

    /// The first fatal of the call unbinds the wire id before `endCall` runs, so `endCall` cannot read the id from the
    /// provider: it must clear the call's key-confirmation state (and with it the KCMAC wait tasks) by the ids the
    /// book knows, and the fatal must record the id it ends and be gated by the book.
    func testAppStateCancelsConfirmationWaitsOfAnEndedCallAndGatesFatals() throws {
        let app = try appState()
        XCTAssertTrue(app.contains("HandshakeFatalDecision.decide("), "the fatal is gated by the ended-call book")
        XCTAssertTrue(app.contains("endedCalls.noteEnded(callId, nowMs: SasCommit.monotonicNowMs())"), "the fatal records the id it ends")
        XCTAssertTrue(
            app.contains("for key in Array(kcCalls.keys) where endedCalls.hasEnded(key, nowMs: SasCommit.monotonicNowMs()) { clearKeyConfirmationState(callId: key) }"),
            "endCall cancels the KCMAC waits of every ended call, whatever the provider still reports")
        XCTAssertTrue(
            app.contains("endedCalls.isStale(callId: callId, activeCallId: canonicalActiveCallId(),"),
            "a confirmation expiry for an ended call does nothing, an active call is never skipped")
        XCTAssertTrue(app.contains("endedCalls.forget("), "an admitted call id is removed from the book")
    }
}

final class FatalAssuranceOutcomeTests: XCTestCase {
    func testNoFatalReasonPersistsAPositiveOutcome() {
        XCTAssertEqual(FatalAssuranceOutcome.persisted(forReason: "kcmac_mismatch"), .kcFailed)
        for reason in ["dtls_fp_mismatch", "handshake_malformed", "sas_commit_mismatch", "sas_reveal_timeout", "keyepoch_unresolved", "other"] {
            XCTAssertNil(FatalAssuranceOutcome.persisted(forReason: reason), reason)
        }
    }
}

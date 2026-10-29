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

final class FatalAssuranceKeysTests: XCTestCase {
    func testTheNamedCallWins() {
        XCTAssertEqual(FatalAssuranceOutcome.affectedKeys(callId: "ABC", activeCallId: "def", stashedKeys: ["abc", "def"]), ["abc"])
    }

    func testAnEmptyIdUsesTheActiveCall() {
        XCTAssertEqual(FatalAssuranceOutcome.affectedKeys(callId: "", activeCallId: "DEF", stashedKeys: ["abc", "def"]), ["def"])
    }

    func testNoIdAtAllFailsClosedOnEveryStashedVerdict() {
        XCTAssertEqual(FatalAssuranceOutcome.affectedKeys(callId: "", activeCallId: nil, stashedKeys: ["abc", "def"]), ["abc", "def"])
        XCTAssertEqual(FatalAssuranceOutcome.affectedKeys(callId: "", activeCallId: "", stashedKeys: ["abc"]), ["abc"])
    }
}

final class FatalEndSkipsInPersonFinalizeTests: XCTestCase {
    func testACallEndedOnAHandshakeFailureFinalizesNothingAndForgetsWhatWasHeld() {
        var deferred = DeferredInPersonFinalize()
        XCTAssertEqual(deferred.submit(callId: "c1", names: ["new"], rekeyWaitingForAccept: true), [])
        XCTAssertEqual(deferred.flushOnEnd(callId: "C1", endedOnHandshakeFailure: true), [])
        XCTAssertEqual(deferred, DeferredInPersonFinalize(), "nothing stays held for the next call")
    }

    func testAnOrdinaryEndStillRunsWhatWasHeld() {
        var deferred = DeferredInPersonFinalize()
        _ = deferred.submit(callId: "c2", names: ["new"], rekeyWaitingForAccept: true)
        XCTAssertEqual(deferred.flushOnEnd(callId: "c2", endedOnHandshakeFailure: false), ["new"])
    }

    /// The app passes the pending fatal reason of the ending call, and resolves the id of a fatal that arrives with none.
    func testAppStateWiring() throws {
        let app = try appStateSource()
        let flat = app.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(flat.contains("endedOnHandshakeFailure: !trust.finalizeInPersonKeys"))
        XCTAssertTrue(flat.contains("rekeyWaitingForAccept: true"), "every finalization is held until the call ends")
        XCTAssertTrue(flat.contains("handleRemoteCallHangup(reasonString: reason, source: .authenticatedPeer)"))
        XCTAssertTrue(app.contains("FatalAssuranceOutcome.affectedKeys("))
        XCTAssertFalse(app.contains("runInPersonFinalize(deferredInPersonFinalize.flush(callId: callId))"))
    }

    private func appStateSource() throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }   // the repository root
        return try String(contentsOf: root.appendingPathComponent("QAudionApp/AppState.swift"), encoding: .utf8)
    }
}

final class CallEndTrustTests: XCTestCase {
    func testAnOrdinaryEndFinalizesAndKeepsTheVerdict() {
        let t = CallEndTrust.decide(failureSource: nil, identityHeldUnconfirmed: false)
        XCTAssertTrue(t.finalizeInPersonKeys)
        XCTAssertFalse(t.downgradeStashedVerdict)
        XCTAssertEqual(CallEndTrust.verdictToPersist(stashed: .pskConfirmed, failureSource: nil, reason: ""), .pskConfirmed)
    }

    func testALocalOrAuthenticatedFailureFinalizesNothingAndDowngradesTheVerdict() {
        for source in [HandshakeFailureSource.local, .authenticatedPeer] {
            let t = CallEndTrust.decide(failureSource: source, identityHeldUnconfirmed: false)
            XCTAssertFalse(t.finalizeInPersonKeys, "\(source)")
            XCTAssertTrue(t.downgradeStashedVerdict, "\(source)")
            XCTAssertEqual(CallEndTrust.verdictToPersist(stashed: .nfcAuthenticated, failureSource: source, reason: "kcmac_mismatch"), .kcFailed)
            XCTAssertNil(CallEndTrust.verdictToPersist(stashed: .nfcAuthenticated, failureSource: source, reason: "dtls_fp_mismatch"))
        }
    }

    func testAReasonFromTheRelayAloneChangesNothing() {
        let t = CallEndTrust.decide(failureSource: .relay, identityHeldUnconfirmed: false)
        XCTAssertTrue(t.finalizeInPersonKeys)
        XCTAssertFalse(t.downgradeStashedVerdict)
        XCTAssertEqual(CallEndTrust.verdictToPersist(stashed: .pskConfirmed, failureSource: .relay, reason: "dtls_fp_mismatch"), .pskConfirmed)
    }

    func testMediaStillHeldForAnUnconfirmedIdentityIsNotACleanEnd() {
        XCTAssertFalse(CallEndTrust.decide(failureSource: nil, identityHeldUnconfirmed: true).finalizeInPersonKeys)
        XCTAssertFalse(CallEndTrust.decide(failureSource: .relay, identityHeldUnconfirmed: true).finalizeInPersonKeys)
    }

    func testHeldFinalizationsRunOnlyForACleanEnd() {
        for (source, held, expected) in [
            (nil as HandshakeFailureSource?, false, ["new"]), (.relay, false, ["new"]),
            (.local, false, []), (.authenticatedPeer, false, []), (nil, true, []),
        ] as [(HandshakeFailureSource?, Bool, [String])] {
            var deferred = DeferredInPersonFinalize()
            XCTAssertEqual(deferred.submit(callId: "c", names: ["new"], rekeyWaitingForAccept: true), [])
            let t = CallEndTrust.decide(failureSource: source, identityHeldUnconfirmed: held)
            XCTAssertEqual(deferred.flushOnEnd(callId: "c", endedOnHandshakeFailure: !t.finalizeInPersonKeys), expected)
        }
    }
}

final class HandshakeFailureSourcePrecedenceTests: XCTestCase {
    func testASourceIsNeverWeakenedByALaterReport() {
        // The peer's authenticated frame, then the relayed envelope for the same failure.
        var s = HandshakeFailureSource.strongest(nil, .authenticatedPeer)
        s = HandshakeFailureSource.strongest(s, .relay)
        XCTAssertEqual(s, .authenticatedPeer)
        XCTAssertFalse(CallEndTrust.decide(failureSource: s, identityHeldUnconfirmed: false).finalizeInPersonKeys)
        // Either order, and a local failure outranks both.
        XCTAssertEqual(HandshakeFailureSource.strongest(.relay, .authenticatedPeer), .authenticatedPeer)
        XCTAssertEqual(HandshakeFailureSource.strongest(.authenticatedPeer, .local), .local)
        XCTAssertEqual(HandshakeFailureSource.strongest(.local, .relay), .local)
        XCTAssertEqual(HandshakeFailureSource.strongest(nil, .relay), .relay)
    }
}

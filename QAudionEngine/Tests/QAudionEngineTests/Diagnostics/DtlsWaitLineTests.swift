import XCTest
@testable import QAudionEngine

/// W-DTLSWAIT (2026-10-07) -- the `dtls wait` line of the DTLS handshake wait and the schedule that decides when it is
/// printed. Pure logic, no PeerConnection. The exact strings below are the SAME texts that
/// scripts/test_ship_ios_dtlswait_vocab.py pushes through the phone-log shipper (ship-ios-logs.py): change one side
/// and the other must follow, or the line stops reaching the server.
final class DtlsWaitLineTests: XCTestCase {

    // MARK: - the exact text

    func test_firstLineOfACallStillChecking() {
        XCTAssertEqual(
            DtlsWaitLine.format(count: 1, elapsedMs: 0, localType: "host", networkTypeCode: 3, remoteType: "host",
                                pairState: "in-progress", bytesSent: 0, bytesReceived: 0, dtlsState: "connecting"),
            "dtls wait count=1 ms=0 lct=host nt=3 rct=host cps=running sent=0 recv=0 state=connecting")
    }

    func test_aSucceededRelayPairWithDtlsBytesInBothDirections() {
        XCTAssertEqual(
            DtlsWaitLine.format(count: 7, elapsedMs: 6034, localType: "relay", networkTypeCode: 1, remoteType: "srflx",
                                pairState: "succeeded", bytesSent: 123_456, bytesReceived: 789_012,
                                dtlsState: "connecting"),
            "dtls wait count=7 ms=6034 lct=relay nt=1 rct=srflx cps=ok sent=123456 recv=789012 state=connecting")
    }

    func test_theStalledShapeTheIncidentLookedLike() {
        // ClientHello out, nothing back: sent grows, recv stays 0.
        XCTAssertEqual(
            DtlsWaitLine.format(count: 3, elapsedMs: 2150, localType: "host", networkTypeCode: 3, remoteType: "host",
                                pairState: "succeeded", bytesSent: 1420, bytesReceived: 0, dtlsState: "connecting"),
            "dtls wait count=3 ms=2150 lct=host nt=3 rct=host cps=ok sent=1420 recv=0 state=connecting")
    }

    func test_theLineThatShowsDtlsConnected() {
        XCTAssertEqual(
            DtlsWaitLine.format(count: 2, elapsedMs: 480, localType: "prflx", networkTypeCode: 6, remoteType: "prflx",
                                pairState: "succeeded", bytesSent: 2210, bytesReceived: 2046, dtlsState: "connected"),
            "dtls wait count=2 ms=480 lct=prflx nt=6 rct=prflx cps=ok sent=2210 recv=2046 state=connected")
    }

    func test_nothingKnownYetPrintsNoneAndLeavesTheByteCountersOut() {
        XCTAssertEqual(
            DtlsWaitLine.format(count: 2, elapsedMs: 1000, localType: nil, networkTypeCode: 0, remoteType: nil,
                                pairState: nil, bytesSent: -1, bytesReceived: -1, dtlsState: nil),
            "dtls wait count=2 ms=1000 lct=none nt=0 rct=none cps=none state=none")
    }

    func test_oneCounterMissingIsOmittedTheOtherKept() {
        XCTAssertEqual(
            DtlsWaitLine.format(count: 4, elapsedMs: 3000, localType: "host", networkTypeCode: 2, remoteType: "host",
                                pairState: "waiting", bytesSent: 900, bytesReceived: -1, dtlsState: "new"),
            "dtls wait count=4 ms=3000 lct=host nt=2 rct=host cps=waiting sent=900 state=new")
    }

    func test_theLargestValuesStayInsideTheShippersNumberBudget() {
        // ms is capped at 5 digits and the byte counters at 7, so at most two numbers of 6+ digits are ever printed.
        XCTAssertEqual(
            DtlsWaitLine.format(count: 20, elapsedMs: 123_456_789, localType: "relay", networkTypeCode: 4,
                                remoteType: "relay", pairState: "failed", bytesSent: 99_999_999_999,
                                bytesReceived: 12_345_678, dtlsState: "failed"),
            "dtls wait count=20 ms=99999 lct=relay nt=4 rct=relay cps=failed sent=9999999 recv=9999999 state=failed")
    }

    func test_aNegativeElapsedTimeIsZeroNeverMinus() {
        XCTAssertEqual(
            DtlsWaitLine.format(count: 1, elapsedMs: -5, localType: "host", networkTypeCode: 0, remoteType: "host",
                                pairState: "frozen", bytesSent: 0, bytesReceived: 0, dtlsState: "new"),
            "dtls wait count=1 ms=0 lct=host nt=0 rct=host cps=frozen sent=0 recv=0 state=new")
    }

    // MARK: - closed word sets: nothing the stats API says reaches the line unmapped

    func test_pairStatesAreShortenedToSevenLettersOrLess() {
        XCTAssertEqual(DtlsWaitLine.pairStateWord("frozen"), "frozen")
        XCTAssertEqual(DtlsWaitLine.pairStateWord("waiting"), "waiting")
        XCTAssertEqual(DtlsWaitLine.pairStateWord("in-progress"), "running")
        XCTAssertEqual(DtlsWaitLine.pairStateWord("succeeded"), "ok")
        XCTAssertEqual(DtlsWaitLine.pairStateWord("failed"), "failed")
        XCTAssertEqual(DtlsWaitLine.pairStateWord("cancelled"), "cancel")
        XCTAssertEqual(DtlsWaitLine.pairStateWord(nil), "none")
        XCTAssertEqual(DtlsWaitLine.pairStateWord("something-new"), "other")
    }

    func test_candidateTypesAndDtlsStatesOutsideTheKnownSetBecomeOther() {
        XCTAssertEqual(DtlsWaitLine.typeWord("HOST"), "host")
        XCTAssertEqual(DtlsWaitLine.typeWord(nil), "none")
        XCTAssertEqual(DtlsWaitLine.typeWord("192.0.2.7"), "other", "an address must never be echoed")
        XCTAssertEqual(DtlsWaitLine.dtlsStateWord("connected"), "connected")
        XCTAssertEqual(DtlsWaitLine.dtlsStateWord(nil), "none")
        XCTAssertEqual(DtlsWaitLine.dtlsStateWord("abcdefghijklmnop"), "other")
        let line = DtlsWaitLine.format(count: 1, elapsedMs: 1, localType: "192.0.2.7", networkTypeCode: 0,
                                       remoteType: "2001:db8::1", pairState: "x", bytesSent: 0, bytesReceived: 0,
                                       dtlsState: "y")
        XCTAssertEqual(line, "dtls wait count=1 ms=1 lct=other nt=0 rct=other cps=other sent=0 recv=0 state=other")
    }

    // MARK: - which pair is described

    private func pair(_ id: String, _ state: String?, nominated: Bool = false) -> DtlsWaitLine.Pair {
        DtlsWaitLine.Pair(id: id, state: state, nominated: nominated, localId: "L" + id, remoteId: "R" + id)
    }

    func test_theTransportsSelectedPairWinsOverEverythingElse() {
        let pairs = [pair("a", "succeeded", nominated: true), pair("b", "in-progress"), pair("c", "waiting")]
        XCTAssertEqual(DtlsWaitLine.pick(pairs, selectedId: "c")?.id, "c")
    }

    func test_withoutASelectedPairTheOrderIsNominatedSucceededNominatedSucceededInProgress() {
        XCTAssertEqual(DtlsWaitLine.pick([pair("a", "succeeded"), pair("b", "succeeded", nominated: true)],
                                         selectedId: nil)?.id, "b")
        XCTAssertEqual(DtlsWaitLine.pick([pair("a", "succeeded"), pair("b", "in-progress", nominated: true)],
                                         selectedId: nil)?.id, "b")
        XCTAssertEqual(DtlsWaitLine.pick([pair("a", "in-progress"), pair("b", "succeeded")], selectedId: nil)?.id, "b")
        XCTAssertEqual(DtlsWaitLine.pick([pair("a", "waiting"), pair("b", "in-progress")], selectedId: nil)?.id, "b")
    }

    func test_aPairStillWaitingOrFrozenIsNotDescribedAndAnUnknownSelectedIdFallsThrough() {
        XCTAssertNil(DtlsWaitLine.pick([pair("a", "waiting"), pair("b", "frozen")], selectedId: nil))
        XCTAssertNil(DtlsWaitLine.pick([], selectedId: "zzz"))
        XCTAssertEqual(DtlsWaitLine.pick([pair("a", "succeeded")], selectedId: "zzz")?.id, "a")
    }

    func test_theChoiceDoesNotDependOnTheOrderTheStatsArrivedIn() {
        let one = [pair("p2", "succeeded"), pair("p1", "succeeded")]
        let two = [pair("p1", "succeeded"), pair("p2", "succeeded")]
        XCTAssertEqual(DtlsWaitLine.pick(one, selectedId: nil)?.id, "p1")
        XCTAssertEqual(DtlsWaitLine.pick(two, selectedId: nil)?.id, "p1")
    }

    // MARK: - when a line is printed

    func test_nothingIsDueBeforeIceReportsAnything() {
        let probe = DtlsWaitProbe()
        XCTAssertFalse(probe.wantsSample(nowMs: 1_000))
        var copy = probe
        XCTAssertNil(copy.take(nowMs: 1_000, dtlsState: "connecting"))
    }

    func test_theFirstLineCountsMillisecondsFromTheFirstIceActivity() {
        var probe = DtlsWaitProbe()
        probe.noteIceActive(nowMs: 10_000)
        probe.noteIceActive(nowMs: 12_000)   // a second checking edge (ICE restart) does not move the start
        let first = probe.take(nowMs: 11_000, dtlsState: "connecting")
        XCTAssertEqual(first?.count, 1)
        XCTAssertEqual(first?.elapsedMs, 1_000)
    }

    func test_atMostOneLinePerAboutASecondWhoeverAsks() {
        var probe = DtlsWaitProbe()
        probe.noteIceActive(nowMs: 0)
        XCTAssertNotNil(probe.take(nowMs: 100, dtlsState: "connecting"))
        XCTAssertFalse(probe.wantsSample(nowMs: 600))
        XCTAssertNil(probe.take(nowMs: 600, dtlsState: "connecting"))
        XCTAssertNil(probe.take(nowMs: 999, dtlsState: "connecting"))      // 899 ms after the last line
        XCTAssertEqual(probe.take(nowMs: 1_000, dtlsState: "connecting")?.count, 2)   // 900 ms
        XCTAssertEqual(probe.take(nowMs: 2_005, dtlsState: "connecting")?.count, 3)
    }

    func test_theLineThatShowsConnectedIsTheLastAndNothingIsDueAfterIt() {
        var probe = DtlsWaitProbe()
        probe.noteIceActive(nowMs: 0)
        XCTAssertNotNil(probe.take(nowMs: 1_000, dtlsState: "connecting"))
        XCTAssertFalse(probe.finished)
        XCTAssertEqual(probe.take(nowMs: 2_000, dtlsState: "connected")?.count, 2)
        XCTAssertTrue(probe.finished)
        XCTAssertFalse(probe.wantsSample(nowMs: 60_000), "once connected the stats callback does no extra work")
        XCTAssertNil(probe.take(nowMs: 60_000, dtlsState: "connected"))
        probe.noteIceActive(nowMs: 61_000)
        XCTAssertFalse(probe.wantsSample(nowMs: 120_000), "a later ICE restart does not reopen it")
    }

    func test_neverMoreThanTwentyLinesEvenIfTheHandshakeNeverEnds() {
        var probe = DtlsWaitProbe()
        probe.noteIceActive(nowMs: 0)
        var printed = 0
        var last: Int?
        for second in 1...120 {
            if let due = probe.take(nowMs: Int64(second) * 1_000, dtlsState: "connecting") {
                printed += 1
                last = due.count
            }
        }
        XCTAssertEqual(printed, DtlsWaitLine.maxLines)
        XCTAssertEqual(last, 20)
        XCTAssertTrue(probe.finished)
    }

    func test_aFailedDtlsStateKeepsLoggingUntilTheCap() {
        var probe = DtlsWaitProbe()
        probe.noteIceActive(nowMs: 0)
        XCTAssertNotNil(probe.take(nowMs: 1_000, dtlsState: "failed"))
        XCTAssertFalse(probe.finished)
        XCTAssertNotNil(probe.take(nowMs: 2_000, dtlsState: "closed"))
    }
}

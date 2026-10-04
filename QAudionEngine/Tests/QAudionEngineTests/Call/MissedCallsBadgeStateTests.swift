import XCTest
@testable import QAudionEngine

/// W-MISSEDBADGE (2026-10-04) — the Calls-tab number: missed calls the user has not looked at yet.
///
/// Owner spec: a call that reaches a busy user (or that he did not answer) shows up in the CALLS section, a row with
/// who and when plus a number on the tab, never through chat. The row existed on iOS; the number did not (Android has
/// `MissedCallsBadge`). The model is Android's: the count is derived from the history against a persisted "seen up
/// to" mark, opening the Calls tab moves the mark, a first run starts it at "now", and a new account starts it again.
///
/// `MissedCallsBadgeTests` (app target) drives the object that holds this state with a fake history; here the rules.
final class MissedCallsBadgeStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func missed(_ seconds: TimeInterval) -> MissedCallStamp { MissedCallStamp(isMissed: true, at: at(seconds)) }
    private func answered(_ seconds: TimeInterval) -> MissedCallStamp { MissedCallStamp(isMissed: false, at: at(seconds)) }

    // MARK: - counting

    /// Only missed calls count, and only the ones after the mark. Without the `isMissed` filter every answered call
    /// would be a number on the tab.
    func testOnlyMissedCallsAfterTheMarkCount() {
        let state = MissedCallsBadgeState(seenUpTo: at(100))
        let stamps = [missed(50), missed(150), answered(160), missed(200), answered(10)]
        XCTAssertEqual(state.unreadCount(in: stamps), 2, "the missed calls at 150 and 200")
    }

    /// A call at exactly the mark was seen (the mark IS the instant everything up to was looked at).
    func testACallAtTheMarkIsSeen() {
        let state = MissedCallsBadgeState(seenUpTo: at(100))
        XCTAssertEqual(state.unreadCount(in: [missed(100)]), 0)
        XCTAssertEqual(state.unreadCount(in: [missed(100.001)]), 1)
    }

    func testAnEmptyHistoryIsNoBadge() {
        XCTAssertEqual(MissedCallsBadgeState(seenUpTo: at(0)).unreadCount(in: []), 0)
    }

    // MARK: - seen

    /// Opening the Calls tab: the count goes to 0 and a later missed call counts again. Without moving the mark the
    /// number would never go away.
    func testOpeningTheCallsTabClearsTheCountAndTheNextMissedCallCountsAgain() {
        var state = MissedCallsBadgeState(seenUpTo: at(0))
        var stamps = [missed(10), missed(20)]
        XCTAssertEqual(state.unreadCount(in: stamps), 2)
        XCTAssertTrue(state.markSeen(now: at(30), in: stamps))
        XCTAssertEqual(state.seenUpTo, at(30))
        XCTAssertEqual(state.unreadCount(in: stamps), 0)
        stamps.append(missed(45))
        XCTAssertEqual(state.unreadCount(in: stamps), 1, "a call missed after the user looked")
    }

    /// A row dated ahead of the phone clock (a clock that was set back): the mark goes to the newest missed call, or
    /// the row the user is looking at would stay unread for good.
    func testTheMarkIsTheLaterOfNowAndTheNewestMissedCall() {
        var state = MissedCallsBadgeState(seenUpTo: at(0))
        let stamps = [missed(10), missed(500)]
        XCTAssertTrue(state.markSeen(now: at(100), in: stamps))
        XCTAssertEqual(state.seenUpTo, at(500))
        XCTAssertEqual(state.unreadCount(in: stamps), 0)
    }

    /// An answered call in the future does not move the mark.
    func testAnAnsweredCallNeverMovesTheMark() {
        var state = MissedCallsBadgeState(seenUpTo: at(0))
        XCTAssertTrue(state.markSeen(now: at(100), in: [answered(900)]))
        XCTAssertEqual(state.seenUpTo, at(100))
    }

    /// The mark only moves forward, and says whether it moved (so nothing is written for nothing).
    func testTheMarkNeverMovesBackAndReportsWhetherItMoved() {
        var state = MissedCallsBadgeState(seenUpTo: at(200))
        XCTAssertFalse(state.markSeen(now: at(100), in: [missed(50)]), "now is before the mark")
        XCTAssertEqual(state.seenUpTo, at(200))
        XCTAssertFalse(state.markSeen(now: at(200), in: []), "same instant")
        XCTAssertTrue(state.markSeen(now: at(201), in: []))
    }

    // MARK: - first run and new account

    /// First run: nothing stored, the mark is now, so the missed calls already in the history are not announced as new
    /// when the feature first ships. Without it every old missed call would be a number on the tab at the first launch.
    func testAFirstRunAnnouncesNothingThatIsAlreadyInTheHistory() {
        let state = MissedCallsBadgeState.restored(stored: nil, now: at(1_000))
        XCTAssertEqual(state.seenUpTo, at(1_000))
        XCTAssertEqual(state.unreadCount(in: [missed(10), missed(900)]), 0)
        XCTAssertEqual(state.unreadCount(in: [missed(1_001)]), 1)
    }

    func testAStoredMarkIsRestoredAsIs() {
        let state = MissedCallsBadgeState.restored(stored: t0.timeIntervalSince1970 + 77, now: at(1_000))
        XCTAssertEqual(state.seenUpTo, at(77))
    }

    func testAnUnusableStoredMarkIsTreatedAsNone() {
        XCTAssertEqual(MissedCallsBadgeState.restored(stored: 0, now: at(5)).seenUpTo, at(5))
        XCTAssertEqual(MissedCallsBadgeState.restored(stored: -3, now: at(5)).seenUpTo, at(5))
    }

    /// A new account on the device starts from now: whatever the previous account had unread is gone from the count,
    /// and the new account's first missed call counts.
    func testANewAccountStartsFromNow() {
        let previous = MissedCallsBadgeState(seenUpTo: at(0))
        let leftovers = [missed(10), missed(20), missed(30)]
        XCTAssertEqual(previous.unreadCount(in: leftovers), 3)
        let fresh = MissedCallsBadgeState.forNewAccount(now: at(100))
        XCTAssertEqual(fresh.seenUpTo, at(100))
        XCTAssertEqual(fresh.unreadCount(in: leftovers), 0)
        XCTAssertEqual(fresh.unreadCount(in: leftovers + [missed(101)]), 1)
    }

    // MARK: - when the tab counts as looked at

    /// Selected AND the app on screen: a tab left selected in a backgrounded app has shown nothing to anybody, and a
    /// tab that is not selected has not either.
    func testTheTabIsLookedAtOnlyWhenSelectedAndTheAppIsActive() {
        XCTAssertTrue(MissedCallsBadgeState.countsAsLookedAt(callsTabSelected: true, appActive: true))
        XCTAssertFalse(MissedCallsBadgeState.countsAsLookedAt(callsTabSelected: true, appActive: false))
        XCTAssertFalse(MissedCallsBadgeState.countsAsLookedAt(callsTabSelected: false, appActive: true))
        XCTAssertFalse(MissedCallsBadgeState.countsAsLookedAt(callsTabSelected: false, appActive: false))
    }
}

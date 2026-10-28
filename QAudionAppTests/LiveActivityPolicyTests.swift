import XCTest
@testable import QAudionApp

/// The pure rules of the Live Activities: which transfers get one, the 2 second throttle, the contact name that is shown only when
/// previews are allowed, the state mapping and the plan of what to start, update and end.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class LiveActivityPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Which transfers

    func test_onlyFilesAboveFiveMegabytesQualify() {
        XCTAssertFalse(LiveActivityPolicy.qualifiesFile(totalBytes: 0))
        XCTAssertFalse(LiveActivityPolicy.qualifiesFile(totalBytes: 5_000_000))
        XCTAssertTrue(LiveActivityPolicy.qualifiesFile(totalBytes: 5_000_001))
        XCTAssertTrue(LiveActivityPolicy.qualifiesFile(totalBytes: 250_000_000))
    }

    func test_fractionIsClampedAndZeroWithoutATotal() {
        XCTAssertEqual(LiveActivityPolicy.fraction(done: 50, total: 200), 0.25, accuracy: 1e-9)
        XCTAssertEqual(LiveActivityPolicy.fraction(done: 300, total: 200), 1)
        XCTAssertEqual(LiveActivityPolicy.fraction(done: -5, total: 200), 0)
        XCTAssertEqual(LiveActivityPolicy.fraction(done: 10, total: 0), 0)
    }

    // MARK: Throttle

    func test_throttleLetsTheFirstProgressThrough() {
        var throttle = LiveActivityThrottle()
        XCTAssertTrue(throttle.accept(progress: 0.1, now: 100))
    }

    func test_throttleHoldsUpdatesCloserThanTwoSeconds() {
        var throttle = LiveActivityThrottle()
        XCTAssertTrue(throttle.accept(progress: 0.1, now: 100))
        XCTAssertFalse(throttle.accept(progress: 0.2, now: 100.5))
        XCTAssertFalse(throttle.accept(progress: 0.3, now: 101.9))
        XCTAssertTrue(throttle.accept(progress: 0.4, now: 102))
    }

    func test_throttleSkipsAnUpdateThatChangesNothing() {
        var throttle = LiveActivityThrottle()
        XCTAssertTrue(throttle.accept(progress: 0.5, now: 100))
        XCTAssertFalse(throttle.accept(progress: 0.5, now: 110))
        XCTAssertTrue(throttle.accept(progress: 0.6, now: 111))
    }

    func test_aRejectedUpdateDoesNotMoveTheClock() {
        var throttle = LiveActivityThrottle()
        XCTAssertTrue(throttle.accept(progress: 0.1, now: 100))
        XCTAssertFalse(throttle.accept(progress: 0.2, now: 101))
        // 2 seconds after the last ACCEPTED update, not after the rejected one.
        XCTAssertTrue(throttle.accept(progress: 0.3, now: 102))
    }

    // MARK: Contact name and previews

    func test_theNameIsShownOnlyWhenPreviewsAreAllowed() {
        XCTAssertTrue(LiveActivityPolicy.previewsAllowed(messagePreviewInNotifications: true, hideNotificationContent: false))
        XCTAssertFalse(LiveActivityPolicy.previewsAllowed(messagePreviewInNotifications: false, hideNotificationContent: false))
        XCTAssertFalse(LiveActivityPolicy.previewsAllowed(messagePreviewInNotifications: true, hideNotificationContent: true))
        XCTAssertFalse(LiveActivityPolicy.previewsAllowed(messagePreviewInNotifications: false, hideNotificationContent: true))
    }

    func test_contactNameFollowsThePreviewSetting() {
        XCTAssertEqual(LiveActivityPolicy.contactName("Anna Rossi", previewsAllowed: true), "Anna Rossi")
        XCTAssertEqual(LiveActivityPolicy.contactName("  Anna  ", previewsAllowed: true), "Anna")
        XCTAssertNil(LiveActivityPolicy.contactName("Anna Rossi", previewsAllowed: false))
        XCTAssertNil(LiveActivityPolicy.contactName("   ", previewsAllowed: true))
    }

    // MARK: State mapping

    func test_aShareMapsToItsEndTimeAndTheAllowedName() {
        let share = LiveActivityPolicy.Share(id: "s1", peerUserId: "u1", startedAt: t0, endAt: t0.addingTimeInterval(3_600))
        let shown = LiveActivityPolicy.content(for: share, name: "Anna", previewsAllowed: true)
        XCTAssertEqual(shown.contactName, "Anna")
        XCTAssertEqual(shown.startDate, t0)
        XCTAssertEqual(shown.endDate, t0.addingTimeInterval(3_600))
        let hidden = LiveActivityPolicy.content(for: share, name: "Anna", previewsAllowed: false)
        XCTAssertNil(hidden.contactName)
        XCTAssertEqual(hidden.endDate, shown.endDate)
    }

    func test_aTransferMapsToItsProgressAndNeverNamesAContact() {
        let state = LiveActivityPolicy.content(startedAt: t0, done: 30, total: 120)
        XCTAssertEqual(state.progress, 0.25, accuracy: 1e-9)
        XCTAssertNil(state.contactName)
        XCTAssertNil(state.endDate)
    }

    func test_theStateSurvivesACodableRoundTrip() throws {
        let state = LiveActivityContent(contactName: "Anna", startDate: t0, endDate: t0.addingTimeInterval(900), progress: 0)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(LiveActivityContent.self, from: data), state)
    }

    // MARK: Plan

    private func content(_ name: String?) -> LiveActivityContent {
        LiveActivityContent(contactName: name, startDate: t0, endDate: t0.addingTimeInterval(900), progress: 0)
    }

    func test_planStartsNewEndsGoneAndUpdatesChanged() {
        let running = ["a": content("A"), "b": content("B"), "c": content("C")]
        let wanted = ["b": content("B"), "c": content(nil), "d": content("D")]
        let plan = LiveActivityPolicy.plan(running: running, wanted: wanted)
        XCTAssertEqual(plan, LiveActivityPolicy.Plan(start: ["d"], update: ["c"], end: ["a"]))
    }

    func test_planIsEmptyWhenNothingChanged() {
        let same = ["a": content("A")]
        XCTAssertEqual(LiveActivityPolicy.plan(running: same, wanted: same), LiveActivityPolicy.Plan())
    }

    func test_planEndsEverythingWhenNoShareIsLeft() {
        let plan = LiveActivityPolicy.plan(running: ["a": content("A"), "b": content("B")], wanted: [:])
        XCTAssertEqual(plan.end, ["a", "b"])
        XCTAssertTrue(plan.start.isEmpty)
        XCTAssertTrue(plan.update.isEmpty)
    }
}

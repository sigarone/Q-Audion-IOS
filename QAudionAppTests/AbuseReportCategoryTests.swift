import XCTest
@testable import QAudionApp

/// The in-app report flow: who can be reported, for what, and what travels.
///
///   - Categories: child safety, intimate images without consent and threats were added to spam, abuse and other, most
///     serious first. The wire values are the canonical ids of the receiving side, exactly: `child_safety`,
///     `non_consensual_intimate_imagery`, `threat`, `abuse`, `spam`, `other`.
///   - A report carries the category, the ids and the name of the reported person or group, and the user's own note. It
///     never carries message content: no screenshot, no log tail, no text of the chat.
///   - The Settings row opens the same report sheet as the gestures, under a trigger source of its own.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class AbuseReportCategoryTests: XCTestCase {

    // MARK: - The list

    func test_theListIsTheSixCategoriesMostSeriousFirst() {
        XCTAssertEqual(AbuseReportCategory.allCases.map { $0.wireValue },
                       ["child_safety", "non_consensual_intimate_imagery", "threat", "abuse", "spam", "other"])
    }

    /// The server files a report under exactly these ids; an id it does not know is filed as "other", so a typo here would
    /// quietly turn a child-safety report into a generic one.
    func test_everyWireValueIsTheServersCanonicalId() {
        XCTAssertEqual(AbuseReportCategory.childSafety.wireValue, "child_safety")
        XCTAssertEqual(AbuseReportCategory.nonConsensualIntimateImagery.wireValue, "non_consensual_intimate_imagery")
        XCTAssertEqual(AbuseReportCategory.threat.wireValue, "threat")
        XCTAssertEqual(AbuseReportCategory.abuse.wireValue, "abuse")
        XCTAssertEqual(AbuseReportCategory.spam.wireValue, "spam")
        XCTAssertEqual(AbuseReportCategory.other.wireValue, "other")
    }

    func test_noWireValueIsAnAliasOfTheCanonicalIds() {
        let aliases = ["intimate_images", "threats", "minors", "ncii"]
        for category in AbuseReportCategory.allCases {
            XCTAssertFalse(aliases.contains(category.wireValue), "\(category.wireValue) is an alias, not the canonical id")
        }
    }

    func test_everyCategoryHasADistinctNonEmptyTitle() {
        let titles = AbuseReportCategory.allCases.map { $0.title }
        XCTAssertFalse(titles.contains(""))
        XCTAssertEqual(Set(titles).count, titles.count, "two buttons with the same label")
    }

    // MARK: - What travels

    func test_aReportAboutAPersonCarriesTheCategoryAndWhoItIsAboutAndNothingFromTheChat() async throws {
        let reporter = BugReporter(forTesting: ())
        reporter.configure(getToken: { "token" },
                           getServerUrl: { "https://example.invalid" },
                           getActiveCallId: { nil },
                           getDiagSnapshot: { "" })
        let attempted = expectation(description: "the report reached the uploader")
        var captured: BugReporter.QueuedReport?
        reporter.attemptOverride = { queued in
            captured = queued
            attempted.fulfill()
            return .done
        }

        reporter.reportAbuse(reportedUserId: "user-1",
                             reportedGroupId: nil,
                             reportedName: "Anna",
                             category: .childSafety,
                             note: "")
        await fulfillment(of: [attempted], timeout: 10)

        let queued = try XCTUnwrap(captured)
        XCTAssertEqual(queued.report.trigger, "abuse")
        XCTAssertNil(queued.report.screenshot, "no screenshot: it could show the chat")
        XCTAssertTrue(queued.report.logEntries.isEmpty, "no log tail")
        XCTAssertEqual(queued.report.extraFields["report_category"], "child_safety")
        XCTAssertEqual(queued.report.extraFields["reported_user_id"], "user-1")
        XCTAssertNil(queued.report.extraFields["reported_group_id"])
        XCTAssertEqual(queued.note.components(separatedBy: "\n"),
                       ["ABUSE REPORT", "category=child_safety", "reported_user_id=user-1", "reported_name=Anna"],
                       "the body is the category, the ids and the name, and nothing else")
    }

    func test_aReportAboutAGroupCarriesTheGroupIdAndTheNewCategories() async throws {
        let reporter = BugReporter(forTesting: ())
        reporter.configure(getToken: { "token" },
                           getServerUrl: { "https://example.invalid" },
                           getActiveCallId: { nil },
                           getDiagSnapshot: { "" })
        let attempted = expectation(description: "the report reached the uploader")
        var captured: BugReporter.QueuedReport?
        reporter.attemptOverride = { queued in
            captured = queued
            attempted.fulfill()
            return .done
        }

        reporter.reportAbuse(reportedUserId: nil,
                             reportedGroupId: "group-1",
                             reportedName: "Gruppo",
                             category: .nonConsensualIntimateImagery,
                             note: "")
        await fulfillment(of: [attempted], timeout: 10)

        let queued = try XCTUnwrap(captured)
        XCTAssertEqual(queued.report.extraFields["report_category"], "non_consensual_intimate_imagery")
        XCTAssertEqual(queued.report.extraFields["reported_group_id"], "group-1")
        XCTAssertNil(queued.report.extraFields["reported_user_id"])
        XCTAssertNil(queued.report.screenshot)
        XCTAssertTrue(queued.report.logEntries.isEmpty)
    }

    // MARK: - The Settings row

    func test_theSettingsRowHasATriggerSourceOfItsOwn() {
        XCTAssertEqual(BugReporter.TriggerSource.settings.rawValue, 3)
        let raw = [BugReporter.TriggerSource.volumeGesture, .shake, .settings].map { $0.rawValue }
        XCTAssertEqual(Set(raw).count, 3, "the source is logged as trig src=<n>, so the three must differ")
    }
}

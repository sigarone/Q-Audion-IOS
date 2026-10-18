import XCTest
@testable import QAudionApp

/// `RecoveryEnrollmentStatus` decides whether the recovery-phrase reminders
/// (Settings banner, chat-list banner) show for an account. The rule under
/// test: the reminder needs POSITIVE evidence that the account started out
/// without a phrase (the onboarding reveal of a registration made on this
/// device recorded it) and no enrolment since. The absence of a record proves
/// nothing, because the flag is per install and accounts enrolled on an earlier
/// build, or signing in on a second device, have none.
///
/// Every case runs against a private UserDefaults suite, so nothing touches the
/// device's real defaults and the cases cannot see each other.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and
/// in the `-only-testing` list of `.github/workflows/ios-app-tests.yml`.
final class RecoveryEnrollmentStatusTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let name: String = "recovery-status-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - the reminder needs evidence

    /// The regression this type exists to prevent: an account with no record at
    /// all (enrolled on an earlier build, or just signed in on another device)
    /// must NOT be nagged. The first version nagged exactly these, with a
    /// Settings banner that could not be dismissed.
    func test_anAccountWithNoRecordIsNeverReminded() {
        let d = makeDefaults()
        XCTAssertFalse(RecoveryEnrollmentStatus.needsReminder(userId: "old-build-account", defaults: d))
        XCTAssertFalse(RecoveryEnrollmentStatus.isEnrolled(userId: "old-build-account", defaults: d))
    }

    func test_aRegistrationThatStartedTheRevealIsRemindedUntilItEnrols() {
        let d = makeDefaults()
        RecoveryEnrollmentStatus.markAwaitingEnrollment(userId: "new", defaults: d)
        XCTAssertTrue(RecoveryEnrollmentStatus.needsReminder(userId: "new", defaults: d),
                      "recoverySetup failed or the app was closed mid-reveal: the account has no phrase on record")
        XCTAssertFalse(RecoveryEnrollmentStatus.isEnrolled(userId: "new", defaults: d))

        RecoveryEnrollmentStatus.markEnrolled(userId: "new", defaults: d)
        XCTAssertFalse(RecoveryEnrollmentStatus.needsReminder(userId: "new", defaults: d),
                       "a successful enrolment ends the reminder")
        XCTAssertTrue(RecoveryEnrollmentStatus.isEnrolled(userId: "new", defaults: d))
    }

    /// Restoring from a phrase enrols without ever having been "awaiting": it
    /// must simply leave the account un-nagged, and enrolment must win even if
    /// an awaiting record is written afterwards.
    func test_enrolmentWinsOverAnAwaitingRecord() {
        let d = makeDefaults()
        RecoveryEnrollmentStatus.markEnrolled(userId: "restored", defaults: d)
        XCTAssertFalse(RecoveryEnrollmentStatus.needsReminder(userId: "restored", defaults: d))

        RecoveryEnrollmentStatus.markAwaitingEnrollment(userId: "restored", defaults: d)
        XCTAssertFalse(RecoveryEnrollmentStatus.needsReminder(userId: "restored", defaults: d))
    }

    // MARK: - per account

    func test_theStateBelongsToOneAccountOnly() {
        let d = makeDefaults()
        RecoveryEnrollmentStatus.markAwaitingEnrollment(userId: "a", defaults: d)
        XCTAssertTrue(RecoveryEnrollmentStatus.needsReminder(userId: "a", defaults: d))
        XCTAssertFalse(RecoveryEnrollmentStatus.needsReminder(userId: "b", defaults: d),
                       "another account on the same device never inherits a reminder")

        RecoveryEnrollmentStatus.markEnrolled(userId: "b", defaults: d)
        XCTAssertTrue(RecoveryEnrollmentStatus.needsReminder(userId: "a", defaults: d),
                      "b enrolling does not answer a's reminder")
        XCTAssertFalse(RecoveryEnrollmentStatus.isEnrolled(userId: "a", defaults: d))

        RecoveryEnrollmentStatus.markEnrolled(userId: "a", defaults: d)
        XCTAssertFalse(RecoveryEnrollmentStatus.needsReminder(userId: "a", defaults: d))
        XCTAssertTrue(RecoveryEnrollmentStatus.isEnrolled(userId: "b", defaults: d))
    }

    /// No signed-in account (`currentUserId` nil reads as ""): nothing is read
    /// and nothing is written, so a half-signed-out screen never leaves a
    /// record that the next account would pick up.
    func test_anEmptyUserIdReadsAsNoReminderAndWritesNothing() {
        let d = makeDefaults()
        RecoveryEnrollmentStatus.markAwaitingEnrollment(userId: "", defaults: d)
        RecoveryEnrollmentStatus.markEnrolled(userId: "", defaults: d)
        RecoveryEnrollmentStatus.dismissBanner(userId: "", defaults: d)

        XCTAssertFalse(RecoveryEnrollmentStatus.needsReminder(userId: "", defaults: d))
        XCTAssertFalse(RecoveryEnrollmentStatus.isEnrolled(userId: "", defaults: d))
        XCTAssertFalse(RecoveryEnrollmentStatus.isBannerDismissed(userId: "", defaults: d))
        let written = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("qa.recovery") }
        XCTAssertTrue(written.isEmpty, "an empty id must not create a key every account would share")
    }

    // MARK: - dismissal

    /// The chat-list banner's close button: remembered per account, and not a
    /// substitute for enrolling (Settings keeps reminding).
    func test_dismissingTheBannerIsRememberedPerAccount_andDoesNotEndTheReminder() {
        let d = makeDefaults()
        RecoveryEnrollmentStatus.markAwaitingEnrollment(userId: "a", defaults: d)
        XCTAssertFalse(RecoveryEnrollmentStatus.isBannerDismissed(userId: "a", defaults: d))

        RecoveryEnrollmentStatus.dismissBanner(userId: "a", defaults: d)
        XCTAssertTrue(RecoveryEnrollmentStatus.isBannerDismissed(userId: "a", defaults: d))
        XCTAssertFalse(RecoveryEnrollmentStatus.isBannerDismissed(userId: "b", defaults: d))
        XCTAssertTrue(RecoveryEnrollmentStatus.needsReminder(userId: "a", defaults: d),
                      "dismissing the chat-list banner leaves the Settings reminder standing")
    }
}

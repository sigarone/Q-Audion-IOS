import XCTest
@testable import QAudionEngine

/// W-MISSEDQUIET (2026-10-04) — the "Chiamata persa" notification of a call that reached a busy user arrives while
/// he is in another call. Presented the ordinary way it brought the default chime along (`willPresent` returned
/// `[.banner, .sound, .list, .badge]` with the in-app sound on, and the notification content carried `.default`).
/// While a call is in flight it is shown quietly: banner and list, no sound, no badge. Outside a call nothing changes,
/// and no other category is ever touched.
final class MissedCallAlertPolicyTests: XCTestCase {

    typealias P = MissedCallAlertPolicy.Presentation

    /// The `willPresent` of 1.0.1207, verbatim: the behaviour that must not change outside a call.
    private func legacy(banners: Bool, quiet: Bool, sound: Bool) -> P {
        if !banners { return P(banner: false, list: true, sound: false, badge: true) }
        if quiet { return P(banner: false, list: true, sound: false, badge: true) }
        if sound { return P(banner: true, list: true, sound: true, badge: true) }
        return P(banner: true, list: true, sound: false, badge: true)
    }

    private let bools = [false, true]

    // MARK: - unchanged

    /// Outside a call, every gate combination, for a missed call and for any other notification, is what it was.
    /// Fails if the quiet rule leaks outside a call.
    func testOutsideACallNothingChangesForAnyCategory() {
        for banners in bools { for quiet in bools { for sound in bools { for missed in bools {
            let got = MissedCallAlertPolicy.foreground(
                bannersEnabled: banners, quietNow: quiet, inAppSoundEnabled: sound,
                isMissedCall: missed, callInFlight: false)
            XCTAssertEqual(got, legacy(banners: banners, quiet: quiet, sound: sound),
                           "banners=\(banners) quiet=\(quiet) sound=\(sound) missed=\(missed)")
        } } } }
    }

    /// During a call, every OTHER notification (a chat message, a threat alert) keeps whatever it had. Fails if the rule
    /// is keyed on the call alone, and not on the missed-call category.
    func testDuringACallOtherCategoriesAreUntouched() {
        for banners in bools { for quiet in bools { for sound in bools {
            let got = MissedCallAlertPolicy.foreground(
                bannersEnabled: banners, quietNow: quiet, inAppSoundEnabled: sound,
                isMissedCall: false, callInFlight: true)
            XCTAssertEqual(got, legacy(banners: banners, quiet: quiet, sound: sound),
                           "banners=\(banners) quiet=\(quiet) sound=\(sound)")
        } } }
    }

    // MARK: - quiet

    /// During a call a missed call is banner + list, with no sound and no badge, however loud the settings are. Fails
    /// if the sound is kept (the defect) or if the banner is dropped (the notification must still be seen).
    func testAMissedCallDuringACallIsBannerAndListOnly() {
        let got = MissedCallAlertPolicy.foreground(
            bannersEnabled: true, quietNow: false, inAppSoundEnabled: true, isMissedCall: true, callInFlight: true)
        XCTAssertEqual(got, P(banner: true, list: true, sound: false, badge: false))
    }

    /// Whatever the gates, a missed call during a call never has a sound, and always stays in the list.
    func testAMissedCallDuringACallNeverHasASoundOrABadgeAndStaysInTheList() {
        for banners in bools { for quiet in bools { for sound in bools {
            let got = MissedCallAlertPolicy.foreground(
                bannersEnabled: banners, quietNow: quiet, inAppSoundEnabled: sound, isMissedCall: true, callInFlight: true)
            XCTAssertFalse(got.sound, "banners=\(banners) quiet=\(quiet) sound=\(sound)")
            XCTAssertFalse(got.badge, "banners=\(banners) quiet=\(quiet) sound=\(sound)")
            XCTAssertTrue(got.list, "banners=\(banners) quiet=\(quiet) sound=\(sound)")
            XCTAssertEqual(got.banner, banners && !quiet, "the banner follows the user's own gates")
        } } }
    }

    // MARK: - the content of a local notification

    /// The content's sound is the in-app toggle, except for a missed call during a call. Fails if the content keeps
    /// the chime (a notification delivered with the app in the background never goes through `willPresent`).
    func testTheLocalContentSoundFollowsTheToggleExceptForAMissedCallDuringACall() {
        for sound in bools { for missed in bools { for inCall in bools {
            let expected = sound && !(missed && inCall)
            XCTAssertEqual(
                MissedCallAlertPolicy.localContentHasSound(inAppSoundEnabled: sound, isMissedCall: missed, callInFlight: inCall),
                expected, "sound=\(sound) missed=\(missed) inCall=\(inCall)")
        } } }
        XCTAssertFalse(MissedCallAlertPolicy.localContentHasSound(inAppSoundEnabled: true, isMissedCall: true, callInFlight: true))
        XCTAssertTrue(MissedCallAlertPolicy.localContentHasSound(inAppSoundEnabled: true, isMissedCall: true, callInFlight: false),
                      "outside a call the chime is as before")
        XCTAssertTrue(MissedCallAlertPolicy.localContentHasSound(inAppSoundEnabled: true, isMissedCall: false, callInFlight: true))
    }
}

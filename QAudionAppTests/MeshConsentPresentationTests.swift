import XCTest
@testable import QAudionApp

/// The call goes first. The Bluetooth mesh consent screen is a sheet; a ringing, connecting or running call is a full-screen
/// cover at the root. The order between the two is decided in plain values (`MeshConsentPresentation`), so it does not depend
/// on how SwiftUI times two presentations that change in the same update:
///   - the sheet is shown only for a question somebody wants asked, and never while a call is busy;
///   - a call that arrives while the sheet is up takes the sheet down first, and the call cover waits until the sheet has
///     reported that it is gone (with a bounded wait);
///   - the question comes back by itself, once, after the call, and never once it was answered;
///   - the Settings switch says what the radio is doing, not only that the consent was given.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class MeshConsentPresentationTests: XCTestCase {

    // MARK: - What counts as a busy call

    func test_aPhoneWithNoCallActivityIsNotBusy() {
        XCTAssertFalse(busy())
    }

    func test_eachSignOfACallAloneMakesItBusy() {
        XCTAssertTrue(busy(isInCall: true), "a 1:1 call in progress or being dialled")
        XCTAssertTrue(busy(callIdle: false), "a 1:1 call that is connecting, ringing, active or ending")
        XCTAssertTrue(busy(oneToOneRinging: true), "the 1:1 ring screen is up")
        XCTAssertTrue(busy(groupInvitePending: true), "a group call is ringing")
        XCTAssertTrue(busy(groupCallIdle: false), "a group call is live")
    }

    private func busy(isInCall: Bool = false,
                      callIdle: Bool = true,
                      oneToOneRinging: Bool = false,
                      groupInvitePending: Bool = false,
                      groupCallIdle: Bool = true) -> Bool {
        MeshConsentPresentation.callIsBusy(isInCall: isInCall,
                                           callIdle: callIdle,
                                           oneToOneRinging: oneToOneRinging,
                                           groupInvitePending: groupInvitePending,
                                           groupCallIdle: groupCallIdle)
    }

    // MARK: - The sheet

    func test_theSheetIsShownOnlyForAWantedQuestionAndNeverOverACall() {
        XCTAssertTrue(MeshConsentPresentation.sheetShown(wanted: true, callBusy: false))
        XCTAssertFalse(MeshConsentPresentation.sheetShown(wanted: true, callBusy: true), "a call is never covered by a sheet")
        XCTAssertFalse(MeshConsentPresentation.sheetShown(wanted: false, callBusy: false))
        XCTAssertFalse(MeshConsentPresentation.sheetShown(wanted: false, callBusy: true))
    }

    func test_theQuestionIsWantedOnlyWhileTheFeatureIsAvailableAndNobodyAnswered() {
        XCTAssertTrue(MeshStartGate.consentIsWanted(featureEnabled: true, consent: .undecided))
        XCTAssertFalse(MeshStartGate.consentIsWanted(featureEnabled: true, consent: .accepted))
        XCTAssertFalse(MeshStartGate.consentIsWanted(featureEnabled: true, consent: .declined))
        XCTAssertFalse(MeshStartGate.consentIsWanted(featureEnabled: false, consent: .undecided))
    }

    // MARK: - The call cover

    func test_theCallCoverPresentsWhenACallIsWantedAndNoSheetIsOnScreen() {
        XCTAssertTrue(MeshConsentPresentation.callCoverShown(callWanted: true, consentSheetOnScreen: false))
        XCTAssertFalse(MeshConsentPresentation.callCoverShown(callWanted: true, consentSheetOnScreen: true),
                       "it waits for the sheet to be gone, so two presentations never change in the same update")
        XCTAssertFalse(MeshConsentPresentation.callCoverShown(callWanted: false, consentSheetOnScreen: false))
        XCTAssertFalse(MeshConsentPresentation.callCoverShown(callWanted: false, consentSheetOnScreen: true))
    }

    // MARK: - The whole order

    func test_aCallThatArrivesOverTheSheetTakesItDownFirstAndTheCoverFollows() {
        var tracker = MeshConsentSheetTracker()
        let token = UUID()

        // First run, no call: the question is wanted, the sheet is shown and reported on screen.
        var wanted = MeshStartGate.consentIsWanted(featureEnabled: true, consent: .undecided)
        XCTAssertTrue(MeshConsentPresentation.sheetShown(wanted: wanted, callBusy: false))
        tracker.appeared(token)
        XCTAssertFalse(MeshConsentPresentation.callCoverShown(callWanted: false, consentSheetOnScreen: tracker.isUp))

        // A 1:1 call rings: the sheet comes down at once, and the cover does not present while the sheet is still there.
        let ringing = busy(oneToOneRinging: true)
        XCTAssertTrue(ringing)
        XCTAssertFalse(MeshConsentPresentation.sheetShown(wanted: wanted, callBusy: ringing))
        XCTAssertFalse(MeshConsentPresentation.callCoverShown(callWanted: true, consentSheetOnScreen: tracker.isUp),
                       "the sheet has not reported that it is gone yet")

        // The sheet reports that it is gone: the call cover presents.
        tracker.gone(token)
        XCTAssertFalse(tracker.isUp)
        XCTAssertTrue(MeshConsentPresentation.callCoverShown(callWanted: true, consentSheetOnScreen: tracker.isUp))

        // During the call the sheet stays away, however long it lasts.
        XCTAssertFalse(MeshConsentPresentation.sheetShown(wanted: wanted, callBusy: true))

        // The call ends and nobody answered: the question comes back by itself.
        XCTAssertTrue(MeshConsentPresentation.sheetShown(wanted: wanted, callBusy: false))
        tracker.appeared(token)

        // The user answers: it is gone for good.
        wanted = MeshStartGate.consentIsWanted(featureEnabled: true, consent: .declined)
        XCTAssertFalse(MeshConsentPresentation.sheetShown(wanted: wanted, callBusy: false))
        tracker.gone(token)
        XCTAssertFalse(tracker.isUp)
    }

    func test_aGroupCallThatIsAlreadyLiveKeepsTheSheetAwayFromTheStart() {
        let live = busy(groupCallIdle: false)
        XCTAssertFalse(MeshConsentPresentation.sheetShown(wanted: true, callBusy: live), "never presented over a call")
    }

    // MARK: - The bounded wait

    func test_theWaitForASheetIsBoundedSoACallIsNeverHeldHostage() {
        XCTAssertGreaterThan(MeshConsentPresentation.maxWaitForSheet, 0.5, "a dismissal takes about a third of a second")
        XCTAssertLessThanOrEqual(MeshConsentPresentation.maxWaitForSheet, 3, "a ringing call must not wait longer than this")
        XCTAssertGreaterThan(MeshConsentPresentation.settleAfterCall, 0)
        XCTAssertLessThan(MeshConsentPresentation.settleAfterCall, MeshConsentPresentation.maxWaitForSheet)
    }

    // MARK: - The tracker

    func test_aSheetReportedTwiceCountsOnceAndOneReportedGoneTwiceCannotGoNegative() {
        var tracker = MeshConsentSheetTracker()
        let a = UUID()
        let b = UUID()
        XCTAssertFalse(tracker.isUp)

        tracker.appeared(a)
        tracker.appeared(a)
        XCTAssertEqual(tracker.onScreen.count, 1)
        XCTAssertTrue(tracker.isUp)

        tracker.appeared(b)
        XCTAssertEqual(tracker.onScreen.count, 2, "the Settings sheet and the mesh panel's are two sheets")

        tracker.gone(a)
        tracker.gone(a)
        XCTAssertEqual(tracker.onScreen.count, 1)
        XCTAssertTrue(tracker.isUp, "one sheet is still there")

        tracker.gone(UUID())
        XCTAssertTrue(tracker.isUp, "a sheet that was never reported changes nothing")

        tracker.gone(b)
        XCTAssertFalse(tracker.isUp)
    }

    func test_writingTheSheetsOffClearsEveryOne() {
        var tracker = MeshConsentSheetTracker()
        tracker.appeared(UUID())
        tracker.appeared(UUID())
        tracker.clear()
        XCTAssertFalse(tracker.isUp)
    }

    // MARK: - The arbiter

    func test_theArbiterMirrorsTheCallAndKeepsTrackOfTheSheets() {
        let arbiter = MeshConsentArbiter()
        let token = UUID()
        XCTAssertFalse(arbiter.callBusy)
        XCTAssertFalse(arbiter.consentSheetOnScreen)

        arbiter.setCallBusy(true)
        XCTAssertTrue(arbiter.callBusy)
        arbiter.setCallBusy(false)
        XCTAssertFalse(arbiter.callBusy)

        arbiter.sheetAppeared(token)
        XCTAssertTrue(arbiter.consentSheetOnScreen)
        arbiter.sheetAppeared(token)
        arbiter.sheetGone(token)
        XCTAssertFalse(arbiter.consentSheetOnScreen, "reported twice, gone once: gone")

        arbiter.sheetAppeared(UUID())
        arbiter.clearSheets()
        XCTAssertFalse(arbiter.consentSheetOnScreen, "the bounded wait writes the sheet off")
    }

    // MARK: - What the Settings switch says

    func test_withoutTheConsentTheSwitchSaysNothingAboutTheRadioWhateverItDoes() {
        for consent in [MeshConsentState.undecided, .declined] {
            for antennaOn in [true, false] {
                for visibleOnly in [true, false] {
                    XCTAssertEqual(
                        MeshSettingsStatus.resolve(consent: consent, antennaOn: antennaOn, visibleOnly: visibleOnly),
                        .notAllowed)
                }
            }
        }
    }

    func test_withTheConsentTheSwitchSaysWhatTheRadioIsDoing() {
        XCTAssertEqual(MeshSettingsStatus.resolve(consent: .accepted, antennaOn: false, visibleOnly: false), .radioOff,
                       "consent given and the antenna turned off in the mesh panel: the phone relays nothing")
        XCTAssertEqual(MeshSettingsStatus.resolve(consent: .accepted, antennaOn: true, visibleOnly: true), .visibleOnly)
        XCTAssertEqual(MeshSettingsStatus.resolve(consent: .accepted, antennaOn: true, visibleOnly: false), .on)
    }

    func test_anAntennaThatIsOffIsNeverReportedAsOnEvenIfAModeIsStillSet() {
        XCTAssertEqual(MeshSettingsStatus.resolve(consent: .accepted, antennaOn: false, visibleOnly: true), .radioOff)
    }
}

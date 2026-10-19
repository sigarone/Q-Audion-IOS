import XCTest
@testable import QAudionApp
import QAudionEngine

/// The Bluetooth mesh relays the encrypted messages of other app users through this phone, so it starts only after the
/// user's one-time explicit consent ("Attiva" on the consent screen). These tests pin the start gate:
///   - the radio may start only when the feature is available AND the consent is accepted ("undecided" and "declined" both
///     keep it off);
///   - the consent screen is offered on its own only while the feature is available, nothing was answered yet and no call
///     is on screen (the call rules themselves are in `MeshConsentPresentationTests`);
///   - the answer is stored, survives a new store over the same defaults, and anything unknown counts as "never answered";
///   - a runtime without the consent refuses to start the radio, through `setAntenna` and through the app-start path.
///
/// The positive path (accept, then CoreBluetooth comes up) needs a radio and is not run here.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
@MainActor
final class MeshConsentTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        super.tearDown()
    }

    /// A throwaway defaults suite, so no test touches the user's real answer.
    private func makeDefaults() throws -> UserDefaults {
        let name = "MeshConsentTests." + UUID().uuidString
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    // MARK: - The start gate

    func test_theRadioMayStartOnlyWithTheFeatureAndAnAcceptedConsent() {
        XCTAssertTrue(MeshStartGate.mayStart(featureEnabled: true, consent: .accepted))
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: true, consent: .undecided), "never answered: stays off")
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: true, consent: .declined), "\"Non ora\": stays off")
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: false, consent: .accepted), "the kill switch wins over the consent")
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: false, consent: .undecided))
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: false, consent: .declined))
    }

    func test_theConsentScreenIsOfferedOnlyOnceAndNeverOverACall() {
        func offered(_ feature: Bool, _ consent: MeshConsentState, callBusy: Bool) -> Bool {
            MeshConsentPresentation.sheetShown(
                wanted: MeshStartGate.consentIsWanted(featureEnabled: feature, consent: consent), callBusy: callBusy)
        }
        XCTAssertTrue(offered(true, .undecided, callBusy: false))
        XCTAssertFalse(offered(true, .undecided, callBusy: true), "a ringing or running call is never covered by a sheet")
        XCTAssertFalse(offered(true, .accepted, callBusy: false))
        XCTAssertFalse(offered(true, .declined, callBusy: false),
                       "after \"Non ora\" it is not offered again by itself; Settings reopens it")
        XCTAssertFalse(offered(false, .undecided, callBusy: false), "a feature switched off is not worth asking about")
    }

    // MARK: - The stored answer

    func test_aFreshStoreHasNeverBeenAnswered() throws {
        let store = MeshConsentStore(defaults: try makeDefaults())
        XCTAssertEqual(store.state, .undecided)
    }

    func test_theAnswerIsStoredAndSurvivesANewStoreOverTheSameDefaults() throws {
        let defaults = try makeDefaults()
        MeshConsentStore(defaults: defaults).record(.accepted)
        XCTAssertEqual(MeshConsentStore(defaults: defaults).state, .accepted)
        MeshConsentStore(defaults: defaults).record(.declined)
        XCTAssertEqual(MeshConsentStore(defaults: defaults).state, .declined)
    }

    func test_aStoredValueThatIsNotAKnownAnswerCountsAsNeverAnswered() throws {
        let defaults = try makeDefaults()
        defaults.set("yes please", forKey: MeshConsentStore.key)
        XCTAssertEqual(MeshConsentStore(defaults: defaults).state, .undecided)
        defaults.set(true, forKey: MeshConsentStore.key)
        XCTAssertEqual(MeshConsentStore(defaults: defaults).state, .undecided)
    }

    func test_theObservableConsentFollowsTheAnswerAndKeepsIt() throws {
        let defaults = try makeDefaults()
        let consent = MeshConsent(store: MeshConsentStore(defaults: defaults))
        XCTAssertEqual(consent.state, .undecided)
        XCTAssertFalse(consent.isAccepted)

        consent.accept()
        XCTAssertEqual(consent.state, .accepted)
        XCTAssertTrue(consent.isAccepted)
        XCTAssertEqual(MeshConsent(store: MeshConsentStore(defaults: defaults)).state, .accepted, "stored for the next launch")

        consent.decline()
        XCTAssertEqual(consent.state, .declined)
        XCTAssertFalse(consent.isAccepted)
        XCTAssertEqual(MeshConsent(store: MeshConsentStore(defaults: defaults)).state, .declined)
    }

    // MARK: - The runtime refuses to start without the consent

    func test_aRuntimeThatWasNeverAskedDoesNotStartTheRadio() throws {
        let consent = MeshConsent(store: MeshConsentStore(defaults: try makeDefaults()))
        let runtime = MeshRuntime(forTesting: consent)
        XCTAssertFalse(runtime.startAllowed)

        runtime.setAntenna(mode: .fullMesh)
        XCTAssertFalse(runtime.antennaOn, "setAntenna must not bypass the consent")
        XCTAssertNil(runtime.antennaMode)

        runtime.setAntenna(mode: .visibleOnly)
        XCTAssertFalse(runtime.antennaOn)

        runtime.autoStartIfEnabled()
        XCTAssertFalse(runtime.antennaOn, "the app-start path must not bypass the consent either")
    }

    func test_aRuntimeWhoseUserSaidNotNowDoesNotStartTheRadio() throws {
        let consent = MeshConsent(store: MeshConsentStore(defaults: try makeDefaults()))
        let runtime = MeshRuntime(forTesting: consent)
        consent.decline()

        XCTAssertEqual(consent.state, .declined)
        XCTAssertFalse(runtime.startAllowed)
        runtime.setAntenna(mode: .fullMesh)
        runtime.autoStartIfEnabled()
        XCTAssertFalse(runtime.antennaOn)
    }

    func test_withTheConsentTheRuntimeGateFollowsTheFeatureSwitch() throws {
        let consent = MeshConsent(store: MeshConsentStore(defaults: try makeDefaults()))
        consent.accept()
        let runtime = MeshRuntime(forTesting: consent)
        // Accepted: the only thing left that can keep the radio off is the feature (the remote kill switch).
        XCTAssertEqual(runtime.startAllowed, MeshFeature.enabled)
    }
}

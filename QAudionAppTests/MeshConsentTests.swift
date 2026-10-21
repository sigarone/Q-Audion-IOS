import XCTest
@testable import QAudionApp
import QAudionEngine

/// The Bluetooth mesh may relay the encrypted messages of other app users through this phone, so nothing starts before the
/// user's one-time explicit answer on the consent screen, and relaying needs a yes ("Attiva"). "Solo i miei messaggi" lets
/// the phone find nearby contacts and exchange the user's own messages (direct mode) but never relays. These tests pin the
/// start gate:
///   - the radio may start only when the feature is available AND the consent screen was answered ("undecided" keeps it
///     off); full mesh additionally needs the consent to relay ("declined" allows the direct and visible-only modes only);
///   - the consent screen is offered on its own only while the feature is available, nothing was answered yet and no call
///     is on screen (the call rules themselves are in `MeshConsentPresentationTests`);
///   - the answer is stored, survives a new store over the same defaults, and anything unknown counts as "never answered";
///   - a runtime without the consent refuses to start the radio, through `setAntenna` and through the app-start path, and so
///     does a runtime without an identity (there is no random stand-in node id).
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

    func test_theRadioMayStartOnlyWithTheFeatureAndAnAnsweredConsent() {
        XCTAssertTrue(MeshStartGate.mayStart(featureEnabled: true, consent: .accepted))
        XCTAssertTrue(MeshStartGate.mayStart(featureEnabled: true, consent: .declined), "\"Solo i miei messaggi\": direct mode")
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: true, consent: .undecided), "never answered: stays off")
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: false, consent: .accepted), "the kill switch wins over the consent")
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: false, consent: .undecided))
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: false, consent: .declined))
    }

    func test_fullMeshNeedsTheConsentToRelay() {
        XCTAssertTrue(MeshStartGate.mayStart(featureEnabled: true, consent: .accepted, mode: .fullMesh))
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: true, consent: .declined, mode: .fullMesh))
        XCTAssertTrue(MeshStartGate.mayStart(featureEnabled: true, consent: .declined, mode: .direct))
        XCTAssertTrue(MeshStartGate.mayStart(featureEnabled: true, consent: .declined, mode: .visibleOnly))
        XCTAssertFalse(MeshStartGate.mayStart(featureEnabled: true, consent: .undecided, mode: .direct))
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
                       "after \"Solo i miei messaggi\" it is not offered again by itself; Settings reopens it")
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

    func test_aRuntimeWithoutAnIdentityNeverStartsTheRadioWhateverTheConsent() throws {
        let consent = MeshConsent(store: MeshConsentStore(defaults: try makeDefaults()))
        consent.accept()
        let runtime = MeshRuntime(forTesting: consent)
        XCTAssertNil(runtime.localNodeIdHex, "there is no random stand-in id")
        XCTAssertFalse(runtime.hasIdentity)

        runtime.setAntenna(mode: .fullMesh)
        runtime.setAntenna(mode: .direct)
        runtime.autoStartIfEnabled()
        XCTAssertFalse(runtime.antennaOn)
        XCTAssertNil(runtime.requestedMode, "no transport can be built before the identity key is known")

        // An unusable key (nil, wrong length) leaves it that way.
        runtime.configureLocalIdentity(identityKeyRaw: nil)
        runtime.configureLocalIdentity(identityKeyRaw: Data(count: 31))
        XCTAssertNil(runtime.localNodeIdHex)
        runtime.setAntenna(mode: .direct)
        XCTAssertNil(runtime.requestedMode)
    }

    func test_theNodeIdIsDerivedFromTheIdentityKeyAndFollowsAChange() throws {
        let consent = MeshConsent(store: MeshConsentStore(defaults: try makeDefaults()))
        let runtime = MeshRuntime(forTesting: consent)
        let keyA = Data(repeating: 0x11, count: 32)
        runtime.configureLocalIdentity(identityKeyRaw: keyA)
        XCTAssertEqual(runtime.localNodeIdHex, MeshNodeId.from(identityKeyRaw: keyA)?.hex)
        XCTAssertTrue(runtime.hasIdentity)

        let keyB = Data(repeating: 0x22, count: 32)
        runtime.configureLocalIdentity(identityKeyRaw: keyB)
        XCTAssertEqual(runtime.localNodeIdHex, MeshNodeId.from(identityKeyRaw: keyB)?.hex, "one source of the id, updated in place")

        runtime.accountLeft()
        XCTAssertNil(runtime.localNodeIdHex, "an account that left takes its node id with it")
    }

    func test_aUserWhoDeclinedRelayingStillGetsTheDirectModeAndNeverFullMesh() throws {
        let consent = MeshConsent(store: MeshConsentStore(defaults: try makeDefaults()))
        let runtime = MeshRuntime(forTesting: consent)
        consent.decline()
        XCTAssertEqual(consent.state, .declined)
        XCTAssertTrue(runtime.startAllowed, "declined relaying is an answer: the non-relaying modes may start")
        XCTAssertEqual(MeshModePolicy.defaultMode(consent: consent.state), .direct)
        XCTAssertEqual(MeshModePolicy.allowedMode(.fullMesh, consent: consent.state), .direct)
        // Without an identity nothing starts (the radio itself needs a device; the mode rules are in the engine tests).
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

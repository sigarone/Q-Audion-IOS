import XCTest
@testable import QAudionEngine

/// What Settings > Trasporto stores and what a call reads back: the persisted payload of `TransportSettingsViewModel`
/// (written by "Salva" into `SettingsStore`) and the two values the calls actually read (`TransportPreferences`, the
/// storage behind the app's `TransportGate`).
///
/// This file used to hold four cases that compared the mock with itself or checked constants; none of them could fail
/// when the stored mode stopped reaching the calls. The cases below do: they write through the real storage and read the
/// plan a call would build. The user name and the password of a custom server go to the Keychain, here an in-memory
/// stand-in (`TransportPreferencesCredentialsTests` covers where each piece is kept).
final class TransportSettingsViewModelTests: XCTestCase {

    private typealias Mode = TransportSettingsViewModel.Mode

    /// A TURN server with its own user name and password, in the one-text form the calls get.
    private let customServer = "turn:custom-user:custom-secret@custom.example.test:3478"

    /// The Keychain stand-in: a test bundle has no Keychain access group. A fresh one for each test method.
    private let credentials = InMemoryTransportTurnCredentialStore()

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.transportsettings.\(name).\(UUID().uuidString)"
        // The suite name is a fresh, well-formed, non-empty string: UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - The persisted payload

    func test_everyModeSurvivesTheStoredPayloadWithItsAddressAndTimings() throws {
        let address = URL(string: "turn:relay.example.test:3478")
        for mode in Mode.allCases {
            let model = TransportSettingsViewModel(mode: mode, preferredTurnServerUrl: address,
                                                   lastConnectionMs: 120, lastTurnRoundTripMs: 45)
            let data = try JSONEncoder().encode(model)
            let back = try JSONDecoder().decode(TransportSettingsViewModel.self, from: data)
            XCTAssertEqual(back, model, "\(mode)")
            XCTAssertEqual(back.mode, mode)
        }
    }

    func test_aPayloadWithAnUnknownModeFallsBackToAutoInTheStore() throws {
        let defaults = freshDefaults()
        // A payload as an unknown future build could have written it.
        let json = #"{"mode":"mesh","preferredTurnServerUrl":null,"lastConnectionMs":1,"lastTurnRoundTripMs":2}"#
        defaults.set(Data(json.utf8), forKey: "qaudion.settings.transport")
        let loaded = SettingsStore(defaults: defaults).loadTransport()
        XCTAssertEqual(loaded.mode, .auto, "an unreadable payload must not turn into another routing mode")
        XCTAssertEqual(loaded.lastTurnRoundTripMs, 0)
    }

    // MARK: - What the calls read

    func test_aFreshInstallRoutesAutoWithNoAddress() {
        let prefs = TransportPreferences(defaults: freshDefaults(), credentials: credentials)
        XCTAssertEqual(prefs.mode, .auto)
        XCTAssertNil(prefs.customTurnUrl)
        let plan = prefs.plan()
        XCTAssertEqual(plan.mode, .auto)
        XCTAssertEqual(plan.icePolicy, .all)
        XCTAssertEqual(plan.route, .serverPool)
    }

    func test_theSavedModeIsTheModeTheNextCallPlans() {
        let defaults = freshDefaults()
        let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
        let expectedPolicy: [Mode: TransportPlan.IcePolicy] = [.auto: .all, .p2p: .all, .turn: .relay, .relay: .relay]
        for mode in Mode.allCases {
            prefs.save(mode: mode, customTurnUrl: nil)
            XCTAssertEqual(TransportPreferences(defaults: defaults, credentials: credentials).mode, mode)
            XCTAssertEqual(TransportPreferences(defaults: defaults, credentials: credentials).plan().icePolicy, expectedPolicy[mode], "\(mode)")
        }
    }

    func test_theSavedAddressReachesThePlanOfEveryModeButP2P() {
        let defaults = freshDefaults()
        let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
        let address = URL(string: customServer)
        for mode in Mode.allCases {
            prefs.save(mode: mode, customTurnUrl: address)
            let plan = TransportPreferences(defaults: defaults, credentials: credentials).plan()
            if mode == .p2p {
                XCTAssertNil(plan.customTurn)
                XCTAssertTrue(plan.customTurnIgnored)
            } else {
                XCTAssertEqual(plan.customTurn?.iceUrl, "turn:custom.example.test:3478", "\(mode)")
                XCTAssertEqual(plan.customTurn?.username, "custom-user", "\(mode)")
                XCTAssertEqual(plan.customTurn?.credential, "custom-secret", "\(mode)")
            }
        }
    }

    func test_savingNoAddressClearsTheOneBefore() {
        let defaults = freshDefaults()
        let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
        prefs.save(mode: .turn, customTurnUrl: URL(string: customServer))
        XCTAssertNotNil(prefs.customTurnUrl)
        prefs.save(mode: .turn, customTurnUrl: nil)
        XCTAssertNil(prefs.customTurnUrl)
    }

    func test_valuesWrittenByEarlierBuildsUnderTheOldKeysAreStillRead() {
        // The keys are what "Salva" has written since the calls started reading it: a rename would reset every user to auto.
        let defaults = freshDefaults()
        defaults.set("relay", forKey: "qaudion.transport.preferred_mode")
        defaults.set(customServer, forKey: "qaudion.transport.preferred_turn_url")
        let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
        XCTAssertEqual(prefs.mode, .relay)
        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, customServer)
    }

    /// An address stored by a build that did not ask for credentials: libwebrtc rejects the whole configuration for such a
    /// TURN server, so the calls must not use it, and the pool is used as if there were no address.
    func test_anAddressStoredWithoutCredentialsDoesNotReplaceThePoolInAnyMode() {
        let defaults = freshDefaults()
        defaults.set("turn:custom.example.test:3478", forKey: "qaudion.transport.preferred_turn_url")
        let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
        XCTAssertNil(prefs.customTurnUrl)
        for mode in Mode.allCases {
            prefs.save(mode: mode, customTurnUrl: nil)
            defaults.set("turn:custom.example.test:3478", forKey: "qaudion.transport.preferred_turn_url")
            let plan = TransportPreferences(defaults: defaults, credentials: credentials).plan()
            XCTAssertNil(plan.customTurn, "\(mode)")
            XCTAssertFalse(plan.customTurnIgnored, "\(mode)")
            XCTAssertNotEqual(plan.route, .customServer, "\(mode)")
        }
    }

    func test_whatCannotBeReadIsAutoAndNoAddress() {
        let defaults = freshDefaults()
        defaults.set("mesh", forKey: "qaudion.transport.preferred_mode")
        defaults.set("not an address", forKey: "qaudion.transport.preferred_turn_url")
        let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
        XCTAssertEqual(prefs.mode, .auto)
        XCTAssertNil(prefs.customTurnUrl, "an address saved before addresses were checked must not replace the relay pool")
        XCTAssertEqual(prefs.plan().route, .serverPool)
    }
}

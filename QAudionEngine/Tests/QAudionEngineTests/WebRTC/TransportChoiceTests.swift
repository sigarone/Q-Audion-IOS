import XCTest
@testable import QAudionEngine

/// When the two notes of Settings > Trasporto appear: "Salvato. Vale dalla prossima chiamata 1 a 1." and "Il controllo è
/// stato fatto con una modalità o un indirizzo non ancora salvati", and what "Salva" refuses to save.
///
/// The conditions used to sit in the SwiftUI container, which needs `AppState` and cannot be built in a test. They are
/// `TransportChoice` and `TransportSaveState` now, plain values, and the cases below drive them the way the screen does:
/// a draft typed by the user in the three fields (address, user name, password), a save that is read back from the real
/// storage (`TransportPreferences` on a throw-away `UserDefaults`, with the credentials in an in-memory store: a test
/// bundle has no Keychain access group), a check that records what it ran with.
final class TransportChoiceTests: XCTestCase {

    private typealias Mode = TransportSettingsViewModel.Mode

    /// The address field: a TURN server with nothing before the host.
    private let address = "turn:relay.example.test:3478"
    /// The user name and the password fields.
    private let user = "relay-user"
    private let secret = "relay-secret"
    /// The same server as the one text the calls get, credentials in it.
    private let fullServer = "turn:relay-user:relay-secret@relay.example.test:3478"

    /// The Keychain stand-in of every case: a fresh one for each test method.
    private let credentials = InMemoryTransportTurnCredentialStore()

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.transportchoice.\(name).\(UUID().uuidString)"
        // The suite name is a fresh, well-formed, non-empty string: UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func freshPreferences(_ name: String = #function) -> TransportPreferences {
        TransportPreferences(defaults: freshDefaults(name), credentials: credentials)
    }

    /// What is typed on the screen. The user name and the password default to the ones of `fullServer`.
    private func draft(_ mode: Mode, _ address: String, user: String = "relay-user",
                       password: String = "relay-secret") -> TransportChoice {
        TransportChoice(mode: mode, address: address, username: user, password: password)
    }

    // MARK: - The typed fields

    func test_theTypedFieldsAreEmptyValidMissingCredentialsOrInvalid() {
        XCTAssertEqual(draft(.auto, "").addressState, .empty)
        XCTAssertEqual(draft(.auto, "   \n").addressState, .empty, "spaces alone are an empty field")
        XCTAssertEqual(draft(.auto, "", user: "", password: "").addressState, .empty)
        XCTAssertEqual(draft(.auto, address).addressState, .valid)
        XCTAssertEqual(draft(.auto, "  turns:relay.example.test:443?transport=tcp ").addressState, .valid)

        for (noUser, noPassword) in [("", secret), (user, ""), ("", "")] {
            let choice = draft(.auto, address, user: noUser, password: noPassword)
            XCTAssertEqual(choice.addressState, .needsCredentials, "user \"\(noUser)\" password \"\(noPassword)\"")
            XCTAssertNil(choice.customTurnUrl, "it must not reach the calls")
        }
        for unusable in ["http://relay.example.test", "turn:", "turn://relay.example.test:3478",
                         "turn:relay.example.test:99999", "relay.example.test"] {
            let choice = draft(.auto, unusable)
            XCTAssertEqual(choice.addressState, .invalid, unusable)
            XCTAssertNil(choice.customTurnUrl, unusable)
        }
    }

    /// The password has a field of its own, which is masked. An address with credentials written inside it would show them,
    /// so it is refused, whatever the other two fields hold.
    func test_anAddressWithCredentialsInsideItIsRefused() {
        for inside in ["turn:relay-user:relay-secret@relay.example.test:3478", "turn:relay-user@relay.example.test:3478",
                       "turn:@relay.example.test:3478"] {
            for (u, p) in [(user, secret), ("", ""), (user, "")] {
                let choice = draft(.auto, inside, user: u, password: p)
                XCTAssertEqual(choice.addressState, .invalid, "\(inside) with user \"\(u)\"")
                XCTAssertNil(choice.customTurnUrl, inside)
            }
        }
    }

    func test_aCredentialThatCannotBeWrittenMakesTheServerInvalid() {
        XCTAssertEqual(draft(.auto, address, user: user, password: "two\nlines").addressState, .invalid)
        XCTAssertEqual(draft(.auto, address, user: "tab\there", password: secret).addressState, .invalid)
    }

    func test_onlyAnUnusableAddressBlocksSaving() {
        XCTAssertFalse(TransportChoice.AddressState.empty.blocksSaving)
        XCTAssertFalse(TransportChoice.AddressState.valid.blocksSaving)
        XCTAssertTrue(TransportChoice.AddressState.needsCredentials.blocksSaving)
        XCTAssertTrue(TransportChoice.AddressState.invalid.blocksSaving)
    }

    func test_theServerIsKeptInTheOneTextFormTheCallsGet() {
        XCTAssertEqual(draft(.turn, "").addressWithCredentials, "")
        XCTAssertEqual(draft(.turn, "not an address").addressWithCredentials, "", "an unusable text is no address")
        XCTAssertEqual(draft(.turn, address, user: "", password: "").addressWithCredentials, "",
                       "an address without credentials is no server")
        XCTAssertEqual(draft(.turn, address).addressWithCredentials, fullServer)
        XCTAssertEqual(draft(.turn, "  \(address)  ").addressWithCredentials, fullServer,
                       "surrounding spaces are not part of it")
        XCTAssertEqual(draft(.turn, "TURN:relay.example.test:3478").addressWithCredentials, fullServer,
                       "the scheme is lower case")
    }

    /// What the fields show for a choice is what was typed in them, whatever the characters of the credentials.
    func test_theFieldsOfAChoiceGiveBackWhatWasTyped() {
        let plain = draft(.relay, address)
        XCTAssertEqual(plain.addressField, address)
        XCTAssertEqual(plain.usernameField, user)
        XCTAssertEqual(plain.passwordField, secret)

        // A user name and a password with the characters that split an address: typed as they are, no URL encoding.
        let awkward = draft(.relay, "turns:relay.example.test:5349?transport=tcp", user: "a@b:c", password: "p:w/d?%é +=")
        XCTAssertEqual(awkward.addressState, .valid)
        XCTAssertEqual(awkward.addressField, "turns:relay.example.test:5349?transport=tcp")
        XCTAssertEqual(awkward.usernameField, "a@b:c")
        XCTAssertEqual(awkward.passwordField, "p:w/d?%é +=")

        let none = draft(.relay, "")
        XCTAssertEqual(none.addressField, "")
        XCTAssertEqual(none.usernameField, "")
        XCTAssertEqual(none.passwordField, "")
        let incomplete = draft(.relay, address, user: "", password: "")
        XCTAssertEqual(incomplete.passwordField, "", "a server that is not usable shows no fields")
    }

    // MARK: - What the calls use

    func test_whatTheCallsUseIsReadFromTheStorage() {
        let prefs = freshPreferences()
        XCTAssertEqual(TransportChoice(preferences: prefs), draft(.auto, ""), "a fresh install: auto, no address")
        prefs.save(mode: .relay, customTurnUrl: URL(string: fullServer))
        let choice = TransportChoice(preferences: prefs)
        XCTAssertEqual(choice.mode, .relay)
        XCTAssertEqual(choice.addressWithCredentials, fullServer)
        XCTAssertEqual(choice.addressState, .valid)
        XCTAssertEqual(choice.addressField, address)
        XCTAssertEqual(choice.usernameField, user)
        XCTAssertEqual(choice.passwordField, secret)
    }

    func test_whatCannotBeReadFromTheStorageIsAutoAndNoAddress() {
        let defaults = freshDefaults()
        defaults.set("mesh", forKey: TransportPreferences.keyPreferredMode)
        defaults.set("not an address", forKey: TransportPreferences.keyPreferredTurnUrl)
        let choice = TransportChoice(preferences: TransportPreferences(defaults: defaults, credentials: credentials))
        XCTAssertEqual(choice.mode, .auto)
        XCTAssertEqual(choice.addressState, .empty)
        XCTAssertEqual(choice.addressWithCredentials, "")
    }

    /// An address stored without credentials (none in the Keychain for its host) is no server for the calls, and
    /// libwebrtc rejects the whole configuration for such a TURN server. The screen still gets the address back, so it can
    /// ask for the credentials instead of dropping the address without a word.
    func test_anAddressStoredWithoutCredentialsIsNoAddressForTheCallsButTheTextIsStillThere() {
        let defaults = freshDefaults()
        defaults.set(address, forKey: TransportPreferences.keyPreferredTurnUrl)
        defaults.set("relay", forKey: TransportPreferences.keyPreferredMode)
        let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
        XCTAssertNil(prefs.customTurnUrl)
        XCTAssertEqual(TransportChoice(preferences: prefs).addressState, .empty)
        XCTAssertEqual(prefs.plan(bridgeAvailable: true).route, .wssBridge, "the call does not use it")
        XCTAssertEqual(prefs.storedAddressText, address)
        XCTAssertNil(prefs.storedCredentials)
        let shown = draft(prefs.mode, prefs.storedAddressText, user: prefs.storedCredentials?.username ?? "",
                          password: prefs.storedCredentials?.password ?? "")
        XCTAssertEqual(shown.addressState, .needsCredentials, "the screen shows it and asks for the credentials")
        XCTAssertEqual(TransportPreferences(defaults: freshDefaults(), credentials: credentials).storedAddressText, "",
                       "nothing stored, no text")
    }

    // MARK: - Is the screen what is saved

    func test_theScreenIsSavedOnlyWhenModeAndServerAreTheStoredOnes() {
        let stored = draft(.relay, address)
        XCTAssertTrue(draft(.relay, address).isSaved(as: stored))
        XCTAssertFalse(draft(.turn, address).isSaved(as: stored), "another mode")
        XCTAssertFalse(draft(.relay, "").isSaved(as: stored), "the address was cleared")
        XCTAssertFalse(draft(.relay, "turn:other.example.test:3478").isSaved(as: stored), "another host")
        XCTAssertFalse(draft(.relay, address, password: "other-secret").isSaved(as: stored), "another password")
        XCTAssertFalse(draft(.relay, address, user: "other-user").isSaved(as: stored), "another user name")
        XCTAssertFalse(draft(.relay, address).isSaved(as: draft(.relay, "")), "an address that is not stored yet")
    }

    func test_spacesAndTheCaseOfTheSchemeDoNotMakeTheAddressUnsaved() {
        let stored = draft(.turn, address)
        XCTAssertTrue(draft(.turn, "  \(address) ").isSaved(as: stored))
        XCTAssertTrue(draft(.turn, "TURN:relay.example.test:3478").isSaved(as: stored))
    }

    func test_anAddressThatCannotBeSavedIsNeverReportedAsSaved() {
        let stored = draft(.auto, "")
        let unsavable = [
            draft(.auto, "http://relay.example.test"),
            draft(.auto, address, user: "", password: ""),
            draft(.auto, "turn:relay-user:relay-secret@relay.example.test:3478")
        ]
        for typed in unsavable {
            XCTAssertTrue(typed.hasSameValues(as: stored), "\(typed.addressState): an unusable text counts as no address ...")
            XCTAssertFalse(typed.isSaved(as: stored), "\(typed.addressState): ... but the screen is not what is stored: the text will not be saved")
        }
    }

    // MARK: - "Salva" refuses what cannot be saved

    /// What the screen's "Salva" does, driven through the real storage on a throw-away `UserDefaults`.
    private func press(_ draft: TransportChoice, on state: inout TransportSaveState, prefs: TransportPreferences,
                       log: inout [String]) -> Bool {
        var events: [String] = []
        let saved = state.save(
            draft: draft,
            write: { choice in
                events.append("write")
                prefs.save(mode: choice.mode, customTurnUrl: choice.customTurnUrl)
            },
            readBack: {
                events.append("read")
                return TransportChoice(preferences: prefs)
            })
        log = events
        return saved
    }

    func test_saveIsRefusedForAnAddressThatIsNotATurnAddressOrHasNoCredentials() {
        let refused: [(String, String, String, TransportChoice.AddressState)] = [
            ("http://relay.example.test", user, secret, .invalid),
            ("turn:relay.example.test:99999", user, secret, .invalid),
            ("relay.example.test", user, secret, .invalid),
            ("turn:relay-user:relay-secret@relay.example.test:3478", user, secret, .invalid),
            (address, "", "", .needsCredentials),
            ("turns:relay.example.test:5349", user, "", .needsCredentials),
            (address, "", secret, .needsCredentials)
        ]
        for (text, u, p, expectedState) in refused {
            for mode in Mode.allCases {
                let prefs = freshPreferences()
                prefs.save(mode: .p2p, customTurnUrl: nil)
                var state = TransportSaveState(saved: TransportChoice(preferences: prefs))
                let typed = draft(mode, text, user: u, password: p)
                XCTAssertEqual(typed.addressState, expectedState, "\(text)")

                var log: [String] = []
                let saved = press(typed, on: &state, prefs: prefs, log: &log)

                XCTAssertFalse(saved, "\(mode) \(text): Salva must refuse it")
                XCTAssertEqual(log, [], "\(mode) \(text): nothing is written and nothing is read back")
                XCTAssertEqual(prefs.mode, .p2p, "\(mode) \(text): the stored mode is untouched, even if the mode on the screen differs")
                XCTAssertNil(prefs.customTurnUrl, "\(mode) \(text)")
                XCTAssertEqual(prefs.storedAddressText, "", "\(mode) \(text)")
                XCTAssertEqual(credentials.hosts, [], "\(mode) \(text): no credentials were kept")
                XCTAssertFalse(state.justSaved, "\(mode) \(text)")
                XCTAssertEqual(state.saved.mode, .p2p, "\(mode) \(text)")
                XCTAssertFalse(state.showsSavedNote(draft: typed), "\(mode) \(text): no \"Salvato\" note")
            }
        }
    }

    func test_saveWritesFirstThenReadsTheStorageBackAndRecordsWhatItHolds() {
        for text in ["", address] {
            for mode in Mode.allCases {
                let defaults = freshDefaults()
                let prefs = TransportPreferences(defaults: defaults, credentials: credentials)
                var state = TransportSaveState(saved: TransportChoice(preferences: prefs))
                let typed = draft(mode, text)
                var log: [String] = []
                let saved = press(typed, on: &state, prefs: prefs, log: &log)
                XCTAssertTrue(saved, "\(mode) \(text)")
                XCTAssertEqual(log, ["write", "read"], "\(mode) \(text): the state is read back after the write")
                XCTAssertEqual(prefs.mode, mode, "\(mode) \(text)")
                XCTAssertEqual(prefs.storedAddressText, typed.addressField, "\(mode) \(text)")
                XCTAssertTrue(state.showsSavedNote(draft: typed), "\(mode) \(text)")
                // Only the address is in UserDefaults, never the user name or the password.
                let inDefaults = defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl) ?? ""
                XCTAssertEqual(inDefaults, typed.addressField, "\(mode) \(text)")
                XCTAssertFalse(inDefaults.contains(secret) || inDefaults.contains(user) || inDefaults.contains("@"),
                               "\(mode) \(text): credentials in UserDefaults: \(inDefaults)")
            }
        }
    }

    func test_aRefusedSaveKeepsTheNoteOfTheSaveBeforeAsItWas() {
        let prefs = freshPreferences()
        var state = TransportSaveState(saved: TransportChoice(preferences: prefs))
        var log: [String] = []
        let firstSave = press(draft(.turn, address), on: &state, prefs: prefs, log: &log)
        XCTAssertTrue(firstSave)
        let afterTheGoodSave = state
        let secondSave = press(draft(.turn, address, user: "", password: ""), on: &state, prefs: prefs, log: &log)
        XCTAssertFalse(secondSave)
        XCTAssertEqual(state, afterTheGoodSave, "a refused save changes nothing of what the screen knows")
        XCTAssertEqual(prefs.storedAddressText, address, "the address saved before is still the stored one")
        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, fullServer, "and so are its credentials")
    }

    /// The Keychain can refuse the user name and the password. `TransportPreferences.save` then changes nothing, and the
    /// storage read back after the write is what it was: the screen sees that it is not what was typed, and the "Salvato"
    /// note does not appear.
    func test_aSaveTheKeychainRefusesLeavesTheStorageAsItWasAndShowsNoSavedNote() {
        let prefs = freshPreferences()
        var state = TransportSaveState(saved: TransportChoice(preferences: prefs))
        var log: [String] = []
        credentials.acceptsWrites = false
        let typed = draft(.relay, address)
        let ran = press(typed, on: &state, prefs: prefs, log: &log)

        XCTAssertTrue(ran, "the engine state still writes and reads back: the read back tells what happened")
        XCTAssertEqual(log, ["write", "read"])
        XCTAssertEqual(prefs.mode, .auto, "the mode was not changed either")
        XCTAssertEqual(prefs.storedAddressText, "")
        XCTAssertNil(prefs.customTurnUrl)
        XCTAssertFalse(typed.isSaved(as: state.saved), "what is on the screen is not what is stored")
        XCTAssertFalse(state.showsSavedNote(draft: typed), "no \"Salvato\" for something that was not saved")
    }

    // MARK: - "Salvato. Vale dalla prossima chiamata 1 a 1."

    func test_theSavedNoteIsNotShownJustByOpeningTheScreen() {
        let state = TransportSaveState(saved: draft(.relay, ""))
        XCTAssertFalse(state.justSaved)
        XCTAssertFalse(state.showsSavedNote(draft: draft(.relay, "")), "the screen shows the stored values, but nothing was saved")
    }

    func test_theSavedNoteFollowsTheScreenAfterASave() {
        var state = TransportSaveState(saved: draft(.auto, ""))
        let relay = draft(.relay, "")
        state.recordSave(readBack: relay)
        XCTAssertTrue(state.showsSavedNote(draft: relay))
        XCTAssertFalse(state.showsSavedNote(draft: draft(.turn, "")), "another mode is on the screen")
        XCTAssertFalse(state.showsSavedNote(draft: draft(.relay, address)), "an address was typed")
        XCTAssertFalse(state.showsSavedNote(draft: draft(.relay, "not an address")), "an unusable address was typed")
        XCTAssertFalse(state.showsSavedNote(draft: draft(.relay, address, user: "", password: "")),
                       "an address without credentials was typed")
        XCTAssertTrue(state.showsSavedNote(draft: draft(.relay, "")), "the saved values are on the screen again, so it is true again")
    }

    func test_theSavedNoteDoesNotClaimWhatTheStorageDidNotTake() {
        var state = TransportSaveState(saved: draft(.auto, ""))
        // "Salva" was pressed on relay, but reading the storage again still gives auto.
        state.recordSave(readBack: draft(.auto, ""))
        XCTAssertFalse(state.showsSavedNote(draft: draft(.relay, "")))
    }

    func test_aSaveThatWentThroughTheStorageIsSeenAsSaved() {
        let texts = ["", address, "  TURNS:relay.example.test:443?transport=tcp  "]
        for mode in Mode.allCases {
            for text in texts {
                let prefs = freshPreferences()
                var state = TransportSaveState(saved: TransportChoice(preferences: prefs))
                let typed = draft(mode, text)
                XCTAssertFalse(typed.addressState.blocksSaving, "\(mode) \(text)")
                // What "Salva" does: write the choice, then read the storage back.
                prefs.save(mode: typed.mode, customTurnUrl: typed.customTurnUrl)
                state.recordSave(readBack: TransportChoice(preferences: prefs))
                XCTAssertTrue(state.showsSavedNote(draft: typed), "\(mode) \(text)")
                XCTAssertEqual(state.saved.mode, mode, "\(mode) \(text)")
                XCTAssertEqual(state.saved.addressWithCredentials, typed.addressWithCredentials, "\(mode) \(text)")
            }
        }
    }

    // MARK: - "Il controllo è stato fatto con una modalità o un indirizzo non ancora salvati"

    func test_theNotSavedNoteFollowsWhatTheLastCheckRanWith() {
        var state = TransportSaveState(saved: draft(.auto, ""))
        XCTAssertTrue(state.checkMatchesSaved, "no check ran: there is no result to warn about")

        state.recordCheck(draft(.auto, ""))
        XCTAssertTrue(state.checkMatchesSaved)

        state.recordCheck(draft(.p2p, ""))
        XCTAssertFalse(state.checkMatchesSaved, "p2p was checked, auto is saved")

        state.recordCheck(draft(.auto, address))
        XCTAssertFalse(state.checkMatchesSaved, "the mode is the saved one, the address is not")

        state.recordSave(readBack: draft(.auto, address))
        XCTAssertTrue(state.checkMatchesSaved, "saving what was checked makes the result a saved one")

        state.recordSave(readBack: draft(.turn, address))
        XCTAssertFalse(state.checkMatchesSaved, "saving something else afterwards makes the result stale again")
    }

    /// The note says "mode or address" because either can be the unsaved part: a check that differs only by the address
    /// warns as well, and so does one that differs only by the mode.
    func test_theNotSavedNoteAlsoFollowsAChangeOfTheAddressAloneAndOfTheModeAlone() {
        var state = TransportSaveState(saved: draft(.relay, address))
        state.recordCheck(draft(.relay, address))
        XCTAssertTrue(state.checkMatchesSaved)
        state.recordCheck(draft(.relay, address, password: "other-secret"))
        XCTAssertFalse(state.checkMatchesSaved, "only the password differs")
        state.recordCheck(draft(.relay, ""))
        XCTAssertFalse(state.checkMatchesSaved, "only the address differs (cleared)")
        state.recordCheck(draft(.turn, address))
        XCTAssertFalse(state.checkMatchesSaved, "only the mode differs")
    }

    func test_aCheckOfAnUnsavedDraftWarnsAndOneOfTheSavedValuesDoesNot() {
        let prefs = freshPreferences()
        prefs.save(mode: .relay, customTurnUrl: nil)
        var state = TransportSaveState(saved: TransportChoice(preferences: prefs))
        state.recordCheck(draft(.relay, ""))
        XCTAssertTrue(state.checkMatchesSaved)
        state.recordCheck(draft(.relay, "  \(address)"))
        XCTAssertFalse(state.checkMatchesSaved)
    }
}

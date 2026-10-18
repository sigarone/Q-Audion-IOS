import XCTest
@testable import QAudionEngine

/// Where Settings > Trasporto keeps the custom TURN server: the address in `UserDefaults`, the user name and the password
/// in the Keychain under the host of the address, and never the password in `UserDefaults`.
///
/// A unit test bundle has no Keychain access group, so the cases drive `TransportPreferences` with
/// `InMemoryTransportTurnCredentialStore` in place of the Keychain. The real Keychain store has its own case at the end,
/// skipped (with its reason) where the Keychain cannot be used.
final class TransportPreferencesCredentialsTests: XCTestCase {

    private let credentials = InMemoryTransportTurnCredentialStore()

    private let server = "turn:alice:s3cret@Relay.Example.Test:3478?transport=udp"
    /// The address as `UserDefaults` keeps it: the host as typed, nothing before it.
    private let storedAddress = "turn:Relay.Example.Test:3478?transport=udp"
    /// The Keychain account: the host, lower case.
    private let host = "relay.example.test"

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.transportprefs.\(name).\(UUID().uuidString)"
        // The suite name is a fresh, well-formed, non-empty string: UserDefaults(suiteName:) never returns nil for it.
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func preferences(_ defaults: UserDefaults) -> TransportPreferences {
        TransportPreferences(defaults: defaults, credentials: credentials)
    }

    // MARK: - Save splits the server

    func test_saveKeepsTheAddressInUserDefaultsAndTheCredentialsInTheKeychainStore() {
        let defaults = freshDefaults()
        let prefs = preferences(defaults)
        XCTAssertTrue(prefs.save(mode: .turn, customTurnUrl: URL(string: server)))

        XCTAssertEqual(defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl), storedAddress)
        XCTAssertEqual(defaults.string(forKey: TransportPreferences.keyPreferredMode), "turn")
        XCTAssertEqual(credentials.credentials(forHost: host),
                       TransportTurnCredentials(username: "alice", password: "s3cret"))
        XCTAssertEqual(credentials.hosts, [host], "one entry, under the lower case host")
    }

    func test_thePasswordIsNotAnywhereInUserDefaultsAfterASave() {
        let defaults = freshDefaults()
        let prefs = preferences(defaults)
        prefs.save(mode: .relay, customTurnUrl: URL(string: server))

        let everything = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        XCTAssertFalse(everything.contains("s3cret"), "the password is in UserDefaults")
        XCTAssertFalse(everything.contains("alice"), "the user name is in UserDefaults")
    }

    func test_theCallsGetTheServerPutTogetherFromBothPlaces() {
        let prefs = preferences(freshDefaults())
        prefs.save(mode: .relay, customTurnUrl: URL(string: server))

        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, "turn:alice:s3cret@Relay.Example.Test:3478?transport=udp")
        let plan = prefs.plan()
        XCTAssertEqual(plan.customTurn?.iceUrl, "turn:Relay.Example.Test:3478?transport=udp")
        XCTAssertEqual(plan.customTurn?.username, "alice")
        XCTAssertEqual(plan.customTurn?.credential, "s3cret")
        XCTAssertEqual(prefs.storedAddressText, storedAddress)
        XCTAssertEqual(prefs.storedCredentials, TransportTurnCredentials(username: "alice", password: "s3cret"))
    }

    func test_aPasswordWithSpecialCharactersSurvivesTheSplitAndThePuttingTogether() {
        let prefs = preferences(freshDefaults())
        let typed = TransportCustomTurn.make(address: "turn:relay.example.test:3478", username: "a@b:c",
                                             password: "p:w/d?%é +=")
        prefs.save(mode: .turn, customTurnUrl: typed?.storedURL)

        XCTAssertEqual(credentials.credentials(forHost: "relay.example.test"),
                       TransportTurnCredentials(username: "a@b:c", password: "p:w/d?%é +="))
        let back = prefs.plan().customTurn
        XCTAssertEqual(back?.username, "a@b:c")
        XCTAssertEqual(back?.credential, "p:w/d?%é +=")
    }

    func test_newCredentialsForTheSameHostReplaceTheOldOnes() {
        let prefs = preferences(freshDefaults())
        prefs.save(mode: .turn, customTurnUrl: URL(string: "turn:alice:old@relay.example.test:3478"))
        prefs.save(mode: .turn, customTurnUrl: URL(string: "turn:alice:new@relay.example.test:3478"))
        XCTAssertEqual(credentials.credentials(forHost: "relay.example.test")?.password, "new")
        XCTAssertEqual(credentials.hosts, ["relay.example.test"])
    }

    func test_theCredentialsOfAServerThatIsNoLongerSavedAreForgotten() {
        let defaults = freshDefaults()
        let prefs = preferences(defaults)
        prefs.save(mode: .turn, customTurnUrl: URL(string: "turn:alice:s3cret@first.example.test:3478"))
        XCTAssertEqual(credentials.hosts, ["first.example.test"])

        // Another host: the first one's credentials are not kept.
        prefs.save(mode: .turn, customTurnUrl: URL(string: "turn:bob:other@second.example.test:3478"))
        XCTAssertEqual(credentials.hosts, ["second.example.test"])
        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, "turn:bob:other@second.example.test:3478")

        // No server at all: nothing is kept, and the address is gone from UserDefaults.
        prefs.save(mode: .turn, customTurnUrl: nil)
        XCTAssertEqual(credentials.hosts, [])
        XCTAssertNil(defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl))
        XCTAssertNil(prefs.customTurnUrl)
    }

    func test_somethingThatIsNotAUsableServerClearsTheSavedOne() {
        let prefs = preferences(freshDefaults())
        prefs.save(mode: .turn, customTurnUrl: URL(string: server))
        XCTAssertNotNil(prefs.customTurnUrl)
        // An address without credentials is no server: it is not stored as one.
        prefs.save(mode: .turn, customTurnUrl: URL(string: "turn:relay.example.test:3478"))
        XCTAssertNil(prefs.customTurnUrl)
        XCTAssertEqual(prefs.storedAddressText, "")
        XCTAssertEqual(credentials.hosts, [])
    }

    // MARK: - The Keychain refuses the write

    func test_whenTheKeychainRefusesTheCredentialsNothingIsChanged() {
        let defaults = freshDefaults()
        let prefs = preferences(defaults)
        XCTAssertTrue(prefs.save(mode: .turn, customTurnUrl: URL(string: "turn:alice:s3cret@first.example.test:3478")))

        credentials.acceptsWrites = false
        let saved = prefs.save(mode: .relay, customTurnUrl: URL(string: "turn:bob:other@second.example.test:3478"))

        XCTAssertFalse(saved)
        XCTAssertEqual(prefs.mode, .turn, "the mode stays as it was")
        XCTAssertEqual(prefs.storedAddressText, "turn:first.example.test:3478", "the address stays as it was")
        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, "turn:alice:s3cret@first.example.test:3478",
                       "the calls keep the server saved before")
        XCTAssertEqual(credentials.hosts, ["first.example.test"], "the credentials of the saved server are not dropped")
    }

    // MARK: - Reading

    func test_anAddressWhoseCredentialsAreGoneReadsAsNoServerButTheAddressIsStillShown() {
        let defaults = freshDefaults()
        let prefs = preferences(defaults)
        prefs.save(mode: .turn, customTurnUrl: URL(string: server))
        credentials.remove(forHost: host)

        XCTAssertNil(prefs.customTurnUrl, "no credentials, no custom server: the pool is used")
        XCTAssertEqual(prefs.plan().route, .poolTurn)
        XCTAssertEqual(prefs.storedAddressText, storedAddress)
        XCTAssertNil(prefs.storedCredentials)
    }

    func test_theCredentialsAreLookedUpByTheLowerCaseHost() {
        let defaults = freshDefaults()
        // The address as typed with capitals, the credentials stored under the lower case host.
        defaults.set("turn:RELAY.example.test:3478", forKey: TransportPreferences.keyPreferredTurnUrl)
        credentials.save(TransportTurnCredentials(username: "alice", password: "s3cret"), forHost: "relay.example.test")
        XCTAssertEqual(preferences(defaults).customTurnUrl?.absoluteString, "turn:alice:s3cret@RELAY.example.test:3478")
    }

    // MARK: - A value written by an earlier build

    /// Earlier builds stored `turn:user:password@host:port` in `UserDefaults`. The first read moves the credentials to the
    /// Keychain store and leaves the address alone in `UserDefaults`.
    func test_aLegacyValueWithThePasswordInsideIsMovedToTheKeychainStoreOnTheFirstRead() {
        let defaults = freshDefaults()
        defaults.set(server, forKey: TransportPreferences.keyPreferredTurnUrl)
        defaults.set("relay", forKey: TransportPreferences.keyPreferredMode)
        let prefs = preferences(defaults)

        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, server, "the calls still get the same server")

        XCTAssertEqual(defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl), storedAddress,
                       "the value with the password is gone from UserDefaults")
        XCTAssertEqual(credentials.credentials(forHost: host), TransportTurnCredentials(username: "alice", password: "s3cret"))
        XCTAssertEqual(prefs.mode, .relay)
        // And a second read finds the same thing, from the two new places.
        XCTAssertEqual(preferences(defaults).customTurnUrl?.absoluteString, server)
    }

    func test_theAddressFieldNeverShowsThePasswordOfALegacyValue() {
        let defaults = freshDefaults()
        defaults.set(server, forKey: TransportPreferences.keyPreferredTurnUrl)
        credentials.acceptsWrites = false
        let prefs = preferences(defaults)
        XCTAssertEqual(prefs.storedAddressText, storedAddress, "the text for the address field has no credentials in it")
        XCTAssertEqual(prefs.storedCredentials, TransportTurnCredentials(username: "alice", password: "s3cret"))
    }

    /// If the Keychain refuses the move, the old value stays where it is: nothing is lost, the calls keep working with it,
    /// and the move happens at a later read.
    func test_aLegacyValueIsNotLostWhenTheKeychainRefusesTheMove() {
        let defaults = freshDefaults()
        defaults.set(server, forKey: TransportPreferences.keyPreferredTurnUrl)
        credentials.acceptsWrites = false
        let prefs = preferences(defaults)

        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, server, "the calls keep the server")
        XCTAssertEqual(defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl), server, "the old value is kept")
        XCTAssertEqual(credentials.hosts, [])

        credentials.acceptsWrites = true
        XCTAssertEqual(prefs.customTurnUrl?.absoluteString, server)
        XCTAssertEqual(defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl), storedAddress, "moved at the next read")
        XCTAssertEqual(credentials.hosts, [host])
    }

    func test_savingOverALegacyValueDropsItsCredentialsToo() {
        let defaults = freshDefaults()
        defaults.set(server, forKey: TransportPreferences.keyPreferredTurnUrl)
        let prefs = preferences(defaults)
        XCTAssertTrue(prefs.save(mode: .turn, customTurnUrl: URL(string: "turn:bob:other@second.example.test:3478")))
        XCTAssertEqual(credentials.hosts, ["second.example.test"])
        XCTAssertEqual(defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl), "turn:second.example.test:3478")
    }

    // MARK: - The real Keychain store

    /// The Keychain store itself: write, read, replace and remove an item. Skipped where the Keychain cannot be used (a
    /// simulator test bundle has no keychain access group); it runs, and must pass, on a device.
    func test_theKeychainStoreKeepsReplacesAndForgetsTheCredentialsOfAHost() throws {
        try KeychainAvailability.requireKeychain()
        let store = KeychainTransportTurnCredentialStore()
        let testHost = "keychain-test-\(UUID().uuidString.lowercased()).example.test"
        defer { store.remove(forHost: testHost) }

        XCTAssertNil(store.credentials(forHost: testHost))
        XCTAssertTrue(store.save(TransportTurnCredentials(username: "alice", password: "one"), forHost: testHost))
        XCTAssertEqual(store.credentials(forHost: testHost), TransportTurnCredentials(username: "alice", password: "one"))
        XCTAssertEqual(store.credentials(forHost: testHost.uppercased()), store.credentials(forHost: testHost),
                       "the host is looked up in lower case")

        XCTAssertTrue(store.save(TransportTurnCredentials(username: "bob", password: "two"), forHost: testHost))
        XCTAssertEqual(store.credentials(forHost: testHost), TransportTurnCredentials(username: "bob", password: "two"))

        store.remove(forHost: testHost)
        XCTAssertNil(store.credentials(forHost: testHost))
    }

    func test_clearAllForgetsTheAddressTheModeTheCredentialsAndTheSettingsCopy() {
        let defaults = freshDefaults()
        let prefs = preferences(defaults)
        XCTAssertTrue(prefs.save(mode: .turn, customTurnUrl: URL(string: server)))
        defaults.set(storedAddress, forKey: TransportPreferences.keyCopyInSettingsStore)
        XCTAssertNotNil(credentials.credentials(forHost: host))

        prefs.clearAll()

        XCTAssertNil(defaults.string(forKey: TransportPreferences.keyPreferredTurnUrl))
        XCTAssertNil(defaults.string(forKey: TransportPreferences.keyPreferredMode))
        XCTAssertNil(defaults.string(forKey: TransportPreferences.keyCopyInSettingsStore))
        XCTAssertNil(credentials.credentials(forHost: host))
    }
}

import XCTest
@testable import QAudionEngine

/// The saved-login wrapper over an injected Keychain. The production Keychain (biometry) is not
/// exercised here: what is pinned is the wrapper's own behaviour.
final class SavedLoginStoreTests: XCTestCase {
    private final class FakeKeychain: SavedLoginKeychain {
        var data: Data?
        var failWrites = false
        var authFails = false
        func write(_ data: Data) -> Bool {
            if failWrites { return false }
            self.data = data
            return true
        }
        func read(reason: String) -> (data: Data?, authenticationFailed: Bool) {
            if authFails { return (nil, true) }
            return (data, false)
        }
        func exists() -> Bool { data != nil }
        func delete() { data = nil }
    }

    private var keychain: FakeKeychain!
    private var defaults: UserDefaults!
    private var store: SavedLoginStore!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "saved-login-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keychain = FakeKeychain()
        store = SavedLoginStore(keychain: keychain, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_startsUnasked() {
        XCTAssertEqual(store.decision, .unasked)
        XCTAssertTrue(store.shouldAsk)
        XCTAssertFalse(store.hasSavedLogin)
    }

    func test_saveThenLoadRoundTrips() {
        XCTAssertTrue(store.save(SavedLogin(extensionNumber: "176", password: "correct horse")))
        XCTAssertEqual(store.decision, .saved)
        XCTAssertFalse(store.shouldAsk)
        XCTAssertTrue(store.hasSavedLogin)
        XCTAssertEqual(store.load(reason: "r"), .found(SavedLogin(extensionNumber: "176", password: "correct horse")))
    }

    func test_failedWriteDoesNotRecordAYes() {
        keychain.failWrites = true
        XCTAssertFalse(store.save(SavedLogin(extensionNumber: "176", password: "pw-123456")))
        XCTAssertEqual(store.decision, .unasked)
        XCTAssertFalse(store.hasSavedLogin)
    }

    func test_declineDeletesAndStopsAsking() {
        store.save(SavedLogin(extensionNumber: "176", password: "pw-123456"))
        store.decline()
        XCTAssertEqual(store.decision, .declined)
        XCTAssertFalse(store.shouldAsk)
        XCTAssertFalse(store.hasSavedLogin)
    }

    func test_resetDecisionAsksAgain() {
        store.decline()
        store.resetDecision()
        XCTAssertTrue(store.shouldAsk)
    }

    func test_updateIfSavedReplacesOnlyAfterAYes() {
        store.updateIfSaved(SavedLogin(extensionNumber: "176", password: "first-pw-1"))
        XCTAssertFalse(store.hasSavedLogin, "no yes recorded: nothing is stored")

        store.save(SavedLogin(extensionNumber: "176", password: "first-pw-1"))
        store.updateIfSaved(SavedLogin(extensionNumber: "176", password: "second-pw-2"))
        XCTAssertEqual(store.load(reason: "r"), .found(SavedLogin(extensionNumber: "176", password: "second-pw-2")))
    }

    func test_updateIfSavedLeavesNoStalePasswordWhenTheWriteFails() {
        store.save(SavedLogin(extensionNumber: "176", password: "first-pw-1"))
        keychain.failWrites = true
        store.updateIfSaved(SavedLogin(extensionNumber: "176", password: "second-pw-2"))
        XCTAssertFalse(store.hasSavedLogin)
        XCTAssertEqual(store.decision, .unasked)
    }

    func test_deleteAllForgetsTheItemAndTheAnswer() {
        store.save(SavedLogin(extensionNumber: "176", password: "pw-123456"))
        store.deleteAll()
        XCTAssertFalse(store.hasSavedLogin)
        XCTAssertEqual(store.decision, .unasked)
    }

    func test_cancelledBiometricKeepsTheItem() {
        store.save(SavedLogin(extensionNumber: "176", password: "pw-123456"))
        keychain.authFails = true
        XCTAssertEqual(store.load(reason: "r"), .notAuthenticated)
        XCTAssertTrue(store.hasSavedLogin)
    }

    func test_garbageInTheKeychainIsDropped() {
        keychain.data = Data("not json".utf8)
        XCTAssertEqual(store.load(reason: "r"), .notFound)
        XCTAssertFalse(store.hasSavedLogin)
    }

    func test_nothingStoredReadsAsNotFound() {
        XCTAssertEqual(store.load(reason: "r"), .notFound)
    }
}

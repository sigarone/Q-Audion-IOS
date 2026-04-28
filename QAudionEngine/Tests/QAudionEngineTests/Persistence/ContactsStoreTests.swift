import XCTest
@testable import QAudionEngine

final class ContactsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: ContactsStore!

    override func setUp() {
        super.setUp()
        let suite = "test.contactsstore.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)!
        store = ContactsStore(defaults: defaults)
    }

    override func tearDown() {
        store = nil
        defaults = nil
        super.tearDown()
    }

    func test_load_emptyByDefault() {
        XCTAssertTrue(store.load().isEmpty)
    }

    func test_save_then_load() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: String(repeating: "ab", count: 32),
            avatarUrl: nil, lastSeen: nil, isVerified: true
        )
        store.save([c])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, c)
    }

    func test_upsert_addsNewContact() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.upsert(c)
        XCTAssertEqual(store.load().count, 1)
    }

    func test_upsert_updatesExisting() {
        let c1 = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        let c2 = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice (verified)",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: true
        )
        store.upsert(c1)
        store.upsert(c2)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.displayName, "Alice (verified)")
    }

    func test_remove_deletesContact() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.save([c])
        store.remove(userId: "u-1")
        XCTAssertTrue(store.load().isEmpty)
    }

    func test_wipeAll_clearsEverything() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.save([c])
        store.wipeAll()
        XCTAssertTrue(store.load().isEmpty)
    }
}

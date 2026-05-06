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

    // MARK: - W14.F pubkey persistence

    func test_pubkey_defaultsToNilWhenNotProvided() {
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        XCTAssertNil(c.pubkey, "Default-arg init should produce a nil pubkey")
    }

    func test_pubkey_roundTripsThroughCodable() {
        let pk = Data(repeating: 0xAB, count: 32)
        let c = ContactsStore.StoredContact(
            userId: "u-1", displayName: "Alice",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: true,
            pubkey: pk
        )
        store.save([c])
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.pubkey, pk)
    }

    func test_findPubkey_returnsValueForKnownUserId() {
        let pk = Data(repeating: 0x42, count: 32)
        let c = ContactsStore.StoredContact(
            userId: "u-known", displayName: "Bob",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: true,
            pubkey: pk
        )
        store.save([c])
        XCTAssertEqual(store.findPubkey(userId: "u-known"), pk)
    }

    func test_findPubkey_returnsNilForUnknownUserId() {
        XCTAssertNil(store.findPubkey(userId: "u-missing"))
    }

    func test_findPubkey_returnsNilForLegacyContactWithoutPubkey() {
        let c = ContactsStore.StoredContact(
            userId: "u-legacy", displayName: "Old Row",
            phoneHash: "abc", avatarUrl: nil, lastSeen: nil, isVerified: false
        )
        store.save([c])
        XCTAssertNil(store.findPubkey(userId: "u-legacy"),
                     "Legacy rows persisted without pubkey field must surface as nil")
    }

    /// Forward-compatibility: a row encoded by an old build (no pubkey field)
    /// should decode cleanly with pubkey=nil. Simulates that by hand-writing
    /// JSON that mirrors the pre-W14.F shape.
    func test_legacyJsonWithoutPubkey_decodesWithNilPubkey() throws {
        let legacyJson = """
        [{"userId":"u-old","displayName":"Old","phoneHash":"abc","isVerified":false}]
        """.data(using: .utf8)!
        defaults.set(legacyJson, forKey: "qaudion.contacts.list")
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.userId, "u-old")
        XCTAssertNil(loaded.first?.pubkey)
    }
}

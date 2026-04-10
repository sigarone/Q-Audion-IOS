import XCTest
@testable import QAudionEngine

final class VoiceprintStoreTests: XCTestCase {

    // MARK: - Save and Load

    func testSaveAndLoadRoundTrip() {
        let store = VoiceprintStore()
        let template: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        store.save(contactId: "alice", template: template)

        let loaded = store.load(contactId: "alice")
        XCTAssertEqual(loaded, template)
    }

    func testLoadNonexistentReturnsNil() {
        let store = VoiceprintStore()
        XCTAssertNil(store.load(contactId: "nobody"))
    }

    func testSaveOverwritesExisting() {
        let store = VoiceprintStore()
        store.save(contactId: "bob", template: [1.0, 2.0])
        store.save(contactId: "bob", template: [3.0, 4.0])

        let loaded = store.load(contactId: "bob")
        XCTAssertEqual(loaded, [3.0, 4.0])
    }

    // MARK: - Delete

    func testDeleteRemovesEntry() {
        let store = VoiceprintStore()
        store.save(contactId: "carol", template: [1.0])
        store.delete(contactId: "carol")
        XCTAssertNil(store.load(contactId: "carol"))
    }

    func testDeleteNonexistentDoesNotCrash() {
        let store = VoiceprintStore()
        store.delete(contactId: "ghost")
        // No crash expected
    }

    // MARK: - List

    func testListContactsReturnsAllKeys() {
        let store = VoiceprintStore()
        store.save(contactId: "alice", template: [1.0])
        store.save(contactId: "bob", template: [2.0])
        store.save(contactId: "carol", template: [3.0])

        let contacts = store.listContacts()
        XCTAssertEqual(Set(contacts), Set(["alice", "bob", "carol"]))
    }

    func testListContactsEmptyStoreReturnsEmpty() {
        let store = VoiceprintStore()
        XCTAssertTrue(store.listContacts().isEmpty)
    }

    func testListContactsAfterDeleteExcludesDeleted() {
        let store = VoiceprintStore()
        store.save(contactId: "alice", template: [1.0])
        store.save(contactId: "bob", template: [2.0])
        store.delete(contactId: "alice")

        let contacts = store.listContacts()
        XCTAssertEqual(contacts, ["bob"])
    }

    // MARK: - Has Template

    func testHasTemplateReturnsTrueWhenPresent() {
        let store = VoiceprintStore()
        store.save(contactId: "dave", template: [0.5])
        XCTAssertTrue(store.hasTemplate(contactId: "dave"))
    }

    func testHasTemplateReturnsFalseWhenAbsent() {
        let store = VoiceprintStore()
        XCTAssertFalse(store.hasTemplate(contactId: "eve"))
    }

    func testHasTemplateReturnsFalseAfterDelete() {
        let store = VoiceprintStore()
        store.save(contactId: "frank", template: [1.0])
        store.delete(contactId: "frank")
        XCTAssertFalse(store.hasTemplate(contactId: "frank"))
    }

    // MARK: - Empty Template

    func testSaveEmptyTemplate() {
        let store = VoiceprintStore()
        store.save(contactId: "empty", template: [])
        let loaded = store.load(contactId: "empty")
        XCTAssertEqual(loaded, [])
        XCTAssertTrue(store.hasTemplate(contactId: "empty"))
    }
}

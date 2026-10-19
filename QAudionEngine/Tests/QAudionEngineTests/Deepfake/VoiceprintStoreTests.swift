import XCTest
#if canImport(Security)
import Security
#endif
@testable import QAudionEngine

final class VoiceprintStoreTests: XCTestCase {

    /// Injects the in-memory backing (see `VoiceprintBacking` doc in
    /// `VoiceprintStore.swift`) instead of the real Keychain — production
    /// `VoiceprintStore()` is Keychain-backed as of the persistence fix
    /// (voiceprint templates must survive an app restart), but a unit test
    /// must stay hermetic across runs on the SAME simulator/device rather
    /// than accumulating real Keychain items call after call.
    private func makeStore() -> VoiceprintStore {
        VoiceprintStore(backing: InMemoryVoiceprintBacking())
    }

    // MARK: - Save and Load

    func testSaveAndLoadRoundTrip() {
        let store = makeStore()
        let template: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        XCTAssertTrue(store.save(contactId: "alice", template: template))

        let loaded = store.load(contactId: "alice")
        XCTAssertEqual(loaded, template)
    }

    func testLoadNonexistentReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.load(contactId: "nobody"))
    }

    func testSaveOverwritesExisting() {
        let store = makeStore()
        store.save(contactId: "bob", template: [1.0, 2.0])
        store.save(contactId: "bob", template: [3.0, 4.0])

        let loaded = store.load(contactId: "bob")
        XCTAssertEqual(loaded, [3.0, 4.0])
    }

    // MARK: - Delete

    func testDeleteRemovesEntry() {
        let store = makeStore()
        store.save(contactId: "carol", template: [1.0])
        XCTAssertTrue(store.delete(contactId: "carol"))
        XCTAssertNil(store.load(contactId: "carol"))
    }

    func testDeleteNonexistentDoesNotCrash() {
        let store = makeStore()
        XCTAssertTrue(store.delete(contactId: "ghost"), "nothing to delete is a finished delete")
    }

    // MARK: - List

    func testListContactsReturnsAllKeys() {
        let store = makeStore()
        store.save(contactId: "alice", template: [1.0])
        store.save(contactId: "bob", template: [2.0])
        store.save(contactId: "carol", template: [3.0])

        let contacts = store.listContacts()
        XCTAssertEqual(Set(contacts), Set(["alice", "bob", "carol"]))
    }

    func testListContactsEmptyStoreReturnsEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.listContacts().isEmpty)
    }

    func testListContactsAfterDeleteExcludesDeleted() {
        let store = makeStore()
        store.save(contactId: "alice", template: [1.0])
        store.save(contactId: "bob", template: [2.0])
        store.delete(contactId: "alice")

        let contacts = store.listContacts()
        XCTAssertEqual(contacts, ["bob"])
    }

    // MARK: - Has Template

    func testHasTemplateReturnsTrueWhenPresent() {
        let store = makeStore()
        store.save(contactId: "dave", template: [0.5])
        XCTAssertTrue(store.hasTemplate(contactId: "dave"))
    }

    func testHasTemplateReturnsFalseWhenAbsent() {
        let store = makeStore()
        XCTAssertFalse(store.hasTemplate(contactId: "eve"))
    }

    func testHasTemplateReturnsFalseAfterDelete() {
        let store = makeStore()
        store.save(contactId: "frank", template: [1.0])
        store.delete(contactId: "frank")
        XCTAssertFalse(store.hasTemplate(contactId: "frank"))
    }

    // MARK: - A template that says nothing is never stored

    /// An empty, non-finite or all-zero vector reads as "learned" and makes
    /// every later score meaningless, and it stops the contact from being
    /// learned again: the store refuses it.
    func testSaveRefusesAnEmptyTemplate() {
        let store = makeStore()
        XCTAssertFalse(store.save(contactId: "empty", template: []))
        XCTAssertNil(store.load(contactId: "empty"))
        XCTAssertFalse(store.hasTemplate(contactId: "empty"))
        XCTAssertEqual(store.lookup(contactId: "empty"), .absent)
    }

    func testSaveRefusesAnAllZeroTemplate() {
        let store = makeStore()
        XCTAssertFalse(store.save(contactId: "zero", template: [Float](repeating: 0, count: 512)))
        XCTAssertFalse(store.save(contactId: "negative-zero", template: [-0.0, -0.0, -0.0]))
        XCTAssertEqual(store.lookup(contactId: "zero"), .absent)
        XCTAssertEqual(store.lookup(contactId: "negative-zero"), .absent)
        XCTAssertTrue(store.listContacts().isEmpty)
    }

    func testSaveRefusesATemplateWithNaNOrInfinity() {
        let store = makeStore()
        var withNaN = [Float](repeating: 0.1, count: 8)
        withNaN[3] = .nan
        var withInfinity = [Float](repeating: 0.1, count: 8)
        withInfinity[5] = .infinity
        XCTAssertFalse(store.save(contactId: "nan", template: withNaN))
        XCTAssertFalse(store.save(contactId: "inf", template: withInfinity))
        XCTAssertFalse(store.save(contactId: "ninf", template: [-.infinity, 0.5]))
        XCTAssertTrue(store.listContacts().isEmpty)
    }

    /// A refused save must not take the place of what is already stored: a
    /// good profile survives a failed relearning.
    func testARefusedSaveLeavesThePreviousTemplateUntouched() {
        let store = makeStore()
        let good: [Float] = [0.3, 0.4, 0.5]
        XCTAssertTrue(store.save(contactId: "gina", template: good))
        XCTAssertFalse(store.save(contactId: "gina", template: [0, 0, 0]))
        XCTAssertFalse(store.save(contactId: "gina", template: [.nan, 1, 1]))
        XCTAssertFalse(store.save(contactId: "gina", template: []))
        XCTAssertEqual(store.load(contactId: "gina"), good)
    }

    /// A template already in the store that says nothing (for example one an
    /// earlier build wrote) is not a learned voice: the store reports it as
    /// absent, so the contact is learned again, and the plain reads agree.
    func testAStoredTemplateThatIsNotUsableIsAbsent() {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        var withNaN = [Float](repeating: 0.1, count: 8)
        withNaN[2] = .nan
        var withInfinity = [Float](repeating: 0.1, count: 8)
        withInfinity[4] = .infinity
        let unusable: [String: [Float]] = [
            "empty": [], "zero": [Float](repeating: 0, count: 512),
            "nan": withNaN, "inf": withInfinity,
        ]
        for (id, template) in unusable {
            XCTAssertTrue(backing.save(contactId: id, template: template), "written behind the store")
            XCTAssertEqual(store.lookup(contactId: id), .absent, id)
            XCTAssertNil(store.load(contactId: id), id)
            XCTAssertFalse(store.hasTemplate(contactId: id), id)
        }
        // Learning it again replaces it.
        let learned: [Float] = [0.4, 0.6]
        XCTAssertTrue(store.save(contactId: "zero", template: learned))
        XCTAssertEqual(store.lookup(contactId: "zero"), .present(learned))
        XCTAssertTrue(store.hasTemplate(contactId: "zero"))
    }

    func testWhatIsUsable() {
        XCTAssertTrue(VoiceprintStore.isUsable([1]))
        XCTAssertTrue(VoiceprintStore.isUsable([-0.5, 0, 0.5]))
        XCTAssertTrue(VoiceprintStore.isUsable([1e-5, 0, 0]), "small but real")
        XCTAssertFalse(VoiceprintStore.isUsable([]))
        XCTAssertFalse(VoiceprintStore.isUsable([0]))
        XCTAssertFalse(VoiceprintStore.isUsable([0, 0, 0, 0]))
        XCTAssertFalse(VoiceprintStore.isUsable([.nan]))
        XCTAssertFalse(VoiceprintStore.isUsable([1, .infinity]))
        XCTAssertFalse(VoiceprintStore.isUsable([1, -.infinity]))
    }

    // MARK: - Absent is not unreadable

    func testLookupTellsAbsentFromPresent() {
        let store = makeStore()
        XCTAssertEqual(store.lookup(contactId: "hal"), .absent)
        store.save(contactId: "hal", template: [0.5, 0.5])
        XCTAssertEqual(store.lookup(contactId: "hal"), .present([0.5, 0.5]))
    }

    /// A store that cannot be read is not an empty store: the caller must not
    /// learn the voice again nor write over it.
    func testAStoreThatCannotBeReadIsNotAbsent() {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        store.save(contactId: "ivy", template: [0.2, 0.9])

        backing.failReads = true
        XCTAssertEqual(store.lookup(contactId: "ivy"), .unreadable)
        XCTAssertEqual(store.lookup(contactId: "never-saved"), .unreadable, "it cannot say that either")
        XCTAssertNil(store.load(contactId: "ivy"), "the plain read has no template to give")
        XCTAssertFalse(store.hasTemplate(contactId: "ivy"))

        backing.failReads = false
        XCTAssertEqual(store.lookup(contactId: "ivy"), .present([0.2, 0.9]), "the profile was never touched")
    }

    func testAWriteTheStoreRefusesIsReportedAndStoresNothing() {
        let backing = InMemoryVoiceprintBacking()
        let store = VoiceprintStore(backing: backing)
        backing.failWrites = true
        XCTAssertFalse(store.save(contactId: "jon", template: [0.4, 0.4]))
        XCTAssertFalse(store.delete(contactId: "jon"))
        backing.failWrites = false
        XCTAssertEqual(store.lookup(contactId: "jon"), .absent)
    }

    // MARK: - Reading the Keychain: which outcomes are absence

    private func encoded(_ template: [Float]) -> AnyObject { VoiceprintCodec.encode(template) as AnyObject }

    /// Only "no such item" and "readable bytes in a layout this version does
    /// not use" are absence. Anything else the Keychain says (a locked store
    /// before the first unlock, an authentication failure, a surprise) is an
    /// unreadable store.
    func testOnlyNotFoundAndAnOldLayoutAreAbsence() {
        let template: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(VoiceprintKeychainRead.lookup(status: errSecSuccess, item: encoded(template)),
                       .present(template))
        XCTAssertEqual(VoiceprintKeychainRead.lookup(status: errSecItemNotFound, item: nil), .absent)
        XCTAssertEqual(VoiceprintKeychainRead.lookup(status: errSecSuccess, item: Data([1, 2, 3]) as AnyObject),
                       .absent, "bytes that are not the current layout will never become readable")
    }

    func testEveryOtherKeychainOutcomeIsUnreadable() {
        let statuses: [OSStatus] = [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable,
                                    errSecDecode, errSecParam, errSecIO, errSecAllocate]
        for status in statuses {
            XCTAssertEqual(VoiceprintKeychainRead.lookup(status: status, item: nil), .unreadable, "\(status)")
            XCTAssertEqual(VoiceprintKeychainRead.lookup(status: status, item: encoded([0.5])), .unreadable,
                           "an error status never yields a template, whatever came with it: \(status)")
        }
        XCTAssertEqual(VoiceprintKeychainRead.lookup(status: errSecSuccess, item: nil), .unreadable,
                       "success without data is not an empty store")
        XCTAssertEqual(VoiceprintKeychainRead.lookup(status: errSecSuccess, item: "text" as NSString),
                       .unreadable, "success with something that is not data is not an empty store")
    }

    // MARK: - Reading the Keychain: which class an item is moved from

    /// After a successful read, only an item still in the class an earlier
    /// build wrote is moved. An item already moved, one in a class this code
    /// never wrote, and one that reports nothing are left alone.
    func testOnlyAnItemStillInTheOldClassIsMoved() {
        XCTAssertTrue(VoiceprintKeychainRead.needsAccessibilityUpgrade(
            attribute: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))
        XCTAssertFalse(VoiceprintKeychainRead.needsAccessibilityUpgrade(
            attribute: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        XCTAssertFalse(VoiceprintKeychainRead.needsAccessibilityUpgrade(
            attribute: kSecAttrAccessibleWhenUnlocked as String), "a class this code never wrote")
        XCTAssertFalse(VoiceprintKeychainRead.needsAccessibilityUpgrade(attribute: nil))
        XCTAssertFalse(VoiceprintKeychainRead.needsAccessibilityUpgrade(attribute: 42))
    }

    // MARK: - Codec

    func testCodecRoundTrip() {
        let template: [Float] = (0..<512).map { Float($0) / 512 - 0.25 }
        XCTAssertEqual(VoiceprintCodec.decode(VoiceprintCodec.encode(template)), template)
    }

    func testCodecRejectsAnythingThatIsNotTheCurrentLayout() {
        let good = VoiceprintCodec.encode([0.1, 0.2, 0.3])
        XCTAssertNotNil(VoiceprintCodec.decode(good))
        XCTAssertNil(VoiceprintCodec.decode(Data()))
        XCTAssertNil(VoiceprintCodec.decode(good.prefix(11)), "shorter than the header")
        XCTAssertNil(VoiceprintCodec.decode(good.dropLast()), "one byte missing")
        XCTAssertNil(VoiceprintCodec.decode(good + Data([0])), "one byte too many")
        var wrongMagic = good
        wrongMagic[0] ^= 0xFF
        XCTAssertNil(VoiceprintCodec.decode(wrongMagic))
        var wrongVersion = good
        wrongVersion[4] ^= 0xFF
        XCTAssertNil(VoiceprintCodec.decode(wrongVersion))
        XCTAssertNil(VoiceprintCodec.decode(VoiceprintCodec.encode([])), "a template with no dimension")
    }
}

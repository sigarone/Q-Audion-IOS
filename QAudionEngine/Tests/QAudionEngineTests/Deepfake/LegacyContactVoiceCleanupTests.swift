import XCTest
@testable import QAudionEngine

final class LegacyContactVoiceCleanupTests: XCTestCase {

    /// The contact templates are gone after the cleanup, the owner's is still
    /// there, and the cleanup does not run twice on one install.
    func testContactTemplatesAreRemovedAndTheOwnersIsKept() throws {
        let suite = "LegacyContactVoiceCleanupTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let unlocked = ProtectedDataFlag()

        let store = VoiceprintStore(backing: InMemoryVoiceprintBacking())
        let template = [Float](repeating: 0.5, count: 512)
        XCTAssertTrue(store.save(contactId: VoiceprintStore.deviceOwnerId, template: template))
        XCTAssertTrue(store.save(contactId: "contact-a", template: template))
        XCTAssertTrue(store.save(contactId: "contact-b", template: template))

        XCTAssertTrue(LegacyContactVoiceCleanup.runIfNeeded(store: store, defaults: defaults, protectedData: unlocked))

        XCTAssertEqual(store.load(contactId: VoiceprintStore.deviceOwnerId), template, "the owner's template is kept")
        XCTAssertNil(store.load(contactId: "contact-a"))
        XCTAssertNil(store.load(contactId: "contact-b"))
        XCTAssertEqual(store.listContacts(), [VoiceprintStore.deviceOwnerId])
        XCTAssertFalse(LegacyContactVoiceCleanup.runIfNeeded(store: store, defaults: defaults, protectedData: unlocked),
                       "done once")
    }

    /// A lock while the removal runs can leave items out of the Keychain
    /// listing, so that run is not marked done and the next one starts again.
    func testALockDuringTheRemovalLeavesItNotDone() throws {
        let suite = "LegacyContactVoiceCleanupTests.lock"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let protectedData = ProtectedDataFlag()

        let backing = InMemoryVoiceprintBacking()
        backing.onDeleteAll = { protectedData.set(isAvailable: false) }
        let store = VoiceprintStore(backing: backing)
        let template = [Float](repeating: 0.5, count: 512)
        XCTAssertTrue(store.save(contactId: "contact-a", template: template))

        XCTAssertFalse(LegacyContactVoiceCleanup.runIfNeeded(store: store, defaults: defaults, protectedData: protectedData),
                       "locked during the run")
        XCTAssertFalse(defaults.bool(forKey: LegacyContactVoiceCleanup.doneKey), "no mark")

        backing.onDeleteAll = nil
        protectedData.set(isAvailable: true)
        XCTAssertTrue(LegacyContactVoiceCleanup.runIfNeeded(store: store, defaults: defaults, protectedData: protectedData),
                      "runs again once unlocked")
        XCTAssertTrue(defaults.bool(forKey: LegacyContactVoiceCleanup.doneKey))
    }
}

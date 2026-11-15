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
}

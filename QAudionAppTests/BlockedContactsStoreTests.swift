import XCTest
@testable import QAudionApp
import QAudionEngine

/// BLOCK — the on-device blocked list the receive paths read (`BlockedContactsStore`) and the adapter the shared
/// block / unblock function writes through (`BlockedContactsStorage`): which ids count as blocked, that the whole
/// list can be replaced by the server's, that a change is announced to the screens and a no-op is not.
///
/// The list lives in `UserDefaults.standard` under one key; each test saves what was there and puts it back, so a
/// developer's own list on a simulator is not lost. The rules around it (`BlockPolicy`) and the block / unblock
/// function are tested in the engine (`ContactBlockingTests`).
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class BlockedContactsStoreTests: XCTestCase {

    private let defaultsKey = "qaudion.contacts.blocked"
    private var saved: [String]?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.stringArray(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
        super.tearDown()
    }

    // MARK: - who is blocked

    func testAnAddedContactIsBlockedAndAnotherIsNot() {
        BlockedContactsStore.add("user-1")
        XCTAssertTrue(BlockedContactsStore.isBlocked("user-1"))
        XCTAssertFalse(BlockedContactsStore.isBlocked("user-2"))
    }

    func testIdentifiersAreMatchedTrimmedAndCaseInsensitively() {
        BlockedContactsStore.add("  B0D7BA30-655B-420D-A4ED-8848EFC51C98 ")
        XCTAssertTrue(BlockedContactsStore.isBlocked("b0d7ba30-655b-420d-a4ed-8848efc51c98"))
        XCTAssertEqual(BlockedContactsStore.loadBlockedIds(), ["B0D7BA30-655B-420D-A4ED-8848EFC51C98"],
                       "stored trimmed, as the server spelled it")
    }

    func testAnEmptyIdentifierIsNeverStoredOrBlocked() {
        BlockedContactsStore.add("")
        BlockedContactsStore.add("   ")
        XCTAssertTrue(BlockedContactsStore.loadBlockedIds().isEmpty)
        XCTAssertFalse(BlockedContactsStore.isBlocked(""))
    }

    func testBlockingTheSameContactTwiceKeepsOneEntryEvenWhenTheCaseDiffers() {
        BlockedContactsStore.add("User-1")
        BlockedContactsStore.add("user-1")
        XCTAssertEqual(BlockedContactsStore.loadBlockedIds().count, 1)
    }

    func testRemovingAContactUnblocksItWhateverTheCase() {
        BlockedContactsStore.add("User-1")
        BlockedContactsStore.add("user-2")
        BlockedContactsStore.remove("USER-1")
        XCTAssertFalse(BlockedContactsStore.isBlocked("user-1"))
        XCTAssertTrue(BlockedContactsStore.isBlocked("user-2"))
    }

    // MARK: - replacing the list by the server's

    func testReplaceAllReplacesTheWholeList() {
        BlockedContactsStore.add("a")
        BlockedContactsStore.add("b")
        BlockedContactsStore.replaceAll(["b", " c "])
        XCTAssertEqual(BlockedContactsStore.loadBlockedIds(), ["b", "c"])
        XCTAssertFalse(BlockedContactsStore.isBlocked("a"))
        XCTAssertTrue(BlockedContactsStore.isBlocked("c"))
    }

    func testClearForgetsTheListOfTheAccountThatLeft() {
        BlockedContactsStore.add("a")
        BlockedContactsStore.clear()
        XCTAssertTrue(BlockedContactsStore.loadBlockedIds().isEmpty)
        XCTAssertFalse(BlockedContactsStore.isBlocked("a"))
    }

    func testTheStorageAdapterReadsAndWritesTheSameList() {
        let storage: BlockedListStorage = BlockedContactsStorage()
        storage.insert("a")
        storage.replaceAll(["b"])
        XCTAssertEqual(storage.blockedIds(), ["b"])
        storage.remove("B")
        XCTAssertTrue(storage.blockedIds().isEmpty)
    }

    // MARK: - telling the screens

    func testAChangeIsAnnouncedOnTheMainQueue() {
        let announced = expectation(forNotification: .blockedContactsDidChange, object: nil) { _ in
            Thread.isMainThread
        }
        BlockedContactsStore.add("a")
        wait(for: [announced], timeout: 5)
    }

    func testAReplacementThatChangesNothingIsNotAnnounced() {
        BlockedContactsStore.replaceAll(["a", "b"])
        // Let the announcement of the setup above go by before listening.
        let settle = expectation(description: "setup announcement delivered")
        DispatchQueue.main.async { settle.fulfill() }
        wait(for: [settle], timeout: 5)

        let silent = expectation(forNotification: .blockedContactsDidChange, object: nil, handler: nil)
        silent.isInverted = true
        BlockedContactsStore.replaceAll(["A", "b"])   // the same list, spelled differently
        BlockedContactsStore.add("a")                  // already blocked
        BlockedContactsStore.remove("not-there")       // nothing to remove
        wait(for: [silent], timeout: 0.5)
    }
}

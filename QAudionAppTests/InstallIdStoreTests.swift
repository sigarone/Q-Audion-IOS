import XCTest
@testable import QAudionEngine

private final class MemoryInstallIdStorage: InstallIdStorage {
    var value: String?
    func read() -> String? { value }
    func write(_ value: String) { self.value = value }
    func delete() { value = nil }
}

final class InstallIdStoreTests: XCTestCase {
    func testGeneratesUuidOnceAndKeepsIt() {
        let store = InstallIdStore(storage: MemoryInstallIdStorage())
        let first = store.current()
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(store.current(), first)
    }

    func testReusesStoredValue() {
        let storage = MemoryInstallIdStorage()
        storage.value = "0b6f3c1e-2d4a-4b8e-9c10-5a7e8f9d0a1b"
        XCTAssertEqual(InstallIdStore(storage: storage).current(), "0b6f3c1e-2d4a-4b8e-9c10-5a7e8f9d0a1b")
    }

    func testCorruptStoredValueIsReplaced() {
        let storage = MemoryInstallIdStorage()
        storage.value = "not-a-uuid"
        let id = InstallIdStore(storage: storage).current()
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(storage.value, id)
    }

    func testResetProducesNewId() {
        let store = InstallIdStore(storage: MemoryInstallIdStorage())
        let first = store.current()
        store.reset()
        XCTAssertNotEqual(store.current(), first)
    }

    func testAddPutsInstallIdInBody() {
        let store = InstallIdStore(storage: MemoryInstallIdStorage())
        var dict: [String: Any] = ["password": "x"]
        store.add(to: &dict)
        XCTAssertEqual(dict["install_id"] as? String, store.current())
        XCTAssertEqual(dict["password"] as? String, "x")
    }
}

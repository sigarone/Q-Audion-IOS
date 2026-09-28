import XCTest
@testable import QAudionEngine

/// W-MEDIAATACCEPT (option b) — §6/§9: per-call key isolation, replacing
/// the single global `callPqcSessionKey` slot as the durable write target.
final class CallKeyStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CallKeyStore.shared.resetForTesting()
    }

    override func tearDown() {
        CallKeyStore.shared.resetForTesting()
        super.tearDown()
    }

    func testIsolationBetweenTwoConcurrentCalls() {
        let store = CallKeyStore.shared
        let keyA = Data(repeating: 0xAA, count: 32)
        let keyB = Data(repeating: 0xBB, count: 32)

        store.put(callId: "call-a", key: keyA)
        store.put(callId: "call-b", key: keyB)

        XCTAssertEqual(store.get("call-a"), keyA)
        XCTAssertEqual(store.get("call-b"), keyB)
        XCTAssertNotEqual(store.get("call-a"), store.get("call-b"))
    }

    func testGetIsCaseInsensitiveOnCallId() {
        let store = CallKeyStore.shared
        let key = Data(repeating: 0x11, count: 32)
        store.put(callId: "CaLL-X", key: key)
        XCTAssertEqual(store.get("call-x"), key)
    }

    func testWipeZeroesAndRemoves() {
        let store = CallKeyStore.shared
        store.put(callId: "call-a", key: Data(repeating: 0xAA, count: 32))
        store.wipe("call-a", why: 1)
        XCTAssertNil(store.get("call-a"))
        XCTAssertNil(store.entry("call-a"))
    }

    func testTakeDoesNotRemoveEntry() {
        // Spec §6: `take` is the controller-seed read, not a consume-once —
        // the active-call projection must keep resolving after it.
        let store = CallKeyStore.shared
        let key = Data(repeating: 0x42, count: 32)
        store.put(callId: "call-a", key: key)
        XCTAssertEqual(store.take("call-a"), key)
        XCTAssertEqual(store.get("call-a"), key, "take must not remove the entry")
    }

    func testWipeAllClearsEveryEntry() {
        let store = CallKeyStore.shared
        store.put(callId: "call-a", key: Data(repeating: 0x01, count: 32))
        store.put(callId: "call-b", key: Data(repeating: 0x02, count: 32))
        store.wipeAll(why: 1)
        XCTAssertNil(store.get("call-a"))
        XCTAssertNil(store.get("call-b"))
    }

    func testEmptyCallIdIsNeverStoredOrRead() {
        let store = CallKeyStore.shared
        store.put(callId: "", key: Data(repeating: 0x01, count: 32))
        XCTAssertNil(store.get(""))
        XCTAssertNil(store.get(nil))
    }

    func testMaxEntriesEvictsOldest() {
        let store = CallKeyStore.shared
        for i in 0..<CallKeyStore.maxEntries {
            store.put(callId: "call-\(i)", key: Data(repeating: UInt8(i), count: 32))
            Thread.sleep(forTimeInterval: 0.002)
        }
        XCTAssertNotNil(store.get("call-0"))
        store.put(callId: "call-overflow", key: Data(repeating: 0xFF, count: 32))
        XCTAssertNil(store.get("call-0"), "the oldest entry must be evicted to make room")
        XCTAssertNotNil(store.get("call-overflow"))
    }

    func testLatestPutForSameCallIdReplacesPrevious() {
        let store = CallKeyStore.shared
        store.put(callId: "call-a", key: Data(repeating: 0x01, count: 32), origin: .transitional)
        store.put(callId: "call-a", key: Data(repeating: 0x02, count: 32), origin: .pqc)
        XCTAssertEqual(store.get("call-a"), Data(repeating: 0x02, count: 32))
        XCTAssertEqual(store.entry("call-a")?.origin, .pqc)
    }

    func testSweepRemovesOnlyExpiredEntries() {
        let store = CallKeyStore.shared
        store.put(callId: "call-a", key: Data(repeating: 0x01, count: 32))
        store.sweep(nowMs: Int64(Date().timeIntervalSince1970 * 1000) + CallKeyStore.ttlMs + 1_000)
        XCTAssertNil(store.get("call-a"))
    }
}

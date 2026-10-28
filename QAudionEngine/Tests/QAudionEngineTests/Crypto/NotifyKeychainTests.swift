import Foundation
import Security
import XCTest
@testable import QAudionEngine

/// The notification private key store: its query shape (pure) and a real round trip where the Keychain is usable.
final class NotifyKeychainTests: XCTestCase {

    private func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: NotifyKeychain.keyLength) }

    // MARK: - Query shape (no Keychain needed)

    func testNewItemIsAfterFirstUnlockThisDeviceOnlyAndNotSynchronised() {
        let query = NotifyKeychain(accessGroup: "TEAM.com.qaudion.notify").addQuery(key(1))
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, NotifyKeychain.service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, NotifyKeychain.account)
    }

    func testItemIsPlacedInTheNotifyAccessGroup() {
        let store = NotifyKeychain(accessGroup: "TEAM.com.qaudion.notify")
        XCTAssertEqual(store.identityQuery()[kSecAttrAccessGroup as String] as? String, "TEAM.com.qaudion.notify")
        XCTAssertEqual(store.addQuery(key(1))[kSecAttrAccessGroup as String] as? String, "TEAM.com.qaudion.notify")
    }

    func testNoAccessGroupMeansTheDefaultGroup() {
        XCTAssertNil(NotifyKeychain(accessGroup: nil).identityQuery()[kSecAttrAccessGroup as String])
    }

    func testWrongLengthIsRefused() {
        let store = NotifyKeychain(accessGroup: nil)
        XCTAssertThrowsError(try store.store(Data(repeating: 1, count: 31))) {
            XCTAssertEqual($0 as? NotifyKeychain.StoreError, .invalidLength)
        }
        XCTAssertThrowsError(try store.store(Data())) {
            XCTAssertEqual($0 as? NotifyKeychain.StoreError, .invalidLength)
        }
    }

    func testProductionNeedsAnExpandedGroupInTheBundle() {
        // The test bundle has no such key.
        XCTAssertNil(NotifyKeychain.production(bundle: Bundle(for: NotifyKeychainTests.self)))
    }

    // MARK: - Round trip (real Keychain)

    func testStoreLoadReplaceDelete() throws {
        try KeychainAvailability.requireKeychain()
        let store = NotifyKeychain(accessGroup: nil)
        store.delete()
        defer { store.delete() }

        XCTAssertNil(store.load())
        try store.store(key(0x11))
        XCTAssertEqual(store.load(), key(0x11))
        try store.store(key(0x22))
        XCTAssertEqual(store.load(), key(0x22))
        store.delete()
        XCTAssertNil(store.load())
    }
}

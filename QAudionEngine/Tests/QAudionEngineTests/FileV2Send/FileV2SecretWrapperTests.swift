import XCTest
@testable import QAudionEngine
#if canImport(Security)
import Security
#endif

/// The secret wrapper of the send state (WIRE_SPEC 12.8: `K` and the token never rest in the clear): the in-memory wrapper of
/// the tests, and the Keychain wrapper of production, its queries and its handling of a real Keychain.
final class FileV2SecretWrapperTests: XCTestCase {

    private let secret = Data((0..<32).map { UInt8(0x30 &+ UInt8($0)) })

    func testTheInMemoryWrapperGivesBackWhatItWrappedAndTheBlobIsNotTheSecret() throws {
        let wrapper = FileV2InMemorySecretWrapper()
        let blob = try wrapper.wrap(secret)
        XCTAssertNotEqual(blob, secret)
        XCTAssertNil(blob.range(of: secret))
        XCTAssertEqual(try wrapper.unwrap(blob), secret)
        XCTAssertEqual(try wrapper.allBlobs(), [blob])
        XCTAssertEqual(wrapper.count, 1)

        let other = try wrapper.wrap(secret)
        XCTAssertNotEqual(blob, other, "every wrap makes its own handle")
    }

    func testDestroyRemovesTheSecretForGoodAndIsIdempotent() throws {
        let wrapper = FileV2InMemorySecretWrapper()
        let blob = try wrapper.wrap(secret)
        wrapper.destroy(blob)
        wrapper.destroy(blob)
        XCTAssertThrowsError(try wrapper.unwrap(blob)) { XCTAssertEqual($0 as? FileV2SecretError, .unavailable) }
        XCTAssertEqual(try wrapper.allBlobs(), [])
        XCTAssertEqual(wrapper.count, 0)
        XCTAssertThrowsError(try wrapper.unwrap(Data(repeating: 1, count: 16)))
    }

    func testAFailingWrapSurfacesAsAnErrorAndWrapsNothing() throws {
        let wrapper = FileV2InMemorySecretWrapper()
        wrapper.failNextWrapCall()
        XCTAssertThrowsError(try wrapper.wrap(secret))
        XCTAssertEqual(wrapper.count, 0)
        XCTAssertNoThrow(try wrapper.wrap(secret))
    }

    func testTheErrorsNeverCarryASecret() {
        for error in [FileV2SecretError.unavailable, FileV2SecretError.failed(-34018)] {
            XCTAssertFalse(SendStoreFixtures.printed(error).contains(String(decoding: secret, as: UTF8.self)))
        }
    }

    #if canImport(Security)

    // MARK: The Keychain wrapper

    /// A Keychain that lives in a dictionary, to test the wrapper where the real one cannot be used.
    private final class FakeKeychainItems: FileV2KeychainItems, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var items: [String: Data] = [:]
        private(set) var addedServices: [String] = []

        func add(service: String, account: String, secret: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            guard items[service + "|" + account] == nil else { throw FileV2SecretError.failed(Int32(errSecDuplicateItem)) }
            items[service + "|" + account] = secret
            addedServices.append(service)
        }

        func read(service: String, account: String) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            guard let data = items[service + "|" + account] else { throw FileV2SecretError.unavailable }
            return data
        }

        func delete(service: String, account: String) {
            lock.lock()
            defer { lock.unlock() }
            items[service + "|" + account] = nil
        }

        func accounts(service: String) throws -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return items.keys.filter { $0.hasPrefix(service + "|") }.map { String($0.dropFirst(service.count + 1)) }
        }
    }

    func testTheKeychainWrapperNamesItemsByARandomHandleAndDestroyDeletesThem() throws {
        let items = FakeKeychainItems()
        let wrapper = FileV2KeychainSecretWrapper(service: "svc", items: items)
        let blob = try wrapper.wrap(secret)
        XCTAssertEqual(blob.count, 16)
        XCTAssertNil(blob.range(of: secret))
        XCTAssertEqual(items.items.count, 1)
        let account = FileV2KeychainSecretWrapper.account(for: blob)
        XCTAssertEqual(account.utf8.count, 32)
        XCTAssertEqual(items.items["svc|" + account], secret)
        XCTAssertEqual(try wrapper.unwrap(blob), secret)
        XCTAssertEqual(try wrapper.allBlobs(), [blob])

        wrapper.destroy(blob)
        XCTAssertEqual(items.items.count, 0)
        XCTAssertThrowsError(try wrapper.unwrap(blob)) { XCTAssertEqual($0 as? FileV2SecretError, .unavailable) }
        wrapper.destroy(blob)
    }

    func testTheKeychainWrapperIgnoresAccountsThatAreNotItsHandlesAndRefusesBadBlobs() throws {
        let items = FakeKeychainItems()
        try items.add(service: "svc", account: "someone-elses-account", secret: secret)
        try items.add(service: "svc", account: String(repeating: "Z", count: 32), secret: secret)
        let wrapper = FileV2KeychainSecretWrapper(service: "svc", items: items)
        XCTAssertEqual(try wrapper.allBlobs(), [], "only 32 lowercase hex characters name a handle")
        XCTAssertThrowsError(try wrapper.unwrap(Data([1, 2, 3])))
        wrapper.destroy(Data([1, 2, 3]))
        XCTAssertEqual(items.items.count, 2, "a malformed blob deletes nothing")
        XCTAssertEqual(FileV2KeychainSecretWrapper.handle(forAccount: FileV2KeychainSecretWrapper.account(for: Data(0..<16))),
                       Data(0..<16))
    }

    func testTheKeychainItemsAreThisDeviceOnlyNotSynchronisedAndAvailableAfterTheFirstUnlock() {
        let add = FileV2KeychainQueries.add(service: "svc", account: "acc", secret: secret, accessGroup: nil)
        XCTAssertEqual(add[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(add[kSecAttrService as String] as? String, "svc")
        XCTAssertEqual(add[kSecAttrAccount as String] as? String, "acc")
        XCTAssertEqual(add[kSecValueData as String] as? Data, secret)
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false, "never synchronised through iCloud")
        XCTAssertNil(add[kSecAttrAccessGroup as String])

        let grouped = FileV2KeychainQueries.add(service: "svc", account: "acc", secret: secret, accessGroup: "group.example")
        XCTAssertEqual(grouped[kSecAttrAccessGroup as String] as? String, "group.example")

        for query in [FileV2KeychainQueries.read(service: "svc", account: "acc", accessGroup: nil),
                      FileV2KeychainQueries.delete(service: "svc", account: "acc", accessGroup: nil),
                      FileV2KeychainQueries.list(service: "svc", accessGroup: nil)] {
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "svc")
            XCTAssertNil(query[kSecValueData as String], "no secret in a read, delete or list query")
        }
        XCTAssertEqual(FileV2KeychainQueries.read(service: "s", account: "a", accessGroup: nil)[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(FileV2KeychainQueries.list(service: "s", accessGroup: nil)[kSecMatchLimit as String] as? String,
                       kSecMatchLimitAll as String)
    }

    /// The real Keychain. A unit-test bundle in the simulator has no keychain-access-group entitlement and every `SecItemAdd`
    /// answers -34018: the case then reports its skip with the reason (`KeychainAvailability`) and runs wherever the
    /// Keychain works, a real device included.
    func testTheRealKeychainRoundTripAndDestroy() throws {
        try KeychainAvailability.requireKeychain()
        let service = "app.qaudion.filev2.send.tests-\(UUID().uuidString)"
        let wrapper = FileV2KeychainSecretWrapper(service: service)
        let blob = try wrapper.wrap(secret)
        defer { wrapper.destroy(blob) }
        XCTAssertEqual(try wrapper.unwrap(blob), secret)
        XCTAssertEqual(try wrapper.allBlobs(), [blob])
        wrapper.destroy(blob)
        XCTAssertThrowsError(try wrapper.unwrap(blob)) { XCTAssertEqual($0 as? FileV2SecretError, .unavailable) }
        XCTAssertEqual(try wrapper.allBlobs(), [])
    }

    #endif
}

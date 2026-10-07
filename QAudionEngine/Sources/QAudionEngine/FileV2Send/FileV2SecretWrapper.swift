import Foundation
#if canImport(Security)
import Security
#endif

/// Why a secret could not be wrapped or unwrapped. Never carries the secret or a handle.
public enum FileV2SecretError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The wrapper no longer holds what the blob refers to (a Keychain item that is gone, a blob it does not know).
    case unavailable
    /// The secure store refused the operation; `status` is its numeric code (an `OSStatus` on Apple platforms).
    case failed(Int32)

    public var description: String {
        switch self {
        case .unavailable: return "FileV2SecretError(unavailable)"
        case .failed(let status): return "FileV2SecretError(failed: \(status))"
        }
    }
}

/// Protects the two secrets of a send transfer, the file key `K` and the download token (WIRE_SPEC 12.8: "`K` wrapped by the
/// Keystore", "iOS: Keychain `ThisDeviceOnly`", "desktop: `safeStorage`"). The journal stores the BLOB `wrap` returns and
/// nothing else, so a copy of the journal (a backup, a forensic image of the app container) holds no key.
///
/// The blob is opaque: the Keychain implementation returns a random handle that names a Keychain item, an in-process test
/// implementation does the same with a dictionary. `destroy` is what makes a wipe real: it deletes the item the blob names (a
/// Keychain item survives the deletion of the app's files, and even of the app).
public protocol FileV2SecretWrapper: Sendable {
    /// Protects `secret` and returns the blob to store in its place.
    func wrap(_ secret: Data) throws -> Data
    /// The secret a blob stands for. Throws `unavailable` when it is gone (the transfer then cannot go on and is cancelled).
    func unwrap(_ wrapped: Data) throws -> Data
    /// Destroys what the blob refers to. Idempotent; never throws (a wipe must not stop half way).
    func destroy(_ wrapped: Data)
    /// The blobs of every secret this wrapper currently holds, so that a launch can destroy the ones no journal refers to (a
    /// crash between `wrap` and the begin record, a reinstall that took the journals away and left the Keychain). An
    /// implementation that cannot enumerate returns an empty list.
    func allBlobs() throws -> [Data]
}

/// A wrapper that holds secrets in this process only (tests, previews). Each secret gets a random 16-byte handle; the blob IS the
/// handle. A `destroy` zeroes the secret it held.
public final class FileV2InMemorySecretWrapper: FileV2SecretWrapper, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data: Data] = [:]
    private var failNextWrap = false

    public init() {}

    public func wrap(_ secret: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if failNextWrap {
            failNextWrap = false
            throw FileV2SecretError.failed(-1)
        }
        let handle = FileV2.randomBytes(16)
        items[handle] = Data([UInt8](secret))
        return handle
    }

    public func unwrap(_ wrapped: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = items[wrapped] else { throw FileV2SecretError.unavailable }
        return Data([UInt8](secret))
    }

    public func destroy(_ wrapped: Data) {
        lock.lock()
        defer { lock.unlock() }
        if var secret = items.removeValue(forKey: wrapped) { FileV2Secret.wipe(&secret) }
    }

    public func allBlobs() throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.keys)
    }

    /// How many secrets are held now.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    /// Test control: the next `wrap` fails (a secure store that refuses).
    public func failNextWrapCall() {
        lock.lock()
        defer { lock.unlock() }
        failNextWrap = true
    }

    /// Test support: every secret held, so a test can scan files for them. Never used by the pipeline.
    func heldSecrets() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values)
    }
}

#if canImport(Security)

/// The Keychain operations the production wrapper needs, as one small interface so the wrapper (and the attributes it asks for)
/// can be tested where the real Keychain is not usable (a unit-test bundle in the simulator has no keychain-access-group
/// entitlement: `SecItemAdd` answers -34018 there, see `KeychainAvailability` in the tests).
public protocol FileV2KeychainItems: Sendable {
    func add(service: String, account: String, secret: Data) throws
    func read(service: String, account: String) throws -> Data
    /// Deletes an item; a missing one is not an error.
    func delete(service: String, account: String)
    func accounts(service: String) throws -> [String]
}

/// The queries of the Keychain implementation, built in one place so their attributes can be asserted.
enum FileV2KeychainQueries {

    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by a transfer that goes on in the background after the first
    /// unlock, never part of a backup, never moved to another device. Not synchronised through iCloud.
    static func add(service: String, account: String, secret: Data, accessGroup: String?) -> [String: Any] {
        var query = identity(service: service, account: account, accessGroup: accessGroup)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }

    static func read(service: String, account: String, accessGroup: String?) -> [String: Any] {
        var query = identity(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    static func delete(service: String, account: String, accessGroup: String?) -> [String: Any] {
        identity(service: service, account: account, accessGroup: accessGroup)
    }

    static func list(service: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        if let group = accessGroup { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    private static func identity(service: String, account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        if let group = accessGroup { query[kSecAttrAccessGroup as String] = group }
        return query
    }
}

/// The real Keychain.
public struct FileV2SystemKeychainItems: FileV2KeychainItems {
    private let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    public func add(service: String, account: String, secret: Data) throws {
        let status = SecItemAdd(FileV2KeychainQueries.add(service: service, account: account, secret: secret,
                                                          accessGroup: accessGroup) as CFDictionary, nil)
        guard status == errSecSuccess else { throw FileV2SecretError.failed(Int32(status)) }
    }

    public func read(service: String, account: String) throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(FileV2KeychainQueries.read(service: service, account: account,
                                                                    accessGroup: accessGroup) as CFDictionary, &result)
        if status == errSecItemNotFound { throw FileV2SecretError.unavailable }
        guard status == errSecSuccess, let data = result as? Data else { throw FileV2SecretError.failed(Int32(status)) }
        return data
    }

    public func delete(service: String, account: String) {
        _ = SecItemDelete(FileV2KeychainQueries.delete(service: service, account: account,
                                                       accessGroup: accessGroup) as CFDictionary)
    }

    public func accounts(service: String) throws -> [String] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(FileV2KeychainQueries.list(service: service, accessGroup: accessGroup) as CFDictionary,
                                         &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw FileV2SecretError.failed(Int32(status)) }
        let items = (result as? [[String: Any]]) ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// The production wrapper: each secret is a Keychain generic-password item of its own, `ThisDeviceOnly`, named by a random
/// handle (the blob). `destroy` deletes the item.
public final class FileV2KeychainSecretWrapper: FileV2SecretWrapper, @unchecked Sendable {
    public static let defaultService = "app.qaudion.filev2.send"

    private let service: String
    private let items: FileV2KeychainItems

    public init(service: String = FileV2KeychainSecretWrapper.defaultService,
                items: FileV2KeychainItems = FileV2SystemKeychainItems()) {
        self.service = service
        self.items = items
    }

    public func wrap(_ secret: Data) throws -> Data {
        let handle = FileV2.randomBytes(16)
        try items.add(service: service, account: FileV2KeychainSecretWrapper.account(for: handle), secret: secret)
        return handle
    }

    public func unwrap(_ wrapped: Data) throws -> Data {
        guard wrapped.count == 16 else { throw FileV2SecretError.unavailable }
        return try items.read(service: service, account: FileV2KeychainSecretWrapper.account(for: wrapped))
    }

    public func destroy(_ wrapped: Data) {
        guard wrapped.count == 16 else { return }
        items.delete(service: service, account: FileV2KeychainSecretWrapper.account(for: wrapped))
    }

    public func allBlobs() throws -> [Data] {
        try items.accounts(service: service).compactMap { FileV2KeychainSecretWrapper.handle(forAccount: $0) }
    }

    /// The Keychain account of a handle: its 32 lowercase hex characters.
    static func account(for handle: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(handle.count * 2)
        for byte in handle {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func handle(forAccount account: String) -> Data? {
        let bytes = Array(account.utf8)
        guard bytes.count == 32 else { return nil }
        var out = Data()
        var high: UInt8?
        for character in bytes {
            let value: UInt8
            switch character {
            case 0x30...0x39: value = character - 0x30
            case 0x61...0x66: value = character - 0x61 + 10
            default: return nil
            }
            if let top = high {
                out.append(top << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return out
    }
}

#endif

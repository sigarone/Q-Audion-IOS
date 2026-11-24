import Foundation
import CryptoKit
import Security

/// Where the 256-bit key of the voice store lives. The app uses `VoiceKeychainVault`; the tests use an in-memory vault.
protocol VoiceKeyVault: AnyObject {
    /// The key bytes, or nil when there is no key. Every other outcome (the keychain is not available, the device is locked)
    /// throws `VoiceStoreError.Kind.key`: it is never read as "no key".
    func read() throws -> [UInt8]?
    func add(_ key: [UInt8]) throws
    /// Removes the key; a key that is not there is not an error.
    func remove() throws
}

/// The key as a Keychain generic password: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the store must work at the end of a
/// call while the phone is locked), no user-presence or biometric flag, not synchronizable, so it never leaves the device.
final class VoiceKeychainVault: VoiceKeyVault, @unchecked Sendable {
    static let service = "com.bcrypto.qaudion.voice"
    static let account = "qaudion_voice_v3"

    private let service: String
    private let account: String

    init(service: String = VoiceKeychainVault.service, account: String = VoiceKeychainVault.account) {
        self.service = service
        self.account = account
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    func read() throws -> [UInt8]? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VoiceStoreError(.key, "keychain read failed (\(status))")
        }
        return [UInt8](data)
    }

    func add(_ key: [UInt8]) throws {
        var query = baseQuery()
        query[kSecValueData as String] = Data(key)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw VoiceStoreError(.key, "keychain add failed (\(status))") }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceStoreError(.key, "keychain delete failed (\(status))")
        }
    }
}

/// The `VoiceAead` of the app: AES-256-GCM with a key in the Keychain (`VoiceKeyVault`), created the first time it is needed.
/// `dataExists` tells whether the store has a `meta.bin` or a record; `VoiceKeyGuard` uses it to decide when a key may be
/// created or replaced:
///  - the key is looked up again before a new one is created while data exists;
///  - the key is kept in memory after the first successful lookup and dropped only by `deleteKey`;
///  - a key that exists while no data exists is a leftover of a deleted installation (the keychain outlives the app): the store
///    decides that once, when it creates `meta.bin`, and then calls `deleteKey`.
final class VoiceKeychainAead: VoiceAead, @unchecked Sendable {
    private let delegate: VoiceAesGcmAead

    init(dataExists: @escaping () throws -> Bool, vault: VoiceKeyVault = VoiceKeychainVault(),
         log: @escaping (String) -> Void = { _ in }, sleep: @escaping (Int) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1000.0) }) {
        let keyLock = NSLock()
        var cached: SymmetricKey? // the key of this process after the first successful lookup; cleared by deleteKey only
        let guardian = VoiceKeyGuard(
            existing: {
                guard let bytes = try vault.read() else { return nil }
                guard bytes.count == 32 else { throw VoiceStoreError(.key, "stored key has an unexpected size") }
                return SymmetricKey(data: bytes)
            },
            create: {
                let key = SymmetricKey(size: .bits256)
                try vault.add(key.withUnsafeBytes { [UInt8]($0) })
                return key
            },
            dataExists: dataExists,
            log: log,
            sleep: sleep)
        delegate = VoiceAesGcmAead(
            key: {
                try keyLock.withLock {
                    if let cached { return cached }
                    let key = try guardian.get()
                    cached = key
                    return key
                }
            },
            onDeleteKey: {
                try keyLock.withLock {
                    cached = nil
                    try vault.remove()
                }
            })
    }

    func seal(_ plaintext: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        try delegate.seal(plaintext, aad: aad)
    }

    func open(_ sealed: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        try delegate.open(sealed, aad: aad)
    }

    func deleteKey() throws {
        try delegate.deleteKey()
    }
}

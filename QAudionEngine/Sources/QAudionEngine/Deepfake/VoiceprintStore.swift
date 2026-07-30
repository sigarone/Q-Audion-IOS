import Foundation
#if canImport(Security)
import Security
#endif

/// Storage abstraction so `VoiceprintStore` can be exercised in unit tests
/// without touching the real Keychain — mirrors this codebase's
/// `RatchetVault`/`KeychainRatchetVault`/`InMemoryRatchetVault` split (see
/// `RatchetVault.swift`) for the same reason: tests must stay hermetic
/// across runs, while production always gets durable, encrypted-at-rest
/// storage. Internal (not `public`) so it never leaks into the public API —
/// only `@testable import QAudionEngine` test targets can reach it.
protocol VoiceprintBacking: AnyObject {
    func save(contactId: String, template: [Float])
    func load(contactId: String) -> [Float]?
    func delete(contactId: String)
    func listContacts() -> [String]
}

/// Biometric voiceprint template store — Feature A (device-owner Voice-as-Key
/// enrollment, consumed by `VoiceAuthGate`) and Feature B (per-contact
/// call-time voice learning, consumed by `VoiceLearningSession`) both persist
/// through this single store, keyed by `contactId`.
///
/// SECURITY: voiceprint templates are raw biometric material.
///   - Backed by the iOS Keychain with
///     `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — same access-control
///     choice as `KeychainRatchetVault` for the same reason: unreadable while
///     the device is locked, and NEVER `.Always`.
///   - Deliberately NOT synchronizable / iCloud-Keychain-backed — a
///     biometric voiceprint must never leave this device, not even via an
///     encrypted backup restore onto a different device. No
///     `kSecAttrSynchronizable` key is ever set in this file.
///   - There is no upload/export path anywhere in this store or its callers.
///
/// Prior to this fix `VoiceprintStore` was an in-memory-only `[String:
/// [Float]]` dictionary — a template did not survive an app restart even
/// once Feature A/B were fully wired end-to-end. This is a drop-in
/// replacement: identical public API, so no production call site changes.
public final class VoiceprintStore {

    /// Reserved `contactId` for Feature A's device-owner voiceprint
    /// (`VoiceEnrollmentContainer` is the enrollment writer, `VoiceAuthGate`
    /// via `VoiceUnlockController` is the re-auth reader). Never collides
    /// with a real peer/contact id — those are server-issued UUIDs.
    public static let deviceOwnerId = "__qaudion_device_owner__"

    private let backing: VoiceprintBacking

    public init() {
        self.backing = KeychainVoiceprintBacking()
    }

    /// Test-only injection point (see `VoiceprintBacking` doc). Not part of
    /// the public API — reachable only via `@testable import QAudionEngine`.
    init(backing: VoiceprintBacking) {
        self.backing = backing
    }

    public func save(contactId: String, template: [Float]) { backing.save(contactId: contactId, template: template) }
    public func load(contactId: String) -> [Float]? { backing.load(contactId: contactId) }
    public func delete(contactId: String) { backing.delete(contactId: contactId) }
    public func listContacts() -> [String] { backing.listContacts() }
    public func hasTemplate(contactId: String) -> Bool { backing.load(contactId: contactId) != nil }
}

// MARK: - Keychain-backed production storage

private final class KeychainVoiceprintBacking: VoiceprintBacking {
    /// Keychain `kSecAttrService` value. Own namespace, distinct from
    /// `KeychainRatchetVault`/PSK vaults, so a future keychain-dump
    /// migration can target voiceprints independently.
    private static let service = "com.bcrypto.qaudion.voiceprint.v1"

    /// Keychain has no reliable native "list all accounts for a service"
    /// query, so a small explicit index item (JSON array of contactIds) is
    /// maintained alongside the per-contact template items — same "tiny
    /// metadata item beside opaque blobs" shape as this file's sibling
    /// Keychain-backed stores elsewhere in the codebase.
    private static let indexAccount = "__index__"

    private let lock = NSLock()

    func save(contactId: String, template: [Float]) {
        lock.lock(); defer { lock.unlock() }
        Self.writeBlob(account: contactId, blob: Self.encode(template))
        var ids = Self.readIndex()
        if !ids.contains(contactId) {
            ids.append(contactId)
            Self.writeIndex(ids)
        }
    }

    func load(contactId: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let blob = Self.readBlob(account: contactId) else { return nil }
        return Self.decode(blob)
    }

    func delete(contactId: String) {
        lock.lock(); defer { lock.unlock() }
        Self.deleteBlob(account: contactId)
        var ids = Self.readIndex()
        ids.removeAll { $0 == contactId }
        Self.writeIndex(ids)
    }

    func listContacts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Self.readIndex()
    }

    // MARK: - Codec — raw little-endian Float32 vector. No cross-platform
    // wire format needed: templates are opaque, device-local, never parsed
    // by anything other than this same store on this same device.

    private static func encode(_ template: [Float]) -> Data {
        var data = Data(capacity: template.count * MemoryLayout<Float>.size)
        for f in template {
            withUnsafeBytes(of: f) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            for i in 0..<count { result[i] = ptr[i] }
        }
        return result
    }

    private static func readIndex() -> [String] {
        guard let blob = readBlob(account: indexAccount),
              let ids = try? JSONDecoder().decode([String].self, from: blob) else { return [] }
        return ids
    }

    private static func writeIndex(_ ids: [String]) {
        guard let blob = try? JSONEncoder().encode(ids) else { return }
        writeBlob(account: indexAccount, blob: blob)
    }

    // MARK: - Keychain primitives (mirrors `KeychainRatchetVault` exactly)

    private static func readBlob(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if status != errSecSuccess { return nil }
        return item as? Data
    }

    @discardableResult
    private static func writeBlob(account: String, blob: Data) -> Bool {
        let baseAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var addAttrs = baseAttrs
        addAttrs[kSecValueData as String] = blob
        // SECURITY — biometric templates never leave this device and are
        // unreadable while locked: no `.Always`, no synchronizable/iCloud
        // variant anywhere in this file.
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }
        let updateAttrs: [String: Any] = [kSecValueData as String: blob]
        let updateStatus = SecItemUpdate(baseAttrs as CFDictionary, updateAttrs as CFDictionary)
        return updateStatus == errSecSuccess
    }

    private static func deleteBlob(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

// MARK: - In-memory backing (tests only — see `VoiceprintBacking` doc)

final class InMemoryVoiceprintBacking: VoiceprintBacking {
    private let lock = NSLock()
    private var templates: [String: [Float]] = [:]

    func save(contactId: String, template: [Float]) {
        lock.lock(); templates[contactId] = template; lock.unlock()
    }
    func load(contactId: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }; return templates[contactId]
    }
    func delete(contactId: String) {
        lock.lock(); templates.removeValue(forKey: contactId); lock.unlock()
    }
    func listContacts() -> [String] {
        lock.lock(); defer { lock.unlock() }; return Array(templates.keys)
    }
}

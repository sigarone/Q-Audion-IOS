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

    // MARK: - Codec — `MAGIC(4) | version(4) | dim(4) | little-endian Float32
    // vector`. No cross-platform wire format needed (templates are opaque,
    // device-local, never parsed by anything other than this same store on
    // this same device), but a header IS needed: 2026-08-01 CAM++ migration
    // replaced the prior classical LFCC-mean embedding (128-dim) with a
    // 512-dim CAM++ embedding, and a raw unversioned Float32 blob cannot
    // tell those apart — silently feeding a stale 128-dim LFCC vector into
    // CAM++ cosine-similarity code would produce a meaningless score instead
    // of a clear "not enrolled". Same class of gap Android's
    // `VoicePrintVault` v1->v2 migration closed. `decode` returns `nil` (not
    // an empty array) for anything that doesn't match this exact header, so
    // `load`/`hasTemplate` correctly report "no valid template" and the UI
    // re-prompts enrollment rather than silently mis-scoring.
    private static let magic: UInt32 = 0x5150_4156 // "QAVP" packed big-endian-in-source, stored little-endian below
    private static let formatVersion: UInt32 = 2 // 2 == CAM++ 512-dim (2026-08-01); no version 1 header ever existed — pre-migration blobs are unversioned and rejected by decode()
    private static let headerSize = 12 // magic(4) + version(4) + dim(4)

    private static func encode(_ template: [Float]) -> Data {
        var data = Data(capacity: headerSize + template.count * MemoryLayout<Float>.size)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: formatVersion.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(template.count).littleEndian) { data.append(contentsOf: $0) }
        for f in template {
            withUnsafeBytes(of: f) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Returns `nil` for anything that isn't a well-formed, current-version
    /// header (too short, bad magic, wrong version, or a byte count that
    /// doesn't match the declared dim) — including every blob written before
    /// this header existed. Never returns a partially-decoded/garbage vector.
    private static func decode(_ data: Data) -> [Float]? {
        guard data.count >= headerSize else { return nil }
        var readMagic: UInt32 = 0
        var readVersion: UInt32 = 0
        var readDim: UInt32 = 0
        data.withUnsafeBytes { raw in
            readMagic = UInt32(littleEndian: raw.load(fromByteOffset: 0, as: UInt32.self))
            readVersion = UInt32(littleEndian: raw.load(fromByteOffset: 4, as: UInt32.self))
            readDim = UInt32(littleEndian: raw.load(fromByteOffset: 8, as: UInt32.self))
        }
        guard readMagic == magic, readVersion == formatVersion else { return nil }
        let dim = Int(readDim)
        let expectedCount = headerSize + dim * MemoryLayout<Float>.size
        guard dim > 0, data.count == expectedCount else { return nil }
        var result = [Float](repeating: 0, count: dim)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: headerSize)
            let ptr = base.bindMemory(to: Float.self, capacity: dim)
            for i in 0..<dim { result[i] = ptr[i] }
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

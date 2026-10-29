import Foundation
#if canImport(Security)
import Security
#endif

/// What reading a stored template can say. The three answers are not
/// interchangeable, and treating the third as the first is what made the
/// phone learn the same contact's voice again and again.
public enum VoiceprintLookup: Equatable {
    /// Nothing usable is stored for this id: nothing was ever saved, or what
    /// is there is in a layout this version does not use. Learning from
    /// scratch, and writing the result, loses nothing.
    case absent
    /// A well-formed template.
    case present([Float])
    /// The store could not be read (for example the Keychain refused the
    /// read). What it holds is unknown, so the caller must neither learn the
    /// voice again nor write over it: the next read may well succeed.
    case unreadable
}

/// Storage abstraction so `VoiceprintStore` can be exercised in unit tests
/// without touching the real Keychain — mirrors this codebase's
/// `RatchetVault`/`KeychainRatchetVault` split (see
/// `RatchetVault.swift`) for the same reason: tests must stay hermetic
/// across runs, while production always gets durable, encrypted-at-rest
/// storage. Internal (not `public`) so it never leaks into the public API —
/// only `@testable import QAudionEngine` test targets can reach it.
protocol VoiceprintBacking: AnyObject {
    /// `true` only when the template is really stored.
    @discardableResult func save(contactId: String, template: [Float]) -> Bool
    func lookup(contactId: String) -> VoiceprintLookup
    /// `true` when the item is gone afterwards (it may not have existed).
    @discardableResult func delete(contactId: String) -> Bool
    func listContacts() -> [String]
}

extension VoiceprintBacking {
    /// The template, or `nil` for both "absent" and "unreadable". Only for a
    /// caller that does not need the difference.
    func load(contactId: String) -> [Float]? {
        if case .present(let template) = lookup(contactId: contactId) { return template }
        return nil
    }
}

/// Biometric voiceprint template store — Feature A (device-owner Voice-as-Key
/// enrollment, consumed by `VoiceAuthGate`) and Feature B (per-contact
/// call-time voice learning, consumed by `VoiceLearningSession`) both persist
/// through this single store, keyed by `contactId`.
///
/// SECURITY: voiceprint templates are raw biometric material.
///   - Backed by the iOS Keychain with
///     `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: unreadable after a
///     restart until the first unlock, and NEVER `.Always`. It is not
///     `WhenUnlocked` because a call can be answered from the lock screen
///     (CallKit): learning finishes, and the next call reads the template,
///     while the phone is locked. With `WhenUnlocked` both the write and the
///     read failed there, silently, and the contact was learned again.
///   - Deliberately NOT synchronizable / iCloud-Keychain-backed — a
///     biometric voiceprint must never leave this device, not even via an
///     encrypted backup restore onto a different device. No
///     `kSecAttrSynchronizable` key is ever set in this file.
///   - There is no upload/export path anywhere in this store or its callers.
///
/// What it refuses, and what it reports:
///   - It never stores an empty, non-finite or all-zero template
///     (`isUsable`): such a vector would read as "learned" and make every
///     later score meaningless, and it would stop the contact from being
///     learned again.
///   - `save` and `delete` say whether they worked.
///   - `lookup` tells "nothing stored" from "could not read" (see
///     `VoiceprintLookup`), and reports a stored template that is not usable
///     as "nothing stored", so that the contact is learned again.
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

    /// Whether `template` is worth storing: not empty, every value a finite
    /// number, and not all zero.
    public static func isUsable(_ template: [Float]) -> Bool {
        guard !template.isEmpty else { return false }
        var energy: Double = 0
        for value in template {
            guard value.isFinite else { return false }
            energy += Double(value) * Double(value)
        }
        return energy > 1e-12
    }

    /// Stores `template` and returns whether it is stored. An unusable
    /// template is refused and the previous one, if any, is left untouched.
    @discardableResult
    public func save(contactId: String, template: [Float]) -> Bool {
        guard Self.isUsable(template) else { return false }
        return backing.save(contactId: contactId, template: template)
    }

    /// What is stored for `contactId`. A stored template that is not usable
    /// (`isUsable`: empty, not finite or all zero, for example one written by
    /// an earlier build) is `.absent`, not `.present`: it says nothing about
    /// the voice, so the caller learns the contact again and the new template
    /// takes its place.
    public func lookup(contactId: String) -> VoiceprintLookup {
        let result = backing.lookup(contactId: contactId)
        if case .present(let template) = result, !Self.isUsable(template) { return .absent }
        return result
    }

    /// The template, or `nil` when it is absent (an unusable one counts as
    /// absent, see `lookup`) OR unreadable. A caller that decides whether to
    /// learn again must use `lookup` instead.
    public func load(contactId: String) -> [Float]? {
        if case .present(let template) = lookup(contactId: contactId) { return template }
        return nil
    }

    @discardableResult
    public func delete(contactId: String) -> Bool { backing.delete(contactId: contactId) }

    public func listContacts() -> [String] { backing.listContacts() }

    public func hasTemplate(contactId: String) -> Bool { load(contactId: contactId) != nil }
}

// MARK: - Codec

/// `MAGIC(4) | version(4) | dim(4) | little-endian Float32 vector`. No
/// cross-platform wire format needed (templates are opaque, device-local,
/// never parsed by anything other than this same store on this same device),
/// but a header IS needed: 2026-08-01 CAM++ migration replaced the prior
/// classical LFCC-mean embedding (128-dim) with a 512-dim CAM++ embedding,
/// and a raw unversioned Float32 blob cannot tell those apart — silently
/// feeding a stale 128-dim LFCC vector into CAM++ cosine-similarity code
/// would produce a meaningless score instead of a clear "not enrolled". Same
/// class of gap Android's `VoicePrintVault` v1->v2 migration closed. `decode`
/// returns `nil` (not an empty array) for anything that doesn't match this
/// exact header, so a lookup correctly reports "no valid template" and the UI
/// re-prompts enrollment rather than silently mis-scoring.
enum VoiceprintCodec {
    private static let magic: UInt32 = 0x5150_4156 // "QAVP" packed big-endian-in-source, stored little-endian below
    private static let formatVersion: UInt32 = 2 // 2 == CAM++ 512-dim (2026-08-01); no version 1 header ever existed — pre-migration blobs are unversioned and rejected by decode()
    private static let headerSize = 12 // magic(4) + version(4) + dim(4)

    static func encode(_ template: [Float]) -> Data {
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
    static func decode(_ data: Data) -> [Float]? {
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
}

// MARK: - Reading the Keychain

/// How one `SecItemCopyMatching` for a template item becomes a
/// `VoiceprintLookup`. Pure, so the rule that matters — only "not found" and
/// "found but not in the current layout" are absence; every other outcome is
/// an unreadable store — is pinned by a test without a Keychain.
enum VoiceprintKeychainRead {
    static func lookup(status: OSStatus, item: AnyObject?) -> VoiceprintLookup {
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else { return .unreadable }
        guard let data = item as? Data else { return .unreadable }
        if let template = VoiceprintCodec.decode(data) { return .present(template) }
        // Readable bytes in a layout this version does not use. They will
        // never become readable, so there is nothing to protect.
        return .absent
    }

    /// Whether an item that has just been read successfully, and reported
    /// `attribute` as its `kSecAttrAccessible`, is still in the class an
    /// earlier build wrote (`WhenUnlockedThisDeviceOnly`) and so has to move
    /// to `AfterFirstUnlockThisDeviceOnly`. Anything else is left alone:
    /// already moved, a class this codebase never wrote, or no attribute at
    /// all.
    static func needsAccessibilityUpgrade(attribute: Any?) -> Bool {
        KeychainAccessibilityPolicy.accessClass(fromAttribute: attribute) == .whenUnlockedThisDeviceOnly
    }
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

    @discardableResult
    func save(contactId: String, template: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard Self.writeBlob(account: contactId, blob: VoiceprintCodec.encode(template)) else { return false }
        // The index is a convenience list. If it cannot be read it is left
        // alone (writing a one-entry list would drop the others); if it
        // cannot be written the template is still stored and readable.
        if let ids = Self.readIndex(), !ids.contains(contactId) {
            Self.writeIndex(ids + [contactId])
        }
        return true
    }

    func lookup(contactId: String) -> VoiceprintLookup {
        lock.lock(); defer { lock.unlock() }
        let result = Self.copyMatching(account: contactId)
        let read = VoiceprintKeychainRead.lookup(status: result.status, item: result.item)
        if case .present = read { Self.upgradeAccessibilityIfNeeded(account: contactId) }
        return read
    }

    @discardableResult
    func delete(contactId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deleted = Self.deleteBlob(account: contactId)
        if let ids = Self.readIndex(), ids.contains(contactId) {
            Self.writeIndex(ids.filter { $0 != contactId })
        }
        return deleted
    }

    func listContacts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Self.readIndex() ?? []
    }

    // MARK: - Index

    /// `nil` when the index item could not be read; `[]` when there is none
    /// (or it is not a list of ids, which a later write replaces).
    private static func readIndex() -> [String]? {
        let result = copyMatching(account: indexAccount)
        if result.status == errSecItemNotFound { return [] }
        guard result.status == errSecSuccess, let blob = result.item as? Data else { return nil }
        return (try? JSONDecoder().decode([String].self, from: blob)) ?? []
    }

    @discardableResult
    private static func writeIndex(_ ids: [String]) -> Bool {
        guard let blob = try? JSONEncoder().encode(ids) else { return false }
        return writeBlob(account: indexAccount, blob: blob)
    }

    // MARK: - Keychain primitives (mirrors `KeychainRatchetVault` exactly)

    private static func copyMatching(account: String) -> (status: OSStatus, item: AnyObject?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }

    /// `true` only when the item now holds `blob`. Every status is checked:
    /// a refused write (for example before the first unlock after a restart)
    /// must not look like a saved voice.
    private static func writeBlob(account: String, blob: Data) -> Bool {
        let baseAttrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // SECURITY — biometric templates never leave this device and are
        // unreadable until the first unlock after a restart: no `.Always`,
        // no synchronizable/iCloud variant anywhere in this file. After the
        // first unlock they stay readable with the screen locked, because a
        // call can be answered from the lock screen.
        let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var addAttrs = baseAttrs
        addAttrs[kSecValueData as String] = blob
        addAttrs[kSecAttrAccessible as String] = accessible

        let addStatus = SecItemAdd(addAttrs as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }
        // The update also sets the accessibility class, so an item written
        // by an earlier build under `WhenUnlocked` moves to the new class.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: blob,
            kSecAttrAccessible as String: accessible,
        ]
        let updateStatus = SecItemUpdate(baseAttrs as CFDictionary, updateAttrs as CFDictionary)
        return updateStatus == errSecSuccess
    }

    /// An item an earlier build wrote under `WhenUnlockedThisDeviceOnly` can
    /// not be read while the phone is locked, which is how a call answered
    /// from the lock screen learned the same voice again. Once such an item
    /// has been READ successfully it is moved to
    /// `AfterFirstUnlockThisDeviceOnly` with an update of that one attribute:
    /// no delete, no new add, the value is not rewritten. The status is
    /// checked, and a refused update leaves the item exactly as it was (still
    /// readable as before), so nothing is lost and the next successful read
    /// tries again. `print`, not RTLog: RTLog lives in the app target and this
    /// package cannot reach it; the log line carries no contact id.
    private static func upgradeAccessibilityIfNeeded(account: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var attributesQuery = identity
        attributesQuery[kSecReturnAttributes as String] = true
        attributesQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        guard SecItemCopyMatching(attributesQuery as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              VoiceprintKeychainRead.needsAccessibilityUpgrade(
                  attribute: attributes[kSecAttrAccessible as String]) else { return }
        let upgrade: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(identity as CFDictionary, upgrade as CFDictionary)
        if status != errSecSuccess {
            print("[VoiceprintStore] accessibility upgrade refused status=\(status) (item untouched)")
        }
    }

    /// `true` when the item is gone (deleted now, or it was not there).
    private static func deleteBlob(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - In-memory backing (tests only — see `VoiceprintBacking` doc)

final class InMemoryVoiceprintBacking: VoiceprintBacking {
    private let lock = NSLock()
    private var templates: [String: [Float]] = [:]

    /// Test seam: reads report `.unreadable`, like a Keychain that refuses
    /// the read.
    var failReads = false
    /// Test seam: writes and deletes fail and change nothing, like a
    /// Keychain that refuses the write.
    var failWrites = false

    @discardableResult
    func save(contactId: String, template: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failWrites { return false }
        templates[contactId] = template
        return true
    }
    func lookup(contactId: String) -> VoiceprintLookup {
        lock.lock(); defer { lock.unlock() }
        if failReads { return .unreadable }
        if let template = templates[contactId] { return .present(template) }
        return .absent
    }
    @discardableResult
    func delete(contactId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failWrites { return false }
        templates.removeValue(forKey: contactId)
        return true
    }
    func listContacts() -> [String] {
        lock.lock(); defer { lock.unlock() }; return Array(templates.keys)
    }
}

import Foundation
import CryptoKit
import Security
import UIKit
import QAudionEngine

// MARK: - CallRecord

/// A single persisted call record. Codable for encrypted file storage.
/// Sendable-safe: all stored properties are value types.
public struct CallRecord: Codable, Identifiable, Sendable {
    public let id: String               // UUID string minted at beginCall
    public let peerUserId: String
    public let peerDisplayName: String  // resolved at record time from ContactsStore / wire
    public let direction: Direction
    public let startedAt: Date
    public var endedAt: Date?           // nil while call is ongoing
    public let isVideo: Bool
    public let peerExtension: Int?      // PBX short number if known
    /// Post-v5: one of the allow-listed `CallCloseReason` tokens when the call closed over a failed
    /// handshake / identity check, else nil. Shown as a label in the call history. Optional, so records
    /// saved before this field existed decode with nil.
    public var closeReason: String? = nil

    public enum Direction: String, Codable, Sendable {
        case incoming, outgoing, missed
    }

    /// Positive call duration in whole seconds. nil for missed or still-ongoing calls.
    public var durationSeconds: Int? {
        guard let e = endedAt else { return nil }
        let d = Int(e.timeIntervalSince(startedAt))
        return d > 0 ? d : nil
    }
}


// MARK: - Key provider seam

/// Outcome of asking the key store for the call-history key. The three cases are deliberately
/// distinct: only `.notFound` is evidence that the key is gone for good. `.unavailable` means the
/// item may well exist but cannot be read right now (device locked: `errSecInteractionNotAllowed`,
/// -25308; entitlement missing: -34018; any other OSStatus), and a caller must NOT mint a
/// replacement key in that case, because the replacement would not open the file the real key sealed.
enum CallHistoryKeyLookup {
    case found(SymmetricKey)
    case notFound
    case unavailable(OSStatus)
}

/// Outcome of asking the key store to create the call-history key. `.created` and `.existing` are
/// deliberately distinct: only `.created` proves that no key existed before, so only then is a file
/// already on disk known to be sealed under a key that is gone. `.existing` is a key somebody stored
/// between our read and our add (or that could not be read a moment ago): it may well open the file.
enum CallHistoryKeyCreation {
    /// A new key was stored just now.
    case created(SymmetricKey)
    /// The Keychain already held a key (duplicate item): the stored one, never ours.
    case existing(SymmetricKey)
    /// Nothing was created and nothing can be assumed about the stored key.
    case unavailable(OSStatus)
}

/// Injected into `PersistentCallRecordStore` so the locked / not-found / ok paths are unit-testable
/// without a Keychain (a simulator test bundle has none).
protocol CallHistoryKeyProviding {
    /// Read the existing key. Never creates one.
    func readKey() -> CallHistoryKeyLookup
    /// Create and persist a fresh key. Returns `.created` only when the key is really stored, so the
    /// caller never seals data under a key that would be lost at the next launch.
    func createKey() -> CallHistoryKeyCreation
    /// Remove the key (a wipe of the account that is leaving, so a new account starts with a new
    /// key). `errSecSuccess` when no key is stored afterwards, which includes "there was none";
    /// otherwise the status that stopped the removal.
    func deleteKey() -> OSStatus
}

// MARK: - Keychain provider (production)

struct KeychainCallHistoryKeyProvider: CallHistoryKeyProviding {
    private static let service = "com.qaudion.callhistory"
    private static let account = "aes-key"

    func readKey() -> CallHistoryKeyLookup {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      Self.service,
            kSecAttrAccount:      Self.account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            if let data = result as? Data { return .found(SymmetricKey(data: data)) }
            return .unavailable(errSecDecode)
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable(status)
        }
    }

    func createKey() -> CallHistoryKeyCreation {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let attrs: [CFString: Any] = [
            kSecClass:                   kSecClassGenericPassword,
            kSecAttrService:             Self.service,
            kSecAttrAccount:             Self.account,
            kSecAttrAccessible:          kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData:               keyData
        ]
        // Add only, never delete-then-add: a delete that succeeded followed by an add that failed
        // would destroy the key of a file that is still on disk.
        let status = SecItemAdd(attrs as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .created(key)
        case errSecDuplicateItem:
            // Someone created it between our read and this add (or it exists but could not be read
            // a moment ago): use the stored one, never ours.
            switch readKey() {
            case .found(let stored): return .existing(stored)
            case .notFound: return .unavailable(errSecItemNotFound)
            case .unavailable(let readStatus): return .unavailable(readStatus)
            }
        default:
            return .unavailable(status)
        }
    }

    func deleteKey() -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

// MARK: - PersistentCallRecordStore

/// AES-GCM encrypted file-backed store for call history records.
///
/// Storage layout:
///   - Encrypted file: Application Support/qaudion/call_history.enc
///   - Previous version (one backup, refreshed before every automatic overwrite): call_history.enc.bak
///   - A file that cannot be opened with the key we hold (key lost, corrupt): call_history.enc.unreadable
///   - File protection: .completeUnlessOpen
///   - Encryption: CryptoKit AES.GCM (256-bit key)
///   - Key storage: iOS Keychain, accessibility .whenUnlockedThisDeviceOnly
///
/// No-silent-wipe rules (reports 52e53e9f, 6ea3601a: history gone after a launch where the
/// key or the file was not readable yet):
///   - A key that exists but cannot be read now (device locked, background launch from a VoIP
///     push) is never replaced by a new one. The store goes into a "deferred" state: records live in
///     memory only, the file is not touched, and the load is retried when protected data becomes
///     available (and before every mutation). The retry merges what the file holds with what was
///     recorded in the meantime.
///   - An existing file is never overwritten by a list built from nothing. A file that the (readable)
///     key cannot open is moved aside to `.unreadable`, not rewritten in place.
///   - Before every automatic overwrite (a call started or ended, a merge) the previous file is kept
///     as `.bak`.
///   - A deletion by the user is never undone by a copy. When the user deletes a record or clears the
///     history, no file that still holds the removed records may outlive the write that replaces
///     them: `.bak` (and a leftover `.bak.tmp`) are removed, and "clear all" removes `.unreadable` too
///     (a file moved aside because its content did not decode can still be opened with the key). The
///     old file is not copied into a backup while it still holds removed records, and the save that
///     finally replaces it (after a deferral, or a failed write) does the removal. The backup is then
///     rebuilt by the next automatic save.
///   - A wipe of the account that leaves the device (`wipeAccountHistory`, run by
///     `LocalCryptoWipe.wipeAll()` on logout, remote wipe and account deletion) removes all of it:
///     the in-memory list, the file and its copies, the legacy UserDefaults value and the Keychain
///     key, so the next account starts empty and with a new key. It wins over a deferred load: what
///     could not be removed while the device was locked is discarded by the load that follows.
///   - What the user deleted (or cleared, or what a wipe could not remove) stays marked as "not yet
///     on disk" until a write has really replaced the file, so no load in between can bring it back.
///
/// CONSTRAINT (CLAUDE.md §16): this class MUST NOT take AppState as a
/// parameter anywhere. All integration points must pass primitive values
/// (String, Bool, Int) or closures.
@MainActor
public final class PersistentCallRecordStore: ObservableObject {
    public static let shared = PersistentCallRecordStore()

    @Published public private(set) var records: [CallRecord] = []

    /// Why persistence is currently deferred (history kept in memory, file untouched). nil = normal.
    enum DeferReason: Equatable {
        /// The Keychain key could not be read or created now. Carries the OSStatus.
        case keyUnavailable(OSStatus)
        /// The encrypted file exists but could not be read or moved aside now. Carries the NSError code.
        case fileUnreadable(Int)
    }

    private(set) var deferredReason: DeferReason?
    var isPersistenceDeferred: Bool { deferredReason != nil }

    // Legacy UserDefaults key — used only during one-time migration.
    private static let legacyStorageKey = "qaudion.callHistory.v2"
    private static let maxRecords = 200
    private static let logTag = "CallHistory"

    private let keyProvider: CallHistoryKeyProviding
    private let fileURL: URL
    private let defaults: UserDefaults
    // Deletions that are not on disk yet: set BEFORE the save that should write them, cleared only
    // after a write has really replaced the file. Until then the file may still hold the removed
    // records, so every load (a deferred one after unlock, or any later one) replays them over what
    // it reads. They used to be cleared before the write, and set only by a store that was already
    // deferred.
    private var pendingDeletedIds = Set<String>()
    private var pendingClearAll = false
    // The user deleted records (or everything) and the file on disk may still hold them: the save
    // that replaces it removes the copies of the old file, and until then the file is not copied
    // into the backup. Cleared only once the copies are really gone, so a failed write or a failed
    // removal is retried by the next save.
    private var removedByUserNotYetOnDisk = false
    // Same, for "clear all": the quarantined file goes too.
    private var clearedByUserNotYetOnDisk = false

    public convenience init() {
        self.init(keyProvider: KeychainCallHistoryKeyProvider(),
                  fileURL: Self.defaultFileURL(),
                  notificationCenter: .default,
                  retryNotifications: Self.defaultRetryNotifications)
    }

    init(keyProvider: CallHistoryKeyProviding,
         fileURL: URL,
         notificationCenter: NotificationCenter,
         retryNotifications: [Notification.Name],
         defaults: UserDefaults = .standard) {
        self.keyProvider = keyProvider
        self.fileURL = fileURL
        self.defaults = defaults
        attemptLoad()
        migrateFromUserDefaultsIfNeeded()
        // Retry when the device unlocks or the app comes to the foreground. The observer holds the
        // store weakly; the shared instance lives for the whole process.
        for name in retryNotifications {
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let store = self else { return }
                    store.retryDeferredLoad()
                }
            }
        }
    }

    private static var defaultRetryNotifications: [Notification.Name] {
        [UIApplication.protectedDataDidBecomeAvailableNotification,
         UIApplication.didBecomeActiveNotification]
    }

    // MARK: - File locations

    private static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("qaudion", isDirectory: true)
        // Create directory if needed; ignore errors (idempotent).
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )
        return dir.appendingPathComponent("call_history.enc")
    }

    private var backupURL: URL { URL(fileURLWithPath: fileURL.path + ".bak") }
    private var backupTmpURL: URL { URL(fileURLWithPath: backupURL.path + ".tmp") }
    private var quarantineURL: URL { URL(fileURLWithPath: fileURL.path + ".unreadable") }

    // MARK: - Key

    private enum KeyOutcome {
        case key(SymmetricKey)
        case unavailable(OSStatus)
    }

    /// Returns the key to use, creating one only when the Keychain says, authoritatively, that none
    /// exists. A file sealed under a key that no longer exists can never be opened again, so once a
    /// NEW key really exists it is moved aside and the new key starts a new file. The file is moved
    /// only after the key was created, and only if the key is new: a creation that failed, or that
    /// found a key stored in the meantime (duplicate item), leaves the file where it is, because
    /// that key may well open it. Any other failure to read the key is "not now", never "gone".
    private func obtainKey() -> KeyOutcome {
        switch keyProvider.readKey() {
        case .found(let key):
            return .key(key)
        case .unavailable(let status):
            return .unavailable(status)
        case .notFound:
            switch keyProvider.createKey() {
            case .created(let key):
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    RTLog.warn(Self.logTag, "key not found, existing history file cannot be opened")
                    // The new key is stored already: if the file cannot be moved now, the retry reads
                    // that key, fails to open the file with it and moves it then.
                    if quarantineFile() != nil { return .unavailable(errSecIO) }
                }
                return .key(key)
            case .existing(let key):
                return .key(key)
            case .unavailable(let status):
                return .unavailable(status)
            }
        }
    }

    // MARK: - Private persistence

    private func enterDeferred(_ reason: DeferReason) {
        if deferredReason != reason {
            switch reason {
            case .keyUnavailable(let status):
                RTLog.warn(Self.logTag, "key unavailable status=\(status), history kept in memory, file untouched")
            case .fileUnreadable(let code):
                RTLog.warn(Self.logTag, "history file unreadable code=\(code), history kept in memory, file untouched")
            }
        }
        deferredReason = reason
    }

    /// Reads the file and merges it with whatever was recorded in memory while deferred.
    /// Called at init, on unlock / foreground, and before every mutation while deferred.
    private func attemptLoad() {
        let key: SymmetricKey
        switch obtainKey() {
        case .unavailable(let status):
            enterDeferred(.keyUnavailable(status))
            return
        case .key(let k):
            key = k
        }

        var stored: [CallRecord] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            let combined: Data
            do {
                combined = try Data(contentsOf: fileURL)
            } catch {
                let code = (error as NSError).code
                if (error as? CocoaError)?.code != .fileReadNoSuchFile {
                    // Typically data protection while the device is locked. Do not start empty.
                    enterDeferred(.fileUnreadable(code))
                    return
                }
                finishLoad(stored: [])
                return
            }
            do {
                let sealedBox = try AES.GCM.SealedBox(combined: combined)
                let plaintext = try AES.GCM.open(sealedBox, using: key)
                stored = try JSONDecoder().decode([CallRecord].self, from: plaintext)
            } catch {
                // The key is readable and authoritative, and it does not open this file (written
                // under a key we no longer have, truncated, or a schema we cannot read). It will not
                // become readable by waiting, but it must not be overwritten either: keep it aside.
                RTLog.warn(Self.logTag, "history file does not open with the current key, kept aside")
                if let code = quarantineFile() {
                    enterDeferred(.fileUnreadable(code))
                    return
                }
            }
        }
        finishLoad(stored: stored)
    }

    private func finishLoad(stored: [CallRecord]) {
        let wasDeferred = deferredReason != nil
        if wasDeferred { RTLog.info(Self.logTag, "persistence resumed") }
        deferredReason = nil
        guard wasDeferred else {
            records = Array(stored.prefix(Self.maxRecords))
            return
        }
        var merged: [CallRecord] = pendingClearAll
            ? []
            : stored.filter { !pendingDeletedIds.contains($0.id) }
        for memory in records {
            if let idx = merged.firstIndex(where: { $0.id == memory.id }) {
                merged[idx] = memory
            } else {
                merged.append(memory)
            }
        }
        merged.sort { $0.startedAt > $1.startedAt }
        records = merged
        // The pending deletions are cleared by `save()` once the write has landed, not before: a
        // failed write leaves the file as it was, and the next load must replay them again.
        save()
    }

    func retryDeferredLoad() {
        guard deferredReason != nil else { return }
        attemptLoad()
        migrateFromUserDefaultsIfNeeded()
    }

    /// Moves the history file to `.unreadable` (one copy, the latest). Returns nil on success, or
    /// the error code when the file could not be moved, in which case it is still in place.
    private func quarantineFile() -> Int? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        do {
            if fm.fileExists(atPath: quarantineURL.path) { try fm.removeItem(at: quarantineURL) }
            try fm.moveItem(at: fileURL, to: quarantineURL)
            return nil
        } catch {
            return (error as NSError).code
        }
    }

    /// Keeps the file about to be overwritten as `.bak` (one backup). A failed backup is logged and
    /// does not stop the save: the history of the call that just ended matters more.
    private func backUpCurrentFile() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let tmp = backupTmpURL
        do {
            if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
            try fm.copyItem(at: fileURL, to: tmp)
            if fm.fileExists(atPath: backupURL.path) {
                _ = try fm.replaceItemAt(backupURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: backupURL)
            }
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                  ofItemAtPath: backupURL.path)
        } catch {
            RTLog.warn(Self.logTag, "backup failed code=\((error as NSError).code)")
        }
    }

    /// True when nothing is left at `url` afterwards (it was absent, or it has been removed).
    private func removeFileIfPresent(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        do {
            try fm.removeItem(at: url)
            return true
        } catch {
            RTLog.warn(Self.logTag, "could not remove \(url.lastPathComponent) code=\((error as NSError).code)")
            return false
        }
    }

    /// Removes every copy of the old history file that the user's deletion must not leave behind:
    /// the backup and its leftover temp file, and for "clear all" the quarantined file as well (it
    /// is unreadable when the key was lost, but a file moved aside only because its content did not
    /// decode still opens with the key). Returns true when all of them are gone.
    private func removeCopiesOfRemovedHistory() -> Bool {
        var allGone = removeFileIfPresent(at: backupURL)
        allGone = removeFileIfPresent(at: backupTmpURL) && allGone
        if clearedByUserNotYetOnDisk {
            allGone = removeFileIfPresent(at: quarantineURL) && allGone
        }
        return allGone
    }

    @discardableResult
    private func save() -> Bool {
        let capped = Array(records.prefix(Self.maxRecords))
        records = capped
        // Deferred: the file may hold history we have not read. Keep everything in memory.
        guard deferredReason == nil else { return false }
        guard let plaintext = try? JSONEncoder().encode(capped) else { return false }
        let key: SymmetricKey
        switch obtainKey() {
        case .unavailable(let status):
            // E.g. a call ended on the lock screen. The records stay in memory and are merged with
            // the file on the next successful load.
            enterDeferred(.keyUnavailable(status))
            return false
        case .key(let k):
            key = k
        }
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else { return false }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            // The file about to be replaced becomes the single backup, unless it still holds records
            // the user has deleted: then it is not copied anywhere, and the copies that exist are
            // removed BEFORE the write, so an interrupted process cannot leave them behind.
            let copiesRemoved = removedByUserNotYetOnDisk ? removeCopiesOfRemovedHistory() : false
            if !removedByUserNotYetOnDisk { backUpCurrentFile() }
            try combined.write(to: fileURL, options: .atomic)
            if copiesRemoved {
                removedByUserNotYetOnDisk = false
                clearedByUserNotYetOnDisk = false
            }
            // Apply file protection so the OS encrypts at rest when device is locked.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: fileURL.path
            )
            // The file now holds `records`, which carries none of the deleted ones: nothing is
            // pending any more.
            pendingDeletedIds.removeAll()
            pendingClearAll = false
            return true
        } catch {
            RTLog.warn(Self.logTag, "failed to save encrypted file code=\((error as NSError).code)")
            return false
        }
    }

    // MARK: - Migration from UserDefaults

    /// One-time import of the pre-file UserDefaults format. Runs only when persistence is working,
    /// merges instead of overwriting the file, and clears the legacy value only after it has been
    /// written, so a locked or failing store never loses it.
    private func migrateFromUserDefaultsIfNeeded() {
        guard deferredReason == nil else { return }
        guard let legacyData = defaults.data(forKey: Self.legacyStorageKey) else { return }
        let migrated = (try? JSONDecoder().decode([CallRecord].self, from: legacyData)) ?? []
        var merged = records
        // What the user removed (and that is not on disk yet) is not imported back.
        for legacy in migrated where !pendingClearAll
            && !pendingDeletedIds.contains(legacy.id)
            && !merged.contains(where: { $0.id == legacy.id }) {
            merged.append(legacy)
        }
        merged.sort { $0.startedAt > $1.startedAt }
        records = merged
        guard save() else { return }
        defaults.removeObject(forKey: Self.legacyStorageKey)
        RTLog.info(Self.logTag, "migrated legacy UserDefaults records to encrypted file")
    }

    // MARK: - Public API

    /// Register a call that is starting. Call from the outgoing or incoming
    /// call setup path. Parameters are all primitives — no AppState reference.
    ///
    /// - Parameters:
    ///   - id: The UUID string that also tracks this call in CallKit / engine.
    ///   - peerUserId: BCrypto userId of the remote peer.
    ///   - peerDisplayName: Human-readable display name resolved at call time.
    ///   - direction: `.incoming`, `.outgoing`, or `.missed`.
    ///   - isVideo: Whether the call was started as a video call.
    ///   - peerExtension: Optional PBX short number if known.
    public func beginCall(
        id: String,
        peerUserId: String,
        peerDisplayName: String,
        direction: CallRecord.Direction,
        isVideo: Bool,
        peerExtension: Int? = nil
    ) {
        retryDeferredLoad()
        // Deduplicate: if the same callId was already registered (e.g.
        // double-tap guard fired too late) just return without inserting a duplicate.
        if records.firstIndex(where: { $0.id == id }) != nil { return }
        let record = CallRecord(
            id: id,
            peerUserId: peerUserId,
            peerDisplayName: peerDisplayName,
            direction: direction,
            startedAt: Date(),
            endedAt: nil,
            isVideo: isVideo,
            peerExtension: peerExtension
        )
        records.insert(record, at: 0)
        save()
    }

    /// Mark a call as ended (sets `endedAt` to now). `closeReason` is stored only when it is one of the
    /// allow-listed `CallCloseReason` tokens, never a free-form string.
    /// Call from `AppState.endCall()`.
    public func endCall(id: String, closeReason: String? = nil) {
        retryDeferredLoad()
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[idx]
        // Only set endedAt once — idempotent on double endCall.
        guard old.endedAt == nil else { return }
        let updated = CallRecord(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            direction: old.direction,
            startedAt: old.startedAt,
            endedAt: Date(),
            isVideo: old.isVideo,
            peerExtension: old.peerExtension,
            closeReason: CallCloseReason.accepted(closeReason)?.rawValue
        )
        records[idx] = updated
        save()
    }

    /// Transition an in-progress record to `.missed` direction.
    /// Call when an incoming call is rejected or times out before being answered.
    public func markMissed(id: String) {
        retryDeferredLoad()
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[idx]
        let updated = CallRecord(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            direction: .missed,
            startedAt: old.startedAt,
            endedAt: Date(),
            isVideo: old.isVideo,
            peerExtension: old.peerExtension
        )
        records[idx] = updated
        save()
    }

    /// Remove a single record by id.
    public func deleteRecord(_ id: String) {
        retryDeferredLoad()
        records.removeAll { $0.id == id }
        // The file on disk still holds the record until a save replaces it: that save must not copy
        // it into the backup, and it removes the copies that exist.
        removedByUserNotYetOnDisk = true
        // Marked BEFORE the save, and cleared by the save only once the write has landed: the save
        // can find the key unreadable (deferred) or fail to write, and in both cases the file still
        // holds the record, which a later load must not bring back.
        pendingDeletedIds.insert(id)
        save()
    }

    /// Wipe all records, and with them every copy of the old file (backup, quarantined file).
    public func clearAll() {
        retryDeferredLoad()
        records.removeAll()
        removedByUserNotYetOnDisk = true
        clearedByUserNotYetOnDisk = true
        // Same as `deleteRecord`: pending until a write has replaced the file.
        pendingClearAll = true
        save()
    }

    /// Removes the call history of the account that is leaving the device, so the next account on it
    /// starts empty: the in-memory list, the encrypted file and every copy of it (`.bak`, `.bak.tmp`,
    /// `.unreadable`), the legacy UserDefaults value and the Keychain key (the next account gets a new
    /// key). Run by `LocalCryptoWipe.wipeAll()` for logout, remote wipe and account deletion.
    ///
    /// The wipe wins over a deferred load. While the device is locked the file may not be removable
    /// (and the key not deletable): what survives is marked as not yet on disk, so the load that
    /// follows the unlock discards what it reads from it instead of bringing the old history back, and
    /// the save after that removes the copies. Best effort and never throws: a step that fails is
    /// logged and the others still run.
    public func wipeAccountHistory() {
        records = []
        // Edits that were waiting for the disk concern history that is gone now.
        pendingDeletedIds.removeAll()
        // Files first, key last: a key deleted while a file survives would leave an undecryptable
        // file, while a file removed under a surviving key leaves nothing readable.
        var filesGone = removeFileIfPresent(at: fileURL)
        filesGone = removeFileIfPresent(at: backupURL) && filesGone
        filesGone = removeFileIfPresent(at: backupTmpURL) && filesGone
        filesGone = removeFileIfPresent(at: quarantineURL) && filesGone
        defaults.removeObject(forKey: Self.legacyStorageKey)
        let keyStatus = keyProvider.deleteKey()
        if keyStatus != errSecSuccess {
            RTLog.warn(Self.logTag, "wipe: key not deleted status=\(keyStatus)")
        }
        pendingClearAll = !filesGone
        removedByUserNotYetOnDisk = !filesGone
        clearedByUserNotYetOnDisk = !filesGone
        RTLog.info(Self.logTag, "history wiped filesGone=\(filesGone) keyGone=\(keyStatus == errSecSuccess)")
    }

    // MARK: - Display name helper

    /// Resolve a display name for a peer userId. W-EXTPREFIX consolidation
    /// (2026-07-29): this used to be an independent copy of the resolution
    /// chain with NO placeholder-awareness at all (a stale "Phone #100"
    /// cached in `nameByUserId` or arriving as `wireDisplay` rendered
    /// verbatim). Now a thin adapter over the single canonical
    /// `DisplayName.forUser` — `nameByUserId[userId]`, when present, is
    /// wrapped as a one-entry rubrica snapshot so it flows through the
    /// SAME rubrica-then-server-then-extension-then-fallback priority
    /// every other call site uses, instead of this function keeping its
    /// own parallel order (in practice every live caller already passes
    /// `wireDisplay: nil`, so this is not an observable behaviour change
    /// for wire-vs-rubrica precedence today).
    ///
    /// Static so callers don't need an instance reference and the logic
    /// stays unit-testable without touching persistence.
    public static func resolveDisplayName(
        userId: String,
        wireDisplay: String?,
        nameByUserId: [String: String]
    ) -> String {
        var contacts: [ContactsStore.StoredContact] = []
        if let name = nameByUserId[userId], !name.isEmpty {
            contacts = [ContactsStore.StoredContact(
                userId: userId, displayName: name, phoneHash: "",
                avatarUrl: nil as URL?, lastSeen: nil as Date?, isVerified: false)]
        }
        return DisplayName.forUser(userId, serverDisplay: wireDisplay, contacts: contacts)
    }
}

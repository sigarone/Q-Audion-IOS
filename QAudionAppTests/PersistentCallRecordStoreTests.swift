import XCTest
import CryptoKit
import Security
@testable import QAudionApp

/// Reports 52e53e9f and 6ea3601a: the call history was wiped silently. The store hit an unreadable
/// Keychain key (device locked, background launch) or an unreadable file, started with an empty list
/// and the next save overwrote the file; the old code also minted a NEW key whenever the read failed.
///
/// These tests inject the key provider, so no Keychain is needed: "locked" is a provider that
/// answers `.unavailable(errSecInteractionNotAllowed)` while holding the key, "not found" is a
/// provider with no key, "ok" is a provider that returns it.
///
/// Later rounds (all in this class): a user deletion leaves no copy; the account that leaves the
/// device takes its call history with it (wipe, also while the device is locked); pending deletions
/// mean "not on disk yet"; a file is moved aside only for a key that was really created.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing`
/// list of `.github/workflows/ios-app-tests.yml`.
final class PersistentCallRecordStoreTests: XCTestCase {

    // MARK: - Fakes and helpers

    /// A key store that behaves like the Keychain does for this item. `locked` means the item exists
    /// but cannot be read now (nor deleted). `createKey()` never replaces an existing key: it answers
    /// `.existing`, like the duplicate-item result of the real add.
    final class FakeKeyProvider: CallHistoryKeyProviding {
        var key: SymmetricKey?
        var lockedStatus: OSStatus?
        /// The item exists but a read does not see it: the race after which the add that follows
        /// answers "duplicate".
        var readHidesKey = false
        /// Makes `createKey()` fail with this status.
        var createStatus: OSStatus?
        private(set) var createCalls = 0
        private(set) var deleteCalls = 0

        init(key: SymmetricKey? = nil) { self.key = key }

        func readKey() -> CallHistoryKeyLookup {
            if let status = lockedStatus { return .unavailable(status) }
            if readHidesKey { return .notFound }
            if let key = key { return .found(key) }
            return .notFound
        }

        func createKey() -> CallHistoryKeyCreation {
            createCalls += 1
            if let status = lockedStatus { return .unavailable(status) }
            if let status = createStatus { return .unavailable(status) }
            if let key = key { return .existing(key) }
            let fresh = SymmetricKey(size: .bits256)
            key = fresh
            return .created(fresh)
        }

        func deleteKey() -> OSStatus {
            deleteCalls += 1
            if let status = lockedStatus { return status }
            key = nil
            return errSecSuccess
        }
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("callhistory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            // A test may leave a file or the directory unreadable or unwritable on purpose.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for name in files {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent(name).path)
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    /// A private defaults suite, so that no test reads or removes the app's real legacy value.
    private func makeDefaults() -> UserDefaults {
        let suite = "callhistory-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    private func makeStore(
        _ provider: FakeKeyProvider,
        at url: URL,
        center: NotificationCenter = NotificationCenter(),
        retryOn names: [Notification.Name] = [],
        defaults: UserDefaults? = nil
    ) -> PersistentCallRecordStore {
        PersistentCallRecordStore(
            keyProvider: provider, fileURL: url, notificationCenter: center, retryNotifications: names,
            defaults: defaults ?? makeDefaults())
    }

    private func setMode(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func bytes(of key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func readRecords(at url: URL, key: SymmetricKey) throws -> [CallRecord] {
        let combined = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([CallRecord].self, from: plaintext)
    }

    @MainActor
    private func begin(_ store: PersistentCallRecordStore, _ id: String) {
        store.beginCall(id: id, peerUserId: "peer-\(id)", peerDisplayName: "Peer \(id)",
                        direction: .outgoing, isVideo: false)
        // Distinct startedAt values keep the newest-first ordering deterministic.
        Thread.sleep(forTimeInterval: 0.01)
    }

    private func backupURL(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".bak") }
    private func unreadableURL(_ url: URL) -> URL { URL(fileURLWithPath: url.path + ".unreadable") }

    /// Names of every other file in the directory of the live history file.
    private func siblingNames(of live: URL) -> [String] {
        let dir = live.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != live.lastPathComponent }
            .sorted()
    }

    /// The copies of the live file: the backup, its temp file, the quarantined file.
    private func copyNames(of live: URL) -> [String] {
        siblingNames(of: live).filter { $0.hasPrefix(live.lastPathComponent + ".") }
    }

    /// Call ids that can still be read, with `key`, from any file next to the live history file.
    /// This is what a deletion by the user must leave empty.
    private func idsReadableOutsideTheLiveFile(_ live: URL, key: SymmetricKey) -> Set<String> {
        let dir = live.deletingLastPathComponent()
        var ids = Set<String>()
        for name in siblingNames(of: live) {
            if let records = try? readRecords(at: dir.appendingPathComponent(name), key: key) {
                ids.formUnion(records.map(\.id))
            }
        }
        return ids
    }

    /// A file with two ended calls ("c1", "c2"), written under a real key, and the provider holding it.
    @MainActor
    private func seededFile(in dir: URL) throws -> (url: URL, provider: FakeKeyProvider, bytes: Data) {
        let url = dir.appendingPathComponent("call_history.enc")
        let provider = FakeKeyProvider()
        let store = makeStore(provider, at: url)
        begin(store, "c1")
        store.endCall(id: "c1")
        begin(store, "c2")
        store.endCall(id: "c2")
        XCTAssertFalse(store.isPersistenceDeferred)
        return (url, provider, try Data(contentsOf: url))
    }

    // MARK: - Locked key: the reported failure

    @MainActor
    func test_lockedKey_atLaunch_leavesFileUntouched_andMintsNoKey() throws {
        let dir = try makeDirectory()
        let (url, provider, bytesBefore) = try seededFile(in: dir)
        let createsBefore = provider.createCalls
        let backupBefore = try Data(contentsOf: backupURL(url))   // left by the seeding saves
        provider.lockedStatus = errSecInteractionNotAllowed

        let store = makeStore(provider, at: url)
        XCTAssertTrue(store.isPersistenceDeferred)
        XCTAssertEqual(store.deferredReason, .keyUnavailable(errSecInteractionNotAllowed))
        XCTAssertTrue(store.records.isEmpty)

        // A call recorded while locked is kept in memory and must not touch the file.
        begin(store, "c3")
        XCTAssertEqual(store.records.map(\.id), ["c3"])
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore, "the file must not be overwritten while the key is unreadable")
        XCTAssertEqual(provider.createCalls, createsBefore, "no new key may be minted while the real one is only unreadable")
        XCTAssertEqual(try Data(contentsOf: backupURL(url)), backupBefore, "the backup is not rotated either")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadableURL(url).path))
    }

    @MainActor
    func test_afterUnlock_historyComesBack_andMergesTheCallRecordedWhileLocked() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let realKey = try XCTUnwrap(provider.key)
        provider.lockedStatus = errSecInteractionNotAllowed
        let store = makeStore(provider, at: url)
        begin(store, "c3")

        provider.lockedStatus = nil
        store.retryDeferredLoad()

        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(store.records.map(\.id), ["c3", "c2", "c1"])
        let onDisk = try readRecords(at: url, key: realKey)
        XCTAssertEqual(onDisk.map(\.id), ["c3", "c2", "c1"], "the merged list is written back under the original key")
    }

    @MainActor
    func test_mutationRetriesTheLoad_withoutAnyNotification() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        provider.lockedStatus = errSecInteractionNotAllowed
        let store = makeStore(provider, at: url)
        XCTAssertTrue(store.isPersistenceDeferred)

        provider.lockedStatus = nil
        begin(store, "c3")

        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(store.records.map(\.id), ["c3", "c2", "c1"])
    }

    @MainActor
    func test_protectedDataNotification_triggersTheRetry() async throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        provider.lockedStatus = errSecInteractionNotAllowed
        let center = NotificationCenter()
        let unlocked = Notification.Name("test.protectedDataDidBecomeAvailable")
        let store = makeStore(provider, at: url, center: center, retryOn: [unlocked])
        XCTAssertTrue(store.isPersistenceDeferred)

        provider.lockedStatus = nil
        center.post(name: unlocked, object: nil)
        for _ in 0..<100 where store.isPersistenceDeferred {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(store.records.map(\.id), ["c2", "c1"])
    }

    @MainActor
    func test_keyLockedMidSession_keepsFile_thenPersistsAfterUnlock() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("call_history.enc")
        let provider = FakeKeyProvider()
        let store = makeStore(provider, at: url)
        begin(store, "c1")
        let bytesWhileOpen = try Data(contentsOf: url)

        // The call ends on the lock screen: the key cannot be read for the save.
        provider.lockedStatus = errSecInteractionNotAllowed
        store.endCall(id: "c1")
        XCTAssertTrue(store.isPersistenceDeferred)
        XCTAssertNotNil(store.records.first?.endedAt, "the in-memory record is updated")
        XCTAssertEqual(try Data(contentsOf: url), bytesWhileOpen, "the file is left as it was")

        provider.lockedStatus = nil
        store.retryDeferredLoad()
        XCTAssertFalse(store.isPersistenceDeferred)
        let onDisk = try readRecords(at: url, key: try XCTUnwrap(provider.key))
        XCTAssertEqual(onDisk.map(\.id), ["c1"])
        XCTAssertNotNil(onDisk.first?.endedAt)
    }

    @MainActor
    func test_deleteAndClearWhileDeferred_areReplayedOverTheFile() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let realKey = try XCTUnwrap(provider.key)

        provider.lockedStatus = errSecInteractionNotAllowed
        let store = makeStore(provider, at: url)
        store.deleteRecord("c1")
        provider.lockedStatus = nil
        store.retryDeferredLoad()
        XCTAssertEqual(try readRecords(at: url, key: realKey).map(\.id), ["c2"])

        provider.lockedStatus = errSecInteractionNotAllowed
        store.clearAll()
        XCTAssertTrue(store.isPersistenceDeferred)
        provider.lockedStatus = nil
        store.retryDeferredLoad()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try readRecords(at: url, key: realKey).isEmpty)
    }

    @MainActor
    func test_otherKeychainStatuses_areAlsoTreatedAsNotNow() throws {
        let dir = try makeDirectory()
        let (url, provider, bytesBefore) = try seededFile(in: dir)
        provider.lockedStatus = errSecMissingEntitlement
        let store = makeStore(provider, at: url)
        XCTAssertEqual(store.deferredReason, .keyUnavailable(errSecMissingEntitlement))
        begin(store, "c3")
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    // MARK: - Unreadable file

    @MainActor
    func test_unreadableFile_isNotOverwritten_andLoadsAgainOnceReadable() throws {
        try XCTSkipIf(geteuid() == 0, "permission bits do not stop root")
        let dir = try makeDirectory()
        let (url, provider, bytesBefore) = try seededFile(in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = makeStore(provider, at: url)
        guard case .fileUnreadable = store.deferredReason else {
            return XCTFail("expected a deferred store, got \(String(describing: store.deferredReason))")
        }
        begin(store, "c3")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore, "an unreadable file is never overwritten")

        store.retryDeferredLoad()
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(store.records.map(\.id), ["c3", "c2", "c1"])
    }

    // MARK: - Key not found / file the key cannot open

    @MainActor
    func test_keyNotFound_noFile_createsKeyOnce_andRoundTrips() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("call_history.enc")
        let provider = FakeKeyProvider()
        let store = makeStore(provider, at: url)
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(provider.createCalls, 1)

        begin(store, "c1")
        let reopened = makeStore(provider, at: url)
        XCTAssertEqual(reopened.records.map(\.id), ["c1"])
        XCTAssertEqual(provider.createCalls, 1)
    }

    @MainActor
    func test_keyNotFound_withExistingFile_movesTheFileAside() throws {
        let dir = try makeDirectory()
        let (url, _, bytesBefore) = try seededFile(in: dir)
        let backupBefore = try Data(contentsOf: backupURL(url))   // left by the seeding saves
        let newProvider = FakeKeyProvider()   // the old key is gone (restore to a new device)

        let store = makeStore(newProvider, at: url)
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: unreadableURL(url)), bytesBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        begin(store, "c3")
        XCTAssertEqual(try readRecords(at: url, key: try XCTUnwrap(newProvider.key)).map(\.id), ["c3"])
        XCTAssertEqual(try Data(contentsOf: unreadableURL(url)), bytesBefore, "the old file is still kept")
        XCTAssertEqual(try Data(contentsOf: backupURL(url)), backupBefore,
                       "an unreadable file must not replace the backup")
    }

    @MainActor
    func test_corruptFile_withReadableKey_isMovedAsideNotRewritten() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("call_history.enc")
        let garbage = Data("this is not a sealed box".utf8) + Data(repeating: 7, count: 64)
        try garbage.write(to: url)
        let provider = FakeKeyProvider(key: SymmetricKey(size: .bits256))

        let store = makeStore(provider, at: url)
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: unreadableURL(url)), garbage)

        begin(store, "c1")
        XCTAssertEqual(try readRecords(at: url, key: try XCTUnwrap(provider.key)).map(\.id), ["c1"])
        XCTAssertEqual(provider.createCalls, 0, "the key existed, it must not be replaced")
    }

    // MARK: - Backup

    @MainActor
    func test_beforeEveryOverwrite_thePreviousFileIsKeptAsBackup() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("call_history.enc")
        let provider = FakeKeyProvider()
        let store = makeStore(provider, at: url)
        let key: () throws -> SymmetricKey = { try XCTUnwrap(provider.key) }

        begin(store, "c1")                       // file v1: [c1]
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(url).path))
        begin(store, "c2")                       // file v2: [c2, c1], backup = v1
        XCTAssertEqual(try readRecords(at: backupURL(url), key: try key()).map(\.id), ["c1"])
        store.endCall(id: "c2")                  // file v3, backup = v2
        XCTAssertEqual(try readRecords(at: backupURL(url), key: try key()).map(\.id), ["c2", "c1"])
        XCTAssertNil(try readRecords(at: backupURL(url), key: try key()).first?.endedAt)
        XCTAssertNotNil(try readRecords(at: url, key: try key()).first?.endedAt)
    }

    // MARK: - A deletion by the user leaves no copy

    @MainActor
    func test_deleteRecord_leavesNoCopyOfTheDeletedCall_andTheBackupResumesWithoutIt() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        let store = makeStore(provider, at: url)
        // The seeding saves left a backup that still holds both calls, so this test is not vacuous.
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), ["c1", "c2"])

        store.deleteRecord("c1")

        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c2"])
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), Set<String>(),
                       "no backup may still hold the deleted call")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(url).path))

        // The safety net resumes with the next call event, and it never carries the deleted call.
        begin(store, "c3")
        XCTAssertEqual(try readRecords(at: backupURL(url), key: key).map(\.id), ["c2"])
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c3", "c2"])
    }

    @MainActor
    func test_clearAll_leavesNoCopyOfTheHistory_notEvenALeftoverBackupTempFile() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        // A backup whose last step failed leaves its temp file behind.
        try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: backupURL(url).path + ".tmp"))
        let store = makeStore(provider, at: url)
        XCTAssertEqual(copyNames(of: url), ["call_history.enc.bak", "call_history.enc.bak.tmp"])

        store.clearAll()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(try readRecords(at: url, key: key).isEmpty)
        XCTAssertEqual(copyNames(of: url), [], "no copy of the live file may be left")
    }

    @MainActor
    func test_clearAll_removesAQuarantinedFileThatStillOpensWithTheKey_deleteRecordKeepsIt() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("call_history.enc")
        let provider = FakeKeyProvider(key: SymmetricKey(size: .bits256))
        let key = try XCTUnwrap(provider.key)
        // Sealed under the real key but not a list of call records: it is moved aside, and it can
        // still be opened with the key, so it is history the user may want gone.
        let sealed = try AES.GCM.seal(Data(#"[{"id":"old-shape"}]"#.utf8), using: key)
        try XCTUnwrap(sealed.combined).write(to: url)

        let store = makeStore(provider, at: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableURL(url).path))

        begin(store, "c1")
        begin(store, "c2")
        store.deleteRecord("c1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableURL(url).path),
                      "deleting one call cannot concern a file that was never readable")

        store.clearAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadableURL(url).path))
        XCTAssertEqual(copyNames(of: url), [])
    }

    @MainActor
    func test_deleteAndClearWhileDeferred_leaveNoCopyOnceTheyReachTheDisk() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)

        provider.lockedStatus = errSecInteractionNotAllowed
        let store = makeStore(provider, at: url)
        store.deleteRecord("c1")
        provider.lockedStatus = nil
        store.retryDeferredLoad()
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c2"])
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), Set<String>(),
                       "the replayed delete removes the old backup too")

        begin(store, "c3")                       // file [c3, c2], backup [c2]
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), ["c2"])
        provider.lockedStatus = errSecInteractionNotAllowed
        store.clearAll()
        provider.lockedStatus = nil
        store.retryDeferredLoad()
        XCTAssertTrue(try readRecords(at: url, key: key).isEmpty)
        XCTAssertEqual(copyNames(of: url), [], "the replayed clear-all removes the backup too")
    }

    @MainActor
    func test_failedWriteAfterDelete_doesNotLetTheNextSaveCopyTheDeletedCallIntoTheBackup() throws {
        try XCTSkipIf(geteuid() == 0, "permission bits do not stop root")
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        let store = makeStore(provider, at: url)

        // The directory cannot be written: the delete cannot reach the file, and the old backup
        // cannot be removed either.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        store.deleteRecord("c1")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c2", "c1"], "the write did fail")
        XCTAssertEqual(store.records.map(\.id), ["c2"])

        // The next save finds the file still holding the deleted call: it must not copy it into the
        // backup, and it removes the backup that exists.
        begin(store, "c3")
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c3", "c2"])
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), Set<String>())

        begin(store, "c4")
        XCTAssertEqual(try readRecords(at: backupURL(url), key: key).map(\.id), ["c3", "c2"])
    }

    // MARK: - The account that leaves the device takes its call history with it

    private let legacyKey = "qaudion.callHistory.v2"

    @MainActor
    func test_wipe_removesEveryFile_theKey_theLegacyValue_andTheList_theNextAccountStartsFresh() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let oldKey = try XCTUnwrap(provider.key)
        let defaults = makeDefaults()
        let store = makeStore(provider, at: url, defaults: defaults)
        XCTAssertEqual(store.records.map(\.id), ["c2", "c1"])
        // Every place the history can sit: the file, the backup (left by the seeding saves), the temp
        // file of a backup that failed halfway, the file moved aside, and the pre-file UserDefaults value.
        try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: backupURL(url).path + ".tmp"))
        try FileManager.default.copyItem(at: url, to: unreadableURL(url))
        defaults.set(try JSONEncoder().encode(store.records), forKey: legacyKey)
        XCTAssertEqual(copyNames(of: url),
                       ["call_history.enc.bak", "call_history.enc.bak.tmp", "call_history.enc.unreadable"])

        store.wipeAccountHistory()

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(siblingNames(of: url), [], "no copy of the history may be left")
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertNil(provider.key, "the key goes too")
        XCTAssertEqual(provider.deleteCalls, 1)

        // The next account on the device: a new key and a new file that holds only its own calls.
        begin(store, "n1")
        let newKey = try XCTUnwrap(provider.key)
        XCTAssertNotEqual(bytes(of: newKey), bytes(of: oldKey))
        XCTAssertEqual(try readRecords(at: url, key: newKey).map(\.id), ["n1"])
        XCTAssertThrowsError(try readRecords(at: url, key: oldKey), "the old key opens nothing any more")
        XCTAssertEqual(copyNames(of: url), [])
        XCTAssertEqual(store.records.map(\.id), ["n1"])
    }

    @MainActor
    func test_wipe_whileTheDeviceIsLocked_winsOverTheDeferredLoad() throws {
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        provider.lockedStatus = errSecInteractionNotAllowed
        let store = makeStore(provider, at: url)
        begin(store, "c3")                       // recorded while locked: in memory only
        XCTAssertTrue(store.isPersistenceDeferred)

        store.wipeAccountHistory()

        XCTAssertTrue(store.records.isEmpty, "the call recorded while locked belonged to the account that left")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(provider.deleteCalls, 1)
        XCTAssertNotNil(provider.key, "a locked device cannot delete the key: the files are what must be gone")

        provider.lockedStatus = nil
        store.retryDeferredLoad()                // protected data is available again
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertTrue(store.records.isEmpty, "nothing of the previous account comes back")

        begin(store, "n1")
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["n1"])
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), Set<String>())
    }

    @MainActor
    func test_wipe_whenTheFileCannotBeRemovedNow_stillWinsOverTheDeferredLoad() throws {
        try XCTSkipIf(geteuid() == 0, "permission bits do not stop root")
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        provider.lockedStatus = errSecInteractionNotAllowed
        let store = makeStore(provider, at: url)
        begin(store, "c3")

        // The directory cannot be written: the file and its backup survive the wipe.
        try setMode(dir, 0o500)
        store.wipeAccountHistory()
        try setMode(dir, 0o700)
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c2", "c1"], "the removal did fail")
        XCTAssertTrue(store.records.isEmpty)

        provider.lockedStatus = nil
        store.retryDeferredLoad()
        XCTAssertTrue(store.records.isEmpty, "what the survivor holds is discarded, not merged back")
        XCTAssertTrue(try readRecords(at: url, key: key).isEmpty)
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), Set<String>(),
                       "the save that replaced the survivor removed its copies too")
    }

    @MainActor
    func test_wipe_whenTheFileCannotBeRemoved_theNextAccountsSaveReplacesItAndRemovesTheCopies() throws {
        try XCTSkipIf(geteuid() == 0, "permission bits do not stop root")
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let oldKey = try XCTUnwrap(provider.key)
        let store = makeStore(provider, at: url)

        try setMode(dir, 0o500)
        store.wipeAccountHistory()
        try setMode(dir, 0o700)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(provider.key, "the key is deleted even though a file survived: the survivor opens with nothing")
        XCTAssertEqual(try readRecords(at: url, key: oldKey).map(\.id), ["c2", "c1"], "the removal did fail")

        begin(store, "n1")
        let newKey = try XCTUnwrap(provider.key)
        XCTAssertEqual(try readRecords(at: url, key: newKey).map(\.id), ["n1"])
        XCTAssertEqual(copyNames(of: url), [], "the survivor was moved aside and removed with the other copies")
    }

    @MainActor
    func test_localCryptoWipe_clearsTheCallHistory() {
        // The shared store first: were it created after the legacy value is set, its own migration
        // could remove the value and this test would pass for the wrong reason.
        _ = PersistentCallRecordStore.shared
        let defaults = UserDefaults.standard
        let key = legacyKey
        defaults.set(Data("[]".utf8), forKey: key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        LocalCryptoWipe.wipeCallHistory()

        XCTAssertNil(defaults.data(forKey: key), "wipeAll() reaches the call history store")
        XCTAssertTrue(PersistentCallRecordStore.shared.records.isEmpty)
    }

    @MainActor
    func test_callHistoryList_isBuiltFromThePersistedRecordsOnly() {
        // It used to fall back to made-up entries from the session's recent calls when the store was
        // empty, which brought back the calls the user had just cleared.
        XCTAssertTrue(CallHistoryStore.makeEntries(records: [], cachedContacts: []).isEmpty)
        let record = CallRecord(id: "r1", peerUserId: "peer-r1", peerDisplayName: "Peer r1",
                                direction: .outgoing, startedAt: Date(), endedAt: nil,
                                isVideo: false, peerExtension: nil)
        XCTAssertEqual(CallHistoryStore.makeEntries(records: [record], cachedContacts: []).map(\.id), ["r1"])
    }

    // MARK: - Pending deletions mean "not on disk yet"

    @MainActor
    func test_deleteRecord_whoseWriteFailed_isNotBroughtBackByALaterDeferredLoad() throws {
        try XCTSkipIf(geteuid() == 0, "permission bits do not stop root")
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        let store = makeStore(provider, at: url)

        // The write fails while the store is not deferred: the file still holds c1.
        try setMode(dir, 0o500)
        store.deleteRecord("c1")
        try setMode(dir, 0o700)
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c2", "c1"], "the write did fail")

        // The device locks, a call is recorded in memory, then it unlocks and the load merges.
        provider.lockedStatus = errSecInteractionNotAllowed
        begin(store, "c3")
        XCTAssertTrue(store.isPersistenceDeferred)
        provider.lockedStatus = nil
        store.retryDeferredLoad()

        XCTAssertEqual(store.records.map(\.id), ["c3", "c2"], "the deleted call stays deleted")
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c3", "c2"])
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), Set<String>())
    }

    @MainActor
    func test_clearAll_whoseWriteFailed_isNotBroughtBackByALaterDeferredLoad() throws {
        try XCTSkipIf(geteuid() == 0, "permission bits do not stop root")
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        let store = makeStore(provider, at: url)

        try setMode(dir, 0o500)
        store.clearAll()
        try setMode(dir, 0o700)
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c2", "c1"], "the write did fail")

        provider.lockedStatus = errSecInteractionNotAllowed
        begin(store, "c3")
        XCTAssertTrue(store.isPersistenceDeferred)
        provider.lockedStatus = nil
        store.retryDeferredLoad()

        XCTAssertEqual(store.records.map(\.id), ["c3"], "the cleared history stays cleared")
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c3"])
        XCTAssertEqual(idsReadableOutsideTheLiveFile(url, key: key), Set<String>())
    }

    @MainActor
    func test_deleteWhileDeferred_isStillReplayedAfterTheUnlockWriteFailed() throws {
        try XCTSkipIf(geteuid() == 0, "permission bits do not stop root")
        let dir = try makeDirectory()
        let (url, provider, _) = try seededFile(in: dir)
        let key = try XCTUnwrap(provider.key)
        provider.lockedStatus = errSecInteractionNotAllowed
        let store = makeStore(provider, at: url)
        store.deleteRecord("c1")                 // deferred: nothing reaches the disk

        // Unlock, but the directory cannot be written: the load succeeds, the write does not.
        provider.lockedStatus = nil
        try setMode(dir, 0o500)
        store.retryDeferredLoad()
        try setMode(dir, 0o700)
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(store.records.map(\.id), ["c2"])
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c2", "c1"], "the write did fail")

        // The device locks and unlocks again before any write succeeded: c1 must still be filtered out.
        provider.lockedStatus = errSecInteractionNotAllowed
        begin(store, "c3")
        provider.lockedStatus = nil
        store.retryDeferredLoad()

        XCTAssertEqual(store.records.map(\.id), ["c3", "c2"])
        XCTAssertEqual(try readRecords(at: url, key: key).map(\.id), ["c3", "c2"])
    }

    // MARK: - A file is moved aside only for a key that was really created

    @MainActor
    func test_keyNotFoundButStoredMeanwhile_leavesTheFileInPlace_andOpensIt() throws {
        let dir = try makeDirectory()
        let (url, provider, bytesBefore) = try seededFile(in: dir)
        // The read does not see the key (a race), the add then answers "duplicate": the stored key
        // is the one that sealed the file.
        provider.readHidesKey = true

        let store = makeStore(provider, at: url)

        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(store.records.map(\.id), ["c2", "c1"])
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadableURL(url).path))
    }

    @MainActor
    func test_keyNotFound_andCreationFails_leavesTheFileInPlace_thenMovesItOnceTheKeyIsCreated() throws {
        let dir = try makeDirectory()
        let (url, _, bytesBefore) = try seededFile(in: dir)
        let newProvider = FakeKeyProvider()       // the old key is gone
        newProvider.createStatus = errSecInteractionNotAllowed

        let store = makeStore(newProvider, at: url)

        XCTAssertEqual(store.deferredReason, .keyUnavailable(errSecInteractionNotAllowed))
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore, "no new key exists, so the file is not moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadableURL(url).path))

        newProvider.createStatus = nil
        store.retryDeferredLoad()
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertEqual(try Data(contentsOf: unreadableURL(url)), bytesBefore,
                       "now it is known to be sealed under a key that is gone")
        XCTAssertTrue(try readRecords(at: url, key: try XCTUnwrap(newProvider.key)).isEmpty)
    }

    // MARK: - W-CALLERBUSY: an outgoing call the callee could not take closes as busy / peer_offline

    @MainActor
    func test_busyAndPeerOfflineCloseReasons_areStored_andSurviveARelaunch() throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("call_history.enc")
        let provider = FakeKeyProvider()
        let store = makeStore(provider, at: url)
        begin(store, "c1")
        store.endCall(id: "c1", closeReason: "busy")
        begin(store, "c2")
        store.endCall(id: "c2", closeReason: "peer_offline")

        XCTAssertEqual(store.records.first(where: { $0.id == "c1" })?.closeReason, "busy")
        XCTAssertEqual(store.records.first(where: { $0.id == "c2" })?.closeReason, "peer_offline")
        let key = try XCTUnwrap(provider.key)
        let onDisk = try readRecords(at: url, key: key)
        XCTAssertEqual(onDisk.first(where: { $0.id == "c1" })?.closeReason, "busy")
        XCTAssertEqual(onDisk.first(where: { $0.id == "c2" })?.closeReason, "peer_offline")
    }

    @MainActor
    func test_aFreeFormCloseReason_isStillDropped_andBusyHasNoDuration() throws {
        let dir = try makeDirectory()
        let store = makeStore(FakeKeyProvider(), at: dir.appendingPathComponent("call_history.enc"))
        begin(store, "c1")
        store.endCall(id: "c1", closeReason: "not_an_allow_listed_token")
        XCTAssertNil(store.records.first?.closeReason)

        // A busy dial that took a couple of seconds to be answered is not a call of that length.
        let record = CallRecord(
            id: "b1", peerUserId: "p", peerDisplayName: "P", direction: .outgoing,
            startedAt: Date(timeIntervalSinceNow: -5), endedAt: Date(), isVideo: false,
            peerExtension: nil, closeReason: "busy")
        XCTAssertNil(record.durationSeconds)
        let plain = CallRecord(
            id: "p1", peerUserId: "p", peerDisplayName: "P", direction: .outgoing,
            startedAt: Date(timeIntervalSinceNow: -5), endedAt: Date(), isVideo: false,
            peerExtension: nil, closeReason: nil)
        XCTAssertNotNil(plain.durationSeconds)
    }
}

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
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing`
/// list of `.github/workflows/ios-app-tests.yml`.
final class PersistentCallRecordStoreTests: XCTestCase {

    // MARK: - Fakes and helpers

    /// A key store that behaves like the Keychain does for this item. `locked` means the item exists
    /// but cannot be read now. `createKey()` never replaces an existing key.
    final class FakeKeyProvider: CallHistoryKeyProviding {
        var key: SymmetricKey?
        var lockedStatus: OSStatus?
        private(set) var createCalls = 0

        init(key: SymmetricKey? = nil) { self.key = key }

        func readKey() -> CallHistoryKeyLookup {
            if let status = lockedStatus { return .unavailable(status) }
            if let key = key { return .found(key) }
            return .notFound
        }

        func createKey() -> CallHistoryKeyLookup {
            createCalls += 1
            if let status = lockedStatus { return .unavailable(status) }
            if let key = key { return .found(key) }
            let fresh = SymmetricKey(size: .bits256)
            key = fresh
            return .found(fresh)
        }
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("callhistory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            // A test may leave a file unreadable on purpose.
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

    @MainActor
    private func makeStore(
        _ provider: FakeKeyProvider,
        at url: URL,
        center: NotificationCenter = NotificationCenter(),
        retryOn names: [Notification.Name] = []
    ) -> PersistentCallRecordStore {
        PersistentCallRecordStore(
            keyProvider: provider, fileURL: url, notificationCenter: center, retryNotifications: names)
    }

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
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(url).path))
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
        let newProvider = FakeKeyProvider()   // the old key is gone (restore to a new device)

        let store = makeStore(newProvider, at: url)
        XCTAssertFalse(store.isPersistenceDeferred)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: unreadableURL(url)), bytesBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        begin(store, "c3")
        XCTAssertEqual(try readRecords(at: url, key: try XCTUnwrap(newProvider.key)).map(\.id), ["c3"])
        XCTAssertEqual(try Data(contentsOf: unreadableURL(url)), bytesBefore, "the old file is still kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL(url).path),
                       "an unreadable file must not become the backup")
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
}

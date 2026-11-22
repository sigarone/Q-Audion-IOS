import XCTest
@testable import QAudionEngine

/// The records that bind a chat session to the peer key it was authenticated against (`SessionBindingStore`), driven through the
/// persisting steps of `MessageRatchet` (`persistInstall`, `persistReplace`, `persistDrop`, the decrypt notes). The native core is not
/// linked in these tests, so the steps are fed session blobs directly; they are the same code the install and decrypt paths run.
///
/// The per-peer state of the store is process-wide, so every test uses peers of its own.
final class SessionBindingStoreTests: XCTestCase {

    /// A vault in memory whose reads and writes can be made to fail per row.
    final class FlakyVault: RatchetVault, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [String: Data] = [:]
        var failSaveRows: Set<String> = []
        /// Rows whose NEXT save fails, once.
        var failSaveOnce: Set<String> = []
        var failDeleteRows: Set<String> = []
        var failExistsRows: Set<String> = []
        var failLoadRows: Set<String> = []

        private func key(_ epoch: String, _ peer: String) -> String { epoch + "|" + peer }

        func load(epochId: String, peerId: String) -> RatchetSnapshot? { nil }
        func save(epochId: String, peerId: String, snapshot: RatchetSnapshot) throws {}
        func delete(epochId: String, peerId: String) {}

        func loadV4(epochId: String, peerId: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return rows[key(epochId, peerId)]
        }
        func saveV4(epochId: String, peerId: String, blob: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if failSaveRows.contains(epochId) { throw VaultError.persistFailed(-1) }
            if failSaveOnce.remove(epochId) != nil { throw VaultError.persistFailed(-1) }
            rows[key(epochId, peerId)] = blob
        }
        func deleteV4(epochId: String, peerId: String) {
            lock.lock(); defer { lock.unlock() }
            rows.removeValue(forKey: key(epochId, peerId))
        }
        func hasV4Checked(epochId: String, peerId: String) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if failExistsRows.contains(epochId) { throw VaultError.readFailed(-2) }
            return rows[key(epochId, peerId)] != nil
        }
        func loadV4Checked(epochId: String, peerId: String) throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            if failLoadRows.contains(epochId) { throw VaultError.readFailed(-3) }
            return rows[key(epochId, peerId)]
        }
        func deleteV4Checked(epochId: String, peerId: String) throws {
            lock.lock(); defer { lock.unlock() }
            if failDeleteRows.contains(epochId) { throw VaultError.deleteFailed(-4) }
            rows.removeValue(forKey: key(epochId, peerId))
        }
    }

    /// Collects lines or ids from a callback that may run on any thread.
    final class LineBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private let chat = MessageRatchet.v4RoutingEpoch
    private let control = MessageRatchet.v5ControlRoutingEpoch
    private let printA = String(repeating: "a1", count: 16)
    private let printB = String(repeating: "b2", count: 16)
    private let printC = String(repeating: "c3", count: 16)

    private func blob(_ n: UInt8) -> Data { Data(repeating: n, count: 64) }
    private func newPeer() -> String { UUID().uuidString.lowercased() }

    private func bound(_ r: MessageRatchet, _ peer: String) -> Set<String>? {
        if case .known(let prints) = r.boundPeerPrintsChecked(peerId: peer) { return prints }
        return nil
    }

    // MARK: Written at each install site, moved on replace, gone with the session

    func testTheBindingIsWrittenAtEveryInstallSite() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        // CHAT created if absent (the KMS pre-bootstrap, the create primitive) and CONTROL replaced (every handshake and pre-bootstrap).
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        XCTAssertEqual(bound(r, peer), [printA])
        let replaced = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printA)
        XCTAssertTrue(replaced)
        XCTAssertEqual(bound(r, peer), [printA])
        // Both rows carry the hash of their session next to it.
        XCTAssertEqual(vault.loadV4(epochId: SessionBindingStore.srcId(chat), peerId: peer), SessionBindingStore.tag(of: blob(1)))
        XCTAssertEqual(vault.loadV4(epochId: SessionBindingStore.srcId(control), peerId: peer), SessionBindingStore.tag(of: blob(2)))
    }

    func testAReplaceMovesTheBindingToThePreviousSlot() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printB)
        // The previous session has not been shown dead: both keys count.
        XCTAssertEqual(bound(r, peer), [printA, printB])
        XCTAssertNotNil(vault.loadV4(epochId: SessionBindingStore.prevId(control), peerId: peer))
        XCTAssertEqual(vault.loadV4(epochId: SessionBindingStore.prevSrcId(control), peerId: peer), SessionBindingStore.tag(of: blob(1)))
    }

    func testTheBindingGoesWithTheSessionThatIsDropped() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        r.persistDrop(epochId: chat, peerId: peer)
        XCTAssertNil(vault.loadV4(epochId: chat, peerId: peer))
        XCTAssertNil(bound(r, peer), "no session is left: nothing is bound")
        // A replaced session's previous one keeps its own binding when the current one is dropped.
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printA)
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(3), peerKeyPrint: printB)
        r.persistDrop(epochId: control, peerId: peer)
        XCTAssertEqual(bound(r, peer), [printA])
    }

    func testARepeatOfTheSameMaterialReplacesNothingButBindsALegacySession() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        // A session installed by a build without bindings: the row and its source hash, no record.
        try vault.saveV4(epochId: control, peerId: peer, blob: blob(7))
        try vault.saveV4(epochId: SessionBindingStore.srcId(control), peerId: peer, blob: SessionBindingStore.tag(of: blob(7)))
        XCTAssertNil(bound(r, peer), "a legacy session has no binding")
        let replaced = try r.persistReplace(epochId: control, peerId: peer, blob: blob(7), peerKeyPrint: printA)
        XCTAssertFalse(replaced, "the same material replaces nothing")
        XCTAssertEqual(bound(r, peer), [printA])
    }

    // MARK: Unknown

    func testALegacySessionWithoutARecordIsUnknown() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        try vault.saveV4(epochId: chat, peerId: peer, blob: blob(1))
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    func testNoSessionAtAllIsUnknown() {
        let r = MessageRatchet(vault: FlakyVault())
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: newPeer()), .unknown)
    }

    func testASessionInstalledWithoutAPrintIsUnknown() throws {
        let r = MessageRatchet(vault: FlakyVault())
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: nil)
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    func testAnUnreadableStoreIsUnknownAndNeverCached() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let reader = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 4 })
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        vault.failExistsRows = [chat]
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .failed)
        XCTAssertNil(reader.boundPeerPrints(peerUserId: peer))
        XCTAssertNil(reader.cachedAnswer(peerUserId: peer), "an error is never cached")
        vault.failExistsRows = []
        XCTAssertEqual(reader.boundPeerPrints(peerUserId: peer), [printA])
        // A row that exists but cannot be read is an error, not an absent row.
        vault.failLoadRows = [SessionBindingStore.recId(chat)]
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .failed, "a record that exists and cannot be read is an error")
    }

    func testARatchetOlderThanV4OrOneThatCannotBeReadIsUnknown() throws {
        let r = MessageRatchet(vault: FlakyVault())
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        for version in 0...3 {
            let reader = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in version })
            XCTAssertNil(reader.boundPeerPrints(peerUserId: peer), "v\(version)")
        }
        struct Unreadable: Error {}
        let broken = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in throw Unreadable() })
        XCTAssertNil(broken.boundPeerPrints(peerUserId: peer))
        XCTAssertEqual(PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 5 }).boundPeerPrints(peerUserId: peer), [printA])
    }

    func testACrashBetweenTheSessionWriteAndTheRecordWriteIsUnknown() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        XCTAssertEqual(bound(r, peer), [printA])
        // The next install dies after the session is written and before its record is: the record was invalidated first.
        vault.failSaveRows = [SessionBindingStore.recId(chat)]
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(2), peerKeyPrint: printB)
        vault.failSaveRows = []
        XCTAssertNotNil(vault.loadV4(epochId: chat, peerId: peer))
        XCTAssertNil(vault.loadV4(epochId: SessionBindingStore.recId(chat), peerId: peer))
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    // MARK: Liveness of the previous session, on a counter

    func testThePreviousSessionIsLiveUntilTheCurrentOneHasDecryptedAndItHasNot() throws {
        let r = MessageRatchet(vault: FlakyVault())
        let peer = newPeer()
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printB)
        XCTAssertEqual(bound(r, peer), [printA, printB], "the current session has not decrypted yet")
        r.noteCurrentOpened(epochId: control, peerId: peer)
        XCTAssertEqual(bound(r, peer), [printB], "the current session decrypted and the previous one did not")
        r.noteCurrentOpened(epochId: control, peerId: peer) // once per install: nothing moves
        XCTAssertEqual(bound(r, peer), [printB])
        r.notePreviousOpened(epochId: control, peerId: peer)
        XCTAssertEqual(bound(r, peer), [printA, printB], "the previous session decrypted after the current one's first decrypt")
    }

    func testTheFirstDecryptIsNotedOncePerInstall() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        let before = MessageRatchet.bindingVersion(peerId: peer)
        r.noteCurrentOpened(epochId: chat, peerId: peer)
        let afterFirst = MessageRatchet.bindingVersion(peerId: peer)
        XCTAssertGreaterThan(afterFirst, before, "the first decrypt is recorded")
        for _ in 0..<50 { r.noteCurrentOpened(epochId: chat, peerId: peer) }
        XCTAssertEqual(MessageRatchet.bindingVersion(peerId: peer), afterFirst, "no record write and no signal per message")
    }

    func testTheCounterIsPersistedAndStrictlyIncreasing() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printB)
        func record() -> SessionBindingStore.Record? {
            vault.loadV4(epochId: SessionBindingStore.recId(control), peerId: peer).flatMap(SessionBindingStore.Record.decode)
        }
        r.noteCurrentOpened(epochId: control, peerId: peer)
        let first = record()
        r.notePreviousOpened(epochId: control, peerId: peer)
        let second = record()
        let a = try XCTUnwrap(first)
        let b = try XCTUnwrap(second)
        XCTAssertGreaterThan(b.counter, a.counter)
        XCTAssertGreaterThanOrEqual(b.prevLastSeq, b.curFirstSeq)
    }

    func testTheLivenessNeverReadsAClock() throws {
        // The store holds no time source at all: a clock stepped back cannot drop a previous session that still decrypts.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QAudionEngine/Crypto/SessionBindingStore.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let code = source.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for forbidden in ["Date(", "Date.", "systemUptime", "CFAbsoluteTime", "DispatchTime", "clock_gettime", "mach_absolute_time"] {
            XCTAssertFalse(code.contains(forbidden), "the binding store must not read a clock: \(forbidden)")
        }
    }

    // MARK: Failures never fail an install or a decrypt

    func testAFailedBindingWriteStillInstalls() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        let box = LineBox()
        CapsBindLog.setSink { line in box.add(line) }
        defer { CapsBindLog.setSink(nil) }
        vault.failSaveRows = [SessionBindingStore.recId(chat), SessionBindingStore.srcId(chat)]
        XCTAssertNoThrow(try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA))
        vault.failSaveRows = [SessionBindingStore.recId(control)]
        XCTAssertNoThrow(try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printA))
        XCTAssertEqual(vault.loadV4(epochId: chat, peerId: peer), blob(1), "the session is installed")
        XCTAssertEqual(vault.loadV4(epochId: control, peerId: peer), blob(2), "the session is installed")
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown, "and fails closed")
        let seen = box.all
        XCTAssertFalse(seen.isEmpty)
        for line in seen {
            XCTAssertTrue(["SESSION-BIND write_failed slot=rec", "SESSION-BIND write_failed slot=cur", "SESSION-BIND write_failed slot=prev"].contains(line),
                          "only the closed-vocabulary line, no ids: \(line)")
        }
    }

    func testAFailedNoteOfThePreviousSessionMarksThatSlotUnknownAndAnotherSlotDoesNotClearIt() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printB)
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(9), peerKeyPrint: printB)
        r.noteCurrentOpened(epochId: control, peerId: peer)
        XCTAssertEqual(bound(r, peer), [printB])
        // The previous session decrypts but that cannot be written.
        vault.failSaveRows = [SessionBindingStore.recId(control)]
        r.notePreviousOpened(epochId: control, peerId: peer)
        vault.failSaveRows = []
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
        // A successful record write to ANOTHER slot of the peer does not clear it.
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(10), peerKeyPrint: printB)
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
        // Nor does a repeat install from the same material of the same slot (no record write is made for it).
        let skipped = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: printB)
        XCTAssertFalse(skipped)
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
        // A later successful record write to the SAME slot does.
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(3), peerKeyPrint: printB)
        XCTAssertNotEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    func testAFailedRecordDeleteOrDropMarksTheSlotUnknown() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        // The record can be neither invalidated nor rewritten: the slot is unknown, not believed by its stale tags.
        vault.failDeleteRows = [SessionBindingStore.recId(chat)]
        vault.failSaveRows = [SessionBindingStore.recId(chat)]
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(2), peerKeyPrint: printB)
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
        // A later successful record write to the same slot clears the mark.
        vault.failDeleteRows = []
        vault.failSaveRows = []
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(3), peerKeyPrint: printB)
        XCTAssertEqual(bound(r, peer), [printB])
        vault.failDeleteRows = [chat]
        r.persistDrop(epochId: chat, peerId: peer) // the session could not be deleted
        vault.failDeleteRows = []
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    func testAReadFailureDuringThePreviousNoteMarksTheSlotUnknown() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printB)
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(2), peerKeyPrint: printA)
        r.noteCurrentOpened(epochId: chat, peerId: peer)
        XCTAssertEqual(bound(r, peer), [printA])
        vault.failLoadRows = [SessionBindingStore.recId(chat)]
        r.notePreviousOpened(epochId: chat, peerId: peer)
        vault.failLoadRows = []
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown, "the previous session decrypted and nothing could say so")
    }

    func testAnUnknownMarkSurvivesARestart() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printB)
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(2), peerKeyPrint: printA)
        r.noteCurrentOpened(epochId: chat, peerId: peer)
        XCTAssertEqual(bound(r, peer), [printA])
        // The note cannot be written once: a tombstone goes over the record.
        vault.failSaveOnce = [SessionBindingStore.recId(chat)]
        r.notePreviousOpened(epochId: chat, peerId: peer)
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
        _ = SessionBindingStore.State.shared.resetAll() // a restart: nothing is remembered in memory
        XCTAssertEqual(MessageRatchet(vault: vault).boundPeerPrintsChecked(peerId: peer), .unknown)
        // An install over it clears it.
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(3), peerKeyPrint: printA)
        r.noteCurrentOpened(epochId: chat, peerId: peer)
        XCTAssertEqual(bound(r, peer), [printA])
        // When the tombstone cannot be written either the record is deleted, which reads as unknown after a restart too.
        vault.failSaveRows = [SessionBindingStore.recId(chat)]
        r.notePreviousOpened(epochId: chat, peerId: peer)
        vault.failSaveRows = []
        _ = SessionBindingStore.State.shared.resetAll()
        XCTAssertNil(vault.loadV4(epochId: SessionBindingStore.recId(chat), peerId: peer))
        XCTAssertEqual(MessageRatchet(vault: vault).boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    func testARepeatInstallNeverOverwritesTheMarkOfAnUnknownSlot() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printB)
        _ = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(2), peerKeyPrint: printA)
        r.noteCurrentOpened(epochId: chat, peerId: peer)
        // the note of the previous session fails once: a mark goes over the record
        vault.failSaveOnce = [SessionBindingStore.recId(chat)]
        r.notePreviousOpened(epochId: chat, peerId: peer)
        // the same material installs again with a print, then the app restarts
        let replaced = try r.persistReplace(epochId: chat, peerId: peer, blob: blob(2), peerKeyPrint: printA)
        XCTAssertFalse(replaced)
        _ = SessionBindingStore.State.shared.resetAll()
        let after = MessageRatchet(vault: vault)
        after.noteCurrentOpened(epochId: chat, peerId: peer)
        XCTAssertEqual(after.boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    func testASessionInstalledWithoutAVerifiedKeyIsUnknownNeverTheClaimedKey() throws {
        // A round whose signature did not verify hands no print: the slot reads as unknown, as before bindings existed.
        let r = MessageRatchet(vault: FlakyVault())
        let peer = newPeer()
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(2), peerKeyPrint: nil)
        r.noteCurrentOpened(epochId: control, peerId: peer)
        XCTAssertNotEqual(r.boundPeerPrintsChecked(peerId: peer), .known([printA]))
        XCTAssertEqual(r.boundPeerPrintsChecked(peerId: peer), .unknown)
    }

    func testTheRatchetVersionNeedsAChatSession() throws {
        let vault = FlakyVault()
        let r = MessageRatchet(vault: vault)
        let peer = newPeer()
        XCTAssertEqual(try r.newestChannelRatchetVersion(peerId: peer), 0)
        _ = try r.persistReplace(epochId: control, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        XCTAssertEqual(try r.newestChannelRatchetVersion(peerId: peer), 0, "a CONTROL session alone is not a v4 or v5 chat")
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(2), peerKeyPrint: printA)
        XCTAssertEqual(try r.newestChannelRatchetVersion(peerId: peer), 5)
        r.persistDrop(epochId: control, peerId: peer)
        XCTAssertEqual(try r.newestChannelRatchetVersion(peerId: peer), 4)
    }

    // MARK: One signal per peer, never lost

    func testABurstOfChangesForOtherPeersDoesNotLoseThisPeersChange() throws {
        let r = MessageRatchet(vault: FlakyVault())
        let mine = newPeer()
        let box = LineBox()
        let token = NotificationCenter.default.addObserver(
            forName: MessageRatchet.bindingDidChangeNotification, object: nil, queue: nil) { note in
            if let peer = note.userInfo?["peerId"] as? String { box.add(peer) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let versionBefore = MessageRatchet.bindingVersion(peerId: mine)
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let other = "burst-\(i % 40)-\(mine)"
            try? r.persistInstall(epochId: self.chat, peerId: other, blob: self.blob(UInt8(i % 200)), peerKeyPrint: self.printC)
        }
        try r.persistInstall(epochId: chat, peerId: mine, blob: blob(1), peerKeyPrint: printA)
        let observed = Set(box.all)
        XCTAssertTrue(observed.contains(mine), "the change of this peer was delivered after a burst of other peers")
        XCTAssertGreaterThan(MessageRatchet.bindingVersion(peerId: mine), versionBefore)
    }

    func testACachedAnswerIsVoidedByThatPeersChangeOnly() throws {
        let r = MessageRatchet(vault: FlakyVault())
        let reader = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 4 })
        let mine = newPeer()
        let other = newPeer()
        try r.persistInstall(epochId: chat, peerId: mine, blob: blob(1), peerKeyPrint: printA)
        XCTAssertEqual(reader.boundPeerPrints(peerUserId: mine), [printA])
        XCTAssertNotNil(reader.cachedAnswer(peerUserId: mine))
        try r.persistInstall(epochId: chat, peerId: other, blob: blob(2), peerKeyPrint: printB)
        XCTAssertNotNil(reader.cachedAnswer(peerUserId: mine), "another peer's change does not void this one")
        try r.persistInstall(epochId: chat, peerId: mine, blob: blob(3), peerKeyPrint: printC)
        XCTAssertNil(reader.cachedAnswer(peerUserId: mine), "its own change does")
        XCTAssertEqual(reader.boundPeerPrints(peerUserId: mine), [printC])
    }

    func testAWipeVoidsEveryCachedAnswer() throws {
        let r = MessageRatchet(vault: FlakyVault())
        let reader = PeerSessionBindings(ratchet: r, ratchetVersionOf: { _ in 4 })
        let peer = newPeer()
        try r.persistInstall(epochId: chat, peerId: peer, blob: blob(1), peerKeyPrint: printA)
        XCTAssertEqual(reader.boundPeerPrints(peerUserId: peer), [printA])
        MessageRatchet.bindingsVaultWiped()
        XCTAssertNil(reader.cachedAnswer(peerUserId: peer))
    }

    // MARK: The fingerprint is the trust rows' fingerprint

    func testThePrintEqualsTheFingerprintTheTrustRowsRecordForTheSameKey() {
        let selfId = "11111111-1111-1111-1111-111111111111"
        let peerId = "22222222-2222-2222-2222-222222222222"
        let selfKey = Data((0..<32).map { UInt8($0 &+ 1) })
        let peerKey = Data((0..<32).map { UInt8($0 &+ 101) })
        let print = PeerKeyPrint.of(selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, peerKey: peerKey)
        let expected = SasPinVerification.fingerprintHex(
            selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, peerIdentityKey: peerKey)
        XCTAssertNotNil(print)
        XCTAssertEqual(print, expected)
        let rows = IdentityShieldRules.contactShieldRows(
            pins: [PeerIdentityPinStore.PinnedRow(deviceId: "dev", key: peerKey)],
            record: .empty, selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId,
            pendingChangeFingerprints: [], traffic: [:])
        XCTAssertEqual(rows.first?.fingerprintHex, print)
        XCTAssertNil(PeerKeyPrint.of(selfUserId: selfId, selfIdentityKey: selfKey, peerUserId: peerId, peerKey: Data(count: 5)))
        XCTAssertNil(PeerKeyPrint.of(selfUserId: nil, selfIdentityKey: selfKey, peerUserId: peerId, peerKey: peerKey))
    }

    // MARK: The line

    func testTheOnlyLineTheStoreWritesIsTheClosedVocabularyOne() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/QAudionEngine/Crypto/SessionBindingStore.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "CapsBindLog.line(").count - 1, 1, "one place writes a line")
        XCTAssertTrue(source.contains("\"SESSION-BIND write_failed slot=\\(slot)\""))
        XCTAssertFalse(source.contains("print("), "nothing else is written")
    }
}

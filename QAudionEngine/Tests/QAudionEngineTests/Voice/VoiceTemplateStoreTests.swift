import XCTest
import Foundation
import CryptoKit
@testable import QAudionEngine

/// The encrypted store with an in-memory key vault in place of the Keychain: nonce per write, AAD binding to the account and the
/// contact, atomic writes, the rule that only a failed authentication deletes anything, the install detection and every
/// deletion path.
final class VoiceTemplateStoreTests: XCTestCase {
    private var dir: URL!
    private var cfg: VoiceStateConstants!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        cfg = try VoiceKat.bundle().state
        dir = try VoiceStoreFixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    // MARK: helpers

    private func record(state: Int = TemplateState.enrolled, last: Int = 1_790_000_000) -> TemplateRecord {
        VoiceStoreFixtures.record(cfg, state: state, last: last)
    }

    private func vaultAead(_ vault: VoiceMemoryVault, at directory: URL? = nil) -> VoiceKeychainAead {
        let target = directory ?? dir!
        return VoiceKeychainAead(dataExists: { try VoiceTemplateStore.dataExists(in: target) }, vault: vault, sleep: { _ in })
    }

    private func store(_ aead: VoiceAead, account: String = "acct-1", directory: URL? = nil,
                       dirSync: @escaping VoiceDirectorySync = VoiceDirectorySyncs.none) -> VoiceTemplateStore {
        VoiceTemplateStore(dir: directory ?? dir, aead: aead, accountId: account, dirSync: dirSync)
    }

    private func plainAead(_ key: SymmetricKey = SymmetricKey(size: .bits256)) -> VoiceAesGcmAead {
        VoiceAesGcmAead(key: { key })
    }

    private func names() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func read(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: dir.appendingPathComponent(name)))
    }

    private func write(_ name: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: dir.appendingPathComponent(name))
    }

    private func meta(_ aead: VoiceAead, account: String = "acct-1") throws -> VoiceMeta {
        let plain = try aead.open(try read("meta.bin"), aad: Array("QAVM|2|\(account)".utf8))
        return try XCTUnwrap(VoiceMeta.decode(plain))
    }

    private func recordFile(_ s: VoiceTemplateStore, _ aead: VoiceAead, _ contact: String) throws -> String {
        s.fileName(salt: try meta(aead).nameSalt, contactId: contact)
    }

    private func assertKind(_ kind: VoiceStoreError.Kind, _ body: () throws -> Void, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        do {
            try body()
            XCTFail("no error: \(message)", file: file, line: line)
        } catch let error as VoiceStoreError {
            XCTAssertEqual(error.kind, kind, message, file: file, line: line)
        } catch {
            XCTFail("another error: \(error) \(message)", file: file, line: line)
        }
    }

    // MARK: the cipher

    func testSealAndOpenRoundTripNonceIsFreshAndAadAndEveryBitAreBound() throws {
        let aead = plainAead()
        let plain = (0..<300).map { UInt8(truncatingIfNeeded: $0) }
        let aad = Array("QAVT|3|acct|c".utf8)
        var nonces = Set<[UInt8]>()
        for i in 0..<2000 {
            let s = try aead.seal(plain, aad: aad)
            XCTAssertEqual(s.count, 12 + plain.count + 16)
            XCTAssertTrue(nonces.insert(Array(s.prefix(12))).inserted, "nonce repeated")
            if i == 0 { XCTAssertEqual(try aead.open(s, aad: aad), plain) }
        }
        let s = try aead.seal(plain, aad: aad)
        for i in [0, 11, 12, 100, s.count - 1] {
            var bad = s
            bad[i] ^= 1
            assertKind(.auth, { _ = try aead.open(bad, aad: aad) }, "a flipped bit at \(i)")
        }
        assertKind(.auth, { _ = try aead.open(s, aad: Array("QAVT|3|acct|d".utf8)) }, "another aad")
        for n in [0, 27] {
            assertKind(.auth, { _ = try aead.open([UInt8](repeating: 0, count: n), aad: aad) }, "a short blob of \(n)")
        }
        assertKind(.auth, { _ = try self.plainAead().open(s, aad: aad) }, "another key")
    }

    // MARK: files

    func testSaveAndLoadGiveTheSameRecordTheFileNameHidesTheContactIdAndTheContentIsCiphertext() throws {
        let vault = VoiceMemoryVault()
        let aead = vaultAead(vault)
        let s = store(aead)
        let rec = record()
        try s.save("Contact-ABC", rec)
        let all = names()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains("meta.bin"))
        let qvt = try XCTUnwrap(all.first { $0 != "meta.bin" })
        XCTAssertNotNil(qvt.range(of: "^[0-9a-f]{32}\\.qvt$", options: .regularExpression), qvt)
        let bytes = try read(qvt)
        XCTAssertEqual(bytes.count, TemplateCodec.sizeOf(state: TemplateState.enrolled, nSessions: 1) + 28) // nonce and tag
        let plain = try TemplateCodec.encode(rec)
        let asText = String(decoding: bytes.map { $0 & 0x7F }, as: UTF8.self)
        XCTAssertFalse(asText.contains("QAVT"), "magic in the file")
        XCTAssertNil(Data(bytes).range(of: Data(plain[8..<24])), "model id in the file")
        XCTAssertNil(Data(bytes).range(of: Data(plain[192..<256])), "anchor in the file")
        let back = try XCTUnwrap(try s.load("contact-abc")) // the id is lowercased
        XCTAssertEqual(try TemplateCodec.encode(back), plain)
        // a new store object over the same files reads it (meta.bin is persistent)
        let again = try XCTUnwrap(try store(vaultAead(vault)).load("CONTACT-abc"))
        XCTAssertEqual(try TemplateCodec.encode(again), plain)
        XCTAssertNil(try s.load("another"))
        // two writes of the same record do not give the same file
        try s.save("contact-abc", rec)
        XCTAssertNotEqual(bytes, try read(qvt))
        XCTAssertEqual(names().count, 2)
    }

    func testNoTempFileIsLeftACutWriteIsCleanedAndTheOldFileSurvivesIt() throws {
        let vault = VoiceMemoryVault()
        let s = store(vaultAead(vault))
        try s.save("c1", record())
        XCTAssertTrue(names().filter { $0.hasSuffix(".tmp") }.isEmpty)
        XCTAssertNotNil(try s.load("c1"))
        try write("deadbeef.qvt.tmp", [UInt8](repeating: 0, count: 10)) // a write that was cut short
        let again = store(vaultAead(vault))
        XCTAssertNotNil(try again.load("c1"))
        XCTAssertTrue(names().filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    func testAFileMovedToAnotherContactDoesNotOpenAndIsDeleted() throws {
        let aead = vaultAead(VoiceMemoryVault())
        let s = store(aead)
        try s.save("alice", record())
        try s.save("bob", record(last: 1_790_000_500))
        let a = try recordFile(s, aead, "alice")
        let b = try recordFile(s, aead, "bob")
        try write(b, try read(a)) // alice's content under bob's name
        XCTAssertNil(try s.load("bob"), "the AAD binds the contact")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(b).path))
        XCTAssertNotNil(try s.load("alice"))
    }

    /// Permanent cases: the file can never be read as a record, so it is deleted and the contact reads as "no record".
    func testAPermanentlyUnreadableRecordFileIsDeletedAndReadsAsNoRecord() throws {
        let aead = vaultAead(VoiceMemoryVault())
        let s = store(aead)
        try s.save("c", record())
        let name = try recordFile(s, aead, "c")
        let good = try read(name)
        let recordAad = Array("QAVT|3|acct-1|c".utf8)
        let broken = record()
        broken.anchor = nil
        var flipped = good
        flipped[40] ^= 1
        let cases: [(String, [UInt8])] = [
            ("a flipped bit", flipped),
            ("a file too short for a nonce and a tag", [UInt8](repeating: 0, count: 20)),
            ("a file larger than any record", [UInt8](repeating: 0, count: 20_000)),
            ("authentic bytes that are not a record", try aead.seal([UInt8](repeating: 1, count: 5000), aad: recordAad)),
            ("an authentic record without its anchor", try aead.seal(try TemplateCodec.encode(broken), aad: recordAad))
        ]
        for (label, bytes) in cases {
            try write(name, bytes)
            XCTAssertNil(try s.load("c"), label)
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(name).path), "\(label): the file is deleted")
        }
        // and the store keeps working
        try s.save("c", record())
        XCTAssertNotNil(try s.load("c"))
    }

    /// Transient cases: the file may be fine, so it stays.
    func testATransientFailureWhileReadingARecordKeepsTheFile() throws {
        let aead = vaultAead(VoiceMemoryVault())
        let s = store(aead)
        try s.save("c", record())
        let name = try recordFile(s, aead, "c")
        let good = try read(name)
        // an I/O error: the path cannot be read as a file
        try fm.removeItem(at: dir.appendingPathComponent(name))
        try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: false)
        assertKind(.io, { _ = try s.load("c") }, "unreadable file")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(name).path))
        try fm.removeItem(at: dir.appendingPathComponent(name))
        try write(name, good)
        XCTAssertNotNil(try s.load("c"))
    }

    func testAKeyThatIsNotAvailableThrowsAndDeletesNothing() throws {
        let vault = VoiceMemoryVault()
        let s = store(vaultAead(vault))
        try s.save("c", record())
        let before = names()
        let keyBefore = try XCTUnwrap(vault.current)
        vault.unavailable = true // the keychain of a locked device
        let locked = store(vaultAead(vault)) // a new process: meta.bin is read again
        assertKind(.key, { _ = try locked.load("c") }, "load while locked")
        assertKind(.key, { try locked.save("c", self.record()) }, "save while locked")
        assertKind(.key, { _ = try locked.update(contactId: "c") { $0 } }, "update while locked")
        XCTAssertEqual(names(), before)
        vault.unavailable = false
        XCTAssertEqual(vault.current, keyBefore, "the key is not replaced")
        XCTAssertNotNil(try store(vaultAead(vault)).load("c"))
    }

    func testAKeystoreFaultWhileOpeningARecordThrowsKeyAndDeletesNothing() throws {
        let faulty = VoiceFaultyAead(vaultAead(VoiceMemoryVault()))
        let s = store(faulty)
        try s.save("c", record())
        let before = names()
        faulty.failOpen = true
        assertKind(.key, { _ = try s.load("c") })
        XCTAssertEqual(names(), before, "the record must survive a keystore fault")
    }

    func testAKeystoreFaultWhileOpeningMetaThrowsKeyAndWipesNothing() throws {
        let faulty = VoiceFaultyAead(vaultAead(VoiceMemoryVault()))
        let s = store(faulty)
        for c in ["a", "b", "c"] { try s.save(c, record()) }
        let before = names()
        faulty.failOpen = true
        let nextProcess = store(faulty) // meta.bin is read again, as after a process start
        assertKind(.key, { _ = try nextProcess.load("a") })
        XCTAssertEqual(names(), before, "every learned voice must survive a keystore fault")
    }

    func testAFailedEncodeLeavesTheOldFile() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        try s.save("c", record())
        let bad = record()
        var v = VoiceStoreFixtures.axis(0)
        v[0] = .nan
        bad.anchor = v
        assertKind(.malformed, { try s.save("c", bad) })
        XCTAssertNotNil(try s.load("c"))
        XCTAssertTrue(names().filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    // MARK: account and meta

    func testADifferentAccountWipesTheLearnerDataAndStartsFresh() throws {
        let vault = VoiceMemoryVault()
        try store(vaultAead(vault), account: "acct-1").save("c", record())
        XCTAssertEqual(names().count, 2)
        let other = store(vaultAead(vault), account: "acct-2")
        XCTAssertNil(try other.load("c"))
        XCTAssertEqual(names(), ["meta.bin"])
        try other.save("c", record())
        XCTAssertNotNil(try store(vaultAead(vault), account: "acct-2").load("c"))
        XCTAssertNil(try store(vaultAead(vault), account: "acct-1").load("c")) // and the first account finds nothing either
    }

    func testAMetaThatFailsAuthenticationOrIsMissingWipesTheRecords() throws {
        let vault = VoiceMemoryVault()
        try store(vaultAead(vault)).save("c", record())
        var meta = try read("meta.bin")
        meta[30] ^= 1
        try write("meta.bin", meta)
        XCTAssertNil(try store(vaultAead(vault)).load("c"))
        XCTAssertEqual(names(), ["meta.bin"])
        // meta.bin missing while records are there: they cannot be named or opened
        let s = store(vaultAead(vault))
        try s.save("c", record())
        try fm.removeItem(at: dir.appendingPathComponent("meta.bin"))
        XCTAssertNil(try store(vaultAead(vault)).load("c"))
        XCTAssertEqual(names(), ["meta.bin"])
    }

    func testAShortOrNotAMetaFileWipesTheRecordsAndStartsFresh() throws {
        let vault = VoiceMemoryVault()
        let aead = vaultAead(vault)
        try store(aead).save("c", record())
        // a file too short for a nonce and a tag
        try write("meta.bin", [UInt8](repeating: 7, count: 10))
        XCTAssertNil(try store(aead).load("c"))
        XCTAssertEqual(names(), ["meta.bin"])
        // an authentic blob that is not a meta file
        try store(aead).save("c", record())
        try write("meta.bin", try aead.seal([UInt8](repeating: 1, count: 40), aad: Array("QAVM|2|acct-1".utf8)))
        XCTAssertNil(try store(aead).load("c"))
        XCTAssertEqual(names(), ["meta.bin"])
        XCTAssertNoThrow(try meta(aead))
    }

    func testATransientFailureWhileReadingMetaBinWipesNothing() throws {
        let vault = VoiceMemoryVault()
        try store(vaultAead(vault)).save("c", record())
        let before = names()
        let good = try read("meta.bin")
        // an I/O error
        try fm.removeItem(at: dir.appendingPathComponent("meta.bin"))
        try fm.createDirectory(at: dir.appendingPathComponent("meta.bin"), withIntermediateDirectories: false)
        assertKind(.io, { _ = try self.store(self.vaultAead(vault)).load("c") }, "unreadable meta.bin")
        XCTAssertEqual(names(), before)
        try fm.removeItem(at: dir.appendingPathComponent("meta.bin"))
        try write("meta.bin", good)
        XCTAssertNotNil(try store(vaultAead(vault)).load("c"))
    }

    func testMetaBinIsTheDocumentedLayoutAndHoldsNothingElse() throws {
        let aead = plainAead()
        try store(aead).prepare()
        let plain = try aead.open(try read("meta.bin"), aad: Array("QAVM|2|acct-1".utf8))
        XCTAssertEqual(plain.count, 86)
        XCTAssertEqual(String(decoding: plain.prefix(4), as: UTF8.self), "QAVM")
        XCTAssertEqual(plain[4], 2)
        XCTAssertEqual(plain[5], 0)
        let m = try XCTUnwrap(VoiceMeta.decode(plain))
        XCTAssertEqual(m.accountHash, Array(SHA256.hash(data: Data("acct-1".utf8))))
        XCTAssertEqual(m.installId.count, 16)
        XCTAssertEqual(m.nameSalt.count, 32)
        XCTAssertNil(VoiceMeta.decode(Array(plain.prefix(85))))
        XCTAssertNil(VoiceMeta.decode(plain + [0]))
        // two installs do not share an id or a salt
        let d2 = try VoiceStoreFixtures.temporaryDirectory()
        defer { try? fm.removeItem(at: d2) }
        try store(aead, directory: d2).prepare()
        let m2 = try XCTUnwrap(VoiceMeta.decode(try aead.open([UInt8](try Data(contentsOf: d2.appendingPathComponent("meta.bin"))),
                                                               aad: Array("QAVM|2|acct-1".utf8))))
        XCTAssertNotEqual(m.installId, m2.installId)
        XCTAssertNotEqual(m.nameSalt, m2.nameSalt)
    }

    // MARK: install detection

    /// The keychain outlives the app and the files do not: a key with no `meta.bin` and no record is a leftover and is deleted.
    func testAnOrphanKeyWithoutMetaBinIsDeletedAndANewOneIsUsed() throws {
        let leftover = SymmetricKey(size: .bits256).withUnsafeBytes { [UInt8]($0) }
        let vault = VoiceMemoryVault(key: leftover)
        let s = store(vaultAead(vault))
        try s.save("c", record())
        XCTAssertEqual(vault.removeCount, 1, "the old key is deleted")
        let fresh = try XCTUnwrap(vault.current)
        XCTAssertNotEqual(fresh, leftover, "a new key is created")
        XCTAssertNotNil(try s.load("c"))
        // from then on data exists, and a new process keeps the key it finds
        let next = store(vaultAead(vault))
        XCTAssertNotNil(try next.load("c"))
        XCTAssertEqual(vault.current, fresh)
        XCTAssertEqual(vault.removeCount, 1)
    }

    func testAKeyThatReadsAsMissingForAMomentWhileDataExistsIsNotReplaced() throws {
        let vault = VoiceMemoryVault()
        try store(vaultAead(vault)).save("c", record())
        let key = try XCTUnwrap(vault.current)
        let adds = vault.addCount
        vault.emptyReads = 2
        XCTAssertNotNil(try store(vaultAead(vault)).load("c"))
        XCTAssertEqual(vault.current, key)
        XCTAssertEqual(vault.addCount, adds)
    }

    func testAKeyThatWasReplacedCannotOpenWhatWasSealedBefore() throws {
        let vault = VoiceMemoryVault()
        try store(vaultAead(vault)).save("a", record())
        vault.replaceKey()
        XCTAssertNil(try store(vaultAead(vault)).load("a"), "a new key reads nothing of the old store")
        XCTAssertEqual(names(), ["meta.bin"])
    }

    // MARK: deletion paths

    func testForgetAContactDeletesThatRecordOnly() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        try s.save("a", record())
        try s.save("b", record())
        XCTAssertTrue(try s.delete("a"))
        XCTAssertFalse(try s.delete("a"))
        XCTAssertNil(try s.load("a"))
        XCTAssertNotNil(try s.load("b"))
        XCTAssertEqual(s.recordCount(), 1)
    }

    func testARecordOfAnotherModelOrFrontEndVersionIsDeletedAConstantsVersionChangeAloneIsKept() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        let m = record()
        m.modelId[0] ^= 1
        try s.save("m", m)
        let f = record()
        f.frontendVersion = cfg.frontendVersion + 1
        try s.save("f", f)
        let c = record()
        c.constantsVersion = cfg.constantsVersion + 5
        try s.save("c", c)
        XCTAssertNil(try s.loadCompatible("m", cfg))
        XCTAssertNil(try s.loadCompatible("f", cfg))
        XCTAssertNotNil(try s.loadCompatible("c", cfg))
        XCTAssertEqual(s.recordCount(), 1)
    }

    func testRetentionAndPurgeRunPerContactAndRewriteOrDeleteTheFile() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        let day = 86_400
        try s.save("old", record(last: 1_790_000_000))
        XCTAssertNil(try XCTUnwrap(try s.sweep("old", nowS: 1_790_000_000 + 730 * day, cfg)).record)
        XCTAssertNil(try s.load("old"))
        XCTAssertNil(try s.sweep("old", nowS: 1_790_000_000, cfg)) // nothing there
        // a Provisional record with a session outside the consensus, 31 days old
        let r = record(state: TemplateState.provisional, last: 1_790_000_000 + 40 * day)
        r.sessions = [
            TemplateSession(speechMs: 50_000, dayIndex: 1, startS: 1_790_000_000, endS: 1_790_000_900, deviceTag: 7, routeClass: 1,
                            inConsensus: true, nWindows: 20, centroid: VoiceStoreFixtures.axis(3)),
            TemplateSession(speechMs: 30_000, dayIndex: 2, startS: 1_790_001_000, endS: 1_790_001_900, deviceTag: 7, routeClass: 1,
                            inConsensus: false, nWindows: 20, centroid: VoiceStoreFixtures.axis(9))
        ]
        try s.save("p", r)
        let res = try XCTUnwrap(try s.sweep("p", nowS: 1_790_000_000 + 1900 + 30 * day, cfg))
        XCTAssertEqual(res.purged, [1])
        XCTAssertEqual(try s.load("p")?.sessions.count, 1)
    }

    func testOrphanFilesOfContactsThatAreGoneAreDeleted() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        for c in ["a", "b", "c"] { try s.save(c, record()) }
        XCTAssertEqual(try s.deleteOrphans(knownContactIds: ["a", "C", "zzz"], directorySynced: true), 1)
        XCTAssertEqual(s.recordCount(), 2)
        XCTAssertNotNil(try s.load("a"))
        XCTAssertNotNil(try s.load("c"))
        XCTAssertNil(try s.load("b"))
    }

    func testOrphanDeletionDoesNothingWithAnEmptyOrNotYetSyncedContactList() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        for c in ["a", "b"] { try s.save(c, record()) }
        XCTAssertEqual(try s.deleteOrphans(knownContactIds: [], directorySynced: true), 0)
        XCTAssertEqual(try s.deleteOrphans(knownContactIds: ["a"], directorySynced: false), 0)
        XCTAssertEqual(s.recordCount(), 2)
    }

    func testWipeAllDeletesTheRecordsMetaBinAndTheKey() throws {
        let vault = VoiceMemoryVault()
        let s = store(vaultAead(vault))
        for c in ["a", "b"] { try s.save(c, record()) }
        try s.wipeAll()
        XCTAssertEqual(names(), [])
        XCTAssertNil(vault.current)
        // the store is usable again afterwards, as a fresh one
        XCTAssertNil(try s.load("a"))
        try s.save("a", record())
        XCTAssertNotNil(try s.load("a"))
    }

    func testAWipeThatCannotReachTheKeyStillDeletesTheFilesAndThrows() throws {
        let vault = VoiceMemoryVault()
        let s = store(vaultAead(vault))
        try s.save("a", record())
        vault.unavailable = true
        assertKind(.key, { try s.wipeAll() })
        XCTAssertEqual(names(), [])
    }

    func testDeleteAllKeepsTheKeyAndStartsAFreshStoreWithANewSalt() throws {
        let vault = VoiceMemoryVault()
        let aead = vaultAead(vault)
        let s = store(aead)
        try s.save("a", record())
        let salt1 = try meta(aead).nameSalt
        let key = try XCTUnwrap(vault.current)
        let removesBefore = vault.removeCount
        s.deleteAll()
        XCTAssertEqual(names(), [])
        XCTAssertEqual(vault.removeCount, removesBefore)
        XCTAssertEqual(vault.current, key)
        try s.save("a", record())
        XCTAssertNotEqual(try meta(vaultAead(vault)).nameSalt, salt1)
    }

    // MARK: one locked operation per contact

    func testUpdateLoadsRunsAndWritesAsOneOperation() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        let first = try s.update(contactId: "c") { current -> TemplateRecord? in
            XCTAssertNil(current)
            return self.record()
        }
        XCTAssertNotNil(first)
        let stored = try XCTUnwrap(try s.load("c"))
        XCTAssertEqual(stored.sessionsSeenTotal, 0)
        try s.update(contactId: "c") { current in
            let r = try XCTUnwrap(current)
            r.sessionsSeenTotal = 5
            return r
        }
        XCTAssertEqual(try s.load("c")?.sessionsSeenTotal, 5)
        // nil deletes
        try s.update(contactId: "c") { _ in nil }
        XCTAssertNil(try s.load("c"))
        // a body that throws writes nothing
        try s.save("c", record())
        struct Boom: Error {}
        XCTAssertThrowsError(try s.update(contactId: "c") { current -> TemplateRecord? in
            current?.sessionsSeenTotal = 9
            throw Boom()
        })
        XCTAssertEqual(try s.load("c")?.sessionsSeenTotal, 0)
    }

    func testUpdateDropsARecordOfAnotherModelBeforeTheBodyRuns() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        let other = record()
        other.modelId[0] ^= 1
        try s.save("c", other)
        var seen: TemplateRecord? = other
        try s.update(contactId: "c", compatibleWith: cfg) { current in
            seen = current
            return nil
        }
        XCTAssertNil(seen)
        XCTAssertEqual(s.recordCount(), 0)
    }

    func testConcurrentUpdatesOfOneContactLoseNothing() throws {
        let s = store(vaultAead(VoiceMemoryVault()))
        try s.save("c", record())
        let threads = 8
        let each = 15
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<each {
                _ = try? s.update(contactId: "c") { current in
                    let r = current ?? self.record()
                    r.sessionsSeenTotal += 1
                    return r
                }
            }
        }
        XCTAssertEqual(try s.load("c")?.sessionsSeenTotal, threads * each)
    }

    // MARK: files on disk

    func testTheDirectoryAndTheFilesAreExcludedFromBackup() throws {
        let target = dir.appendingPathComponent("voice/v3", isDirectory: true)
        let s = store(vaultAead(VoiceMemoryVault(), at: target), directory: target)
        try s.save("c", record())
        let values = try target.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        for name in try fm.contentsOfDirectory(atPath: target.path) {
            let v = try target.appendingPathComponent(name).resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(v.isExcludedFromBackup, true, name)
        }
    }

    func testTheDirectoryIsUnderApplicationSupportVoiceV3() {
        let base = URL(fileURLWithPath: "/app-support", isDirectory: true)
        XCTAssertEqual(VoiceTemplateStore.directoryFor(applicationSupport: base).path, "/app-support/voice/v3")
        XCTAssertEqual(VoiceKeychainVault.account, "qaudion_voice_v3")
    }

    // MARK: directory sync

    // MARK: a directory that cannot be listed

    /// A listing that fails is not "no data": the key stays and the records stay.
    func testAFailingListingAtTheEndOfACallNeverReplacesTheKey() throws {
        let vault = VoiceMemoryVault()
        let s = store(vaultAead(vault))
        try s.save("c", record())
        let k1 = try XCTUnwrap(vault.current)
        let removes = vault.removeCount
        XCTAssertEqual(chmod(dir.path, 0o300), 0)
        defer { _ = chmod(dir.path, 0o700) }
        // the same process: the store and the key are in memory
        _ = try? s.load("c")
        _ = try? s.save("c", record())
        // a new process: the key is read again and the directory cannot be listed
        assertKind(.io, { _ = try self.store(self.vaultAead(vault)).load("c") }, "a listing that fails")
        XCTAssertEqual(vault.current, k1)
        XCTAssertEqual(vault.removeCount, removes)
        XCTAssertEqual(chmod(dir.path, 0o700), 0)
        XCTAssertNotNil(try s.load("c"))
        XCTAssertNotNil(try store(vaultAead(vault)).load("c"))
        XCTAssertEqual(vault.current, k1)
    }

    func testAFailingListingDuringTheFirstMetaBinKeepsTheKeyAndThrowsIo() throws {
        let leftover = VoiceStoreFixtures.keyBytes(SymmetricKey(size: .bits256))
        let vault = VoiceMemoryVault(key: leftover)
        XCTAssertEqual(chmod(dir.path, 0o300), 0)
        defer { _ = chmod(dir.path, 0o700) }
        assertKind(.io, { try self.store(self.vaultAead(vault)).save("c", self.record()) }, "no meta.bin yet, listing fails")
        XCTAssertEqual(vault.current, leftover)
        XCTAssertEqual(vault.removeCount, 0)
        XCTAssertEqual(chmod(dir.path, 0o700), 0)
        XCTAssertEqual(names(), [])
    }

    func testTheDirectorySyncRunsAfterEveryWriteAndAFailingSyncDoesNotFailTheWrite() throws {
        var calls = 0
        let counting = store(vaultAead(VoiceMemoryVault()), dirSync: { _ in calls += 1 })
        try counting.save("c", record())
        XCTAssertGreaterThanOrEqual(calls, 2) // meta.bin and the record
        let before = calls
        try counting.save("c", record())
        XCTAssertEqual(calls, before + 1)

        let failing = store(vaultAead(VoiceMemoryVault()), directory: dir.appendingPathComponent("other", isDirectory: true),
                            dirSync: { _ in throw VoiceStoreError(.io, "no") })
        try failing.save("c", record())
        XCTAssertNotNil(try failing.load("c"))
    }

    func testThePosixDirectorySyncOpensAndSyncsARealDirectory() throws {
        XCTAssertNoThrow(try VoiceDirectorySyncs.posix(dir))
        XCTAssertThrowsError(try VoiceDirectorySyncs.posix(dir.appendingPathComponent("missing", isDirectory: true)))
        // the default sync of a store is this one: a save through it works
        let s = VoiceTemplateStore(dir: dir, aead: vaultAead(VoiceMemoryVault()), accountId: "acct-1")
        try s.save("c", record())
        XCTAssertNotNil(try s.load("c"))
    }
}

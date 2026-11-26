import Foundation
import CryptoKit

/// A storage operation could not be done. `kind` says why; a message never carries a key, a plaintext or a contact id.
///  - `key`: the key is not available (nothing was deleted, the store is just not usable now);
///  - `auth`: a sealed blob did not authenticate (the only kind that lets the store delete the blob);
///  - `io`: a file operation failed;
///  - `malformed`: a record that cannot be written (the encoder refused it).
struct VoiceStoreError: Error, Equatable {
    enum Kind: Equatable {
        case key
        case auth
        case io
        case malformed
    }

    let kind: Kind
    let message: String

    init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// AES-256-GCM with a key that the platform holds. A sealed blob is `nonce (12) || ciphertext || tag (16)`. The caller never
/// supplies a nonce: every `seal` gets a fresh random one from the cipher, so a nonce cannot repeat by a caller's mistake.
protocol VoiceAead: AnyObject {
    func seal(_ plaintext: [UInt8], aad: [UInt8]) throws -> [UInt8]

    /// The plaintext, or throws `VoiceStoreError`: `.auth` when the tag does not match or the blob is too short to hold a nonce and a tag, `.key` for every other failure (the key is not available, the keychain is locked).
    func open(_ sealed: [UInt8], aad: [UInt8]) throws -> [UInt8]

    /// Deletes the key (the owner turns the feature off, wipe). Every blob sealed with it is unreadable afterwards.
    func deleteKey() throws

    /// Whether the key exists. Never creates one. Throws `.key` when the key store cannot be read now.
    func keyExists() throws -> Bool
}

extension VoiceAead {
    /// A key that the platform does not hold in a keychain (the tests) is always there.
    func keyExists() throws -> Bool { true }
}

/// `VoiceAead` over CryptoKit AES-GCM with the key from `key`: an in-memory key in the tests, the Keychain key in the app
/// (`VoiceKeychainAead`). The nonce of an encryption is the one CryptoKit generates; it must be 12 bytes, not all zero and not
/// equal to the previous one, or the seal fails.
final class VoiceAesGcmAead: VoiceAead, @unchecked Sendable {
    static let nonceBytes = 12
    static let tagBytes = 16

    private let key: () throws -> SymmetricKey
    private let onDeleteKey: () throws -> Void
    private let lock = NSLock()
    private var lastNonce: [UInt8]?

    init(key: @escaping () throws -> SymmetricKey, onDeleteKey: @escaping () throws -> Void = {}) {
        self.key = key
        self.onDeleteKey = onDeleteKey
    }

    func seal(_ plaintext: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        try lock.withLock {
            let symmetricKey = try currentKey()
            let box: AES.GCM.SealedBox
            do {
                box = try AES.GCM.seal(Data(plaintext), using: symmetricKey, authenticating: Data(aad))
            } catch {
                throw VoiceStoreError(.key, "sealing failed")
            }
            let nonce = Array(box.nonce)
            if nonce.count != Self.nonceBytes || nonce.allSatisfy({ $0 == 0 }) || nonce == lastNonce {
                throw VoiceStoreError(.key, "cipher gave an unusable nonce")
            }
            guard let combined = box.combined, combined.count == Self.nonceBytes + plaintext.count + Self.tagBytes else {
                throw VoiceStoreError(.key, "unexpected sealed size")
            }
            lastNonce = nonce
            return Array(combined)
        }
    }

    func open(_ sealed: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        try lock.withLock {
            guard sealed.count >= Self.nonceBytes + Self.tagBytes else { throw VoiceStoreError(.auth, "sealed blob too short") }
            let symmetricKey = try currentKey()
            do {
                let box = try AES.GCM.SealedBox(combined: Data(sealed))
                return Array(try AES.GCM.open(box, using: symmetricKey, authenticating: Data(aad)))
            } catch CryptoKitError.authenticationFailure {
                throw VoiceStoreError(.auth, "authentication failed")
            } catch {
                throw VoiceStoreError(.key, "opening failed")
            }
        }
    }

    func deleteKey() throws {
        try onDeleteKey()
    }

    private func currentKey() throws -> SymmetricKey {
        do {
            return try key()
        } catch let error as VoiceStoreError {
            throw error
        } catch {
            throw VoiceStoreError(.key, "key not available")
        }
    }
}

/// Makes a rename durable by syncing the directory.
typealias VoiceDirectorySync = (URL) throws -> Void

enum VoiceDirectorySyncs {
    /// `open(O_RDONLY)` and `fsync` on the directory.
    static let posix: VoiceDirectorySync = { dir in
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { throw VoiceStoreError(.io, "directory not opened") }
        defer { _ = close(fd) }
        guard fsync(fd) == 0 else { throw VoiceStoreError(.io, "directory not synced") }
    }

    static let none: VoiceDirectorySync = { _ in }
}

/// `meta.bin`, learner-side data only: install id, SHA-256 of the account id and the salt of the file names.
struct VoiceMeta: Equatable {
    static let version = 2
    static let size = 4 + 2 + 16 + 32 + 32
    private static let magic: [UInt8] = [0x51, 0x41, 0x56, 0x4D] // QAVM

    let installId: [UInt8]
    let accountHash: [UInt8]
    let nameSalt: [UInt8]

    func encode() -> [UInt8] {
        Self.magic + [UInt8(Self.version & 0xFF), UInt8(Self.version >> 8)] + installId + accountHash + nameSalt
    }

    /// Strict: exactly the bytes `encode` writes, or nil.
    static func decode(_ b: [UInt8]) -> VoiceMeta? {
        guard b.count == size, Array(b[0..<4]) == magic else { return nil }
        guard Int(b[4]) | (Int(b[5]) << 8) == version else { return nil }
        return VoiceMeta(installId: Array(b[6..<22]), accountHash: Array(b[22..<54]), nameSalt: Array(b[54..<86]))
    }
}

/// The encrypted store of the learned-voice records of one account: one file per contact plus `meta.bin`, in `dir`
/// (`directoryFor(applicationSupport:)`, excluded from backups).
///
/// File name: the first 32 hex characters of SHA-256(name_salt || UTF-8(contact id lowercase)) + `.qvt`, so a directory
/// listing does not reveal contact ids. File content: `VoiceAead` blob, AAD = UTF-8 `QAVT|3|<accountId>|<contactId lowercase>`,
/// so a file moved to another name, contact or account does not open. `meta.bin`: AAD `QAVM|2|<accountId>`.
///
/// Writes: the data goes to a temp file, is fsynced, gets the file protection class and the backup exclusion, and replaces the
/// old file by rename; the directory is then fsynced through `dirSync`. After a crash the old record or no record is there,
/// never a torn file; a rename that was not yet durable may be lost.
///
/// A copy of an older authentic file of the same contact opens, because the AAD carries no counter.
///
/// What deletes what:
///  - a record file that fails AES-GCM authentication or is too short to hold a nonce and a tag (`.auth`), that is larger than
///    any record, or that authenticates but does not decode or cannot be used, is deleted and reads as "no record";
///  - a `meta.bin` that fails authentication or is too short, that authenticates but is not a meta file, or that belongs to
///    another account, wipes the learner data and starts fresh;
///  - every transient failure (I/O errors, a CryptoKit error other than an authentication failure, the Keychain not available
///    while the device is locked, a missing key: `.io` and `.key`) throws and deletes nothing, the files stay as they are.
///
/// Callers:
///  - one store instance and one `VoiceAead` instance per process (the locks are per instance);
///  - load, end-of-call update and save run as ONE per-contact operation: `update(contactId:...)`, so that a delete or a sweep is
///    not undone by a save of an older copy;
///  - never call `deleteOrphans` with an empty or not yet synced contact list (the method refuses);
///  - every method is synchronous and blocks on file I/O, fsync and the Keychain: call it from a background queue;
///  - the closure of `update` runs under the store lock and must not call the store;
///  - `wipeAll()` is the deletion of everything including the key.
final class VoiceTemplateStore: @unchecked Sendable {
    static let metaFile = "meta.bin"
    static let ext = ".qvt"
    static let tmp = ".tmp"
    private static let sealOverhead = VoiceAesGcmAead.nonceBytes + VoiceAesGcmAead.tagBytes

    private let dir: URL
    private let aead: VoiceAead
    private let accountId: String
    private let dirSync: VoiceDirectorySync
    /// The wipe generation of the process. An operation that carries the generation its caller read is refused, inside the lock
    /// and before `meta.bin`, the key or any file is touched, once the generation has moved on.
    private let generationProbe: () -> Int
    private let fm = FileManager.default
    private let lock = NSLock()
    private var meta: VoiceMeta?

    init(dir: URL, aead: VoiceAead, accountId: String, dirSync: @escaping VoiceDirectorySync = VoiceDirectorySyncs.posix,
         generationProbe: @escaping () -> Int = { 0 }) {
        self.dir = dir
        self.aead = aead
        self.accountId = accountId
        self.dirSync = dirSync
        self.generationProbe = generationProbe
    }

    /// Called first inside the lock by every operation that may create `meta.bin` or the key.
    private func admit(_ generation: Int?) throws {
        if let generation, generationProbe() != generation { throw VoiceStaleCall() }
    }

    /// `<Application Support>/voice/v3/`.
    static func directoryFor(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("voice", isDirectory: true).appendingPathComponent("v3", isDirectory: true)
    }

    /// True when `meta.bin` or a record file is in `dir`. A directory that does not exist has no data; a directory that cannot be
    /// listed throws `.io`: that is never an answer.
    static func dataExists(in dir: URL) throws -> Bool {
        let names = try listing(of: dir)
        return names.contains { $0 == metaFile || $0.hasSuffix(ext) }
    }

    /// True when at least one record file is in `dir` (`meta.bin` alone is not a record).
    static func recordsExist(in dir: URL) throws -> Bool {
        try listing(of: dir).contains { $0.hasSuffix(ext) }
    }

    private static func listing(of dir: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        do {
            return try FileManager.default.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw VoiceStoreError(.io, "directory not listable")
        }
    }

    // MARK: names

    private var metaURL: URL { dir.appendingPathComponent(Self.metaFile) }
    private var metaAad: [UInt8] { Array("QAVM|\(VoiceMeta.version)|\(accountId)".utf8) }

    private func recordAad(_ contactLower: String) -> [UInt8] {
        Array("QAVT|\(TemplateCodec.formatVersion)|\(accountId)|\(contactLower)".utf8)
    }

    private func lower(_ contactId: String) -> String { contactId.lowercased() }

    private func sha256(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: Data(p)) }
        return Array(h.finalize())
    }

    func fileName(salt: [UInt8], contactId: String) -> String {
        let h = sha256(salt, Array(lower(contactId).utf8))
        return h.prefix(16).map { String(format: "%02x", $0) }.joined() + Self.ext
    }

    private func randomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// The names in `dir`; a failure to list is `.io`.
    private func listing() throws -> [String] {
        try Self.listing(of: dir)
    }

    /// The names in `dir` for the cleanups that are best effort: nothing when the directory cannot be listed.
    private func names() -> [String] {
        (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // MARK: meta.bin

    private func prepareDirectory() throws {
        do {
            #if os(iOS)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #else
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            #endif
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
            #endif
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw VoiceStoreError(.io, "directory not available")
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = dir
            try mutable.setResourceValues(values)
        } catch let error as VoiceStoreError {
            throw error
        } catch {
            throw VoiceStoreError(.io, "directory not available")
        }
    }

    /// The loaded or created `meta.bin`. A `meta.bin` that does not authenticate or that belongs to another account wipes the
    /// learner data and a new one is made; any other failure throws and leaves everything as it is.
    private func ensureMeta() throws -> VoiceMeta {
        if let meta { return meta }
        try prepareDirectory()
        let listed = try listing() // a listing that fails is .io: nothing below is decided without it
        for name in listed where name.hasSuffix(Self.tmp) { try? fm.removeItem(at: dir.appendingPathComponent(name)) } // a write that was cut short
        let accountHash = sha256(Array(accountId.utf8))
        let metaPresent = listed.contains(Self.metaFile)
        if metaPresent {
            let sealed = try readFile(metaURL)
            do {
                let plain = try aead.open(sealed, aad: metaAad)
                if let decoded = VoiceMeta.decode(plain), decoded.accountHash == accountHash {
                    meta = decoded
                    return decoded
                }
                // another account, or authentic bytes that are not a meta file: the record files cannot be named, so they go
            } catch let error as VoiceStoreError where error.kind == .auth {
                // the key or the account is not the one that sealed it: the learner data goes
            }
        }
        if !metaPresent && !listed.contains(where: { $0.hasSuffix(Self.ext) }) {
            // No meta.bin and no record: a key that is already in the keychain is a leftover of a deleted installation (the
            // keychain outlives the app). This is the one place where that is decided.
            try aead.deleteKey()
        }
        deleteRecordFiles()
        try? fm.removeItem(at: metaURL)
        let fresh = VoiceMeta(installId: randomBytes(16), accountHash: accountHash, nameSalt: randomBytes(32))
        try writeAtomic(metaURL, try aead.seal(fresh.encode(), aad: metaAad))
        meta = fresh
        return fresh
    }

    /// Makes sure `meta.bin` is there (and the directory) without touching a record.
    func prepare() throws {
        try lock.withLock { _ = try ensureMeta() }
    }

    // MARK: records

    private func fileURL(_ contactId: String) throws -> URL {
        dir.appendingPathComponent(fileName(salt: try ensureMeta().nameSalt, contactId: contactId))
    }

    private func readFile(_ url: URL) throws -> [UInt8] {
        do {
            return [UInt8](try Data(contentsOf: url))
        } catch {
            throw VoiceStoreError(.io, "file not readable")
        }
    }

    private func loadLocked(_ contactId: String) throws -> TemplateRecord? {
        let url = try fileURL(contactId)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let maxSize = TemplateCodec.sizeOf(state: TemplateState.learning, nSessions: TemplateCodec.maxSessions) + Self.sealOverhead
        let length = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if length > maxSize { // no record is this large
            try? fm.removeItem(at: url)
            return nil
        }
        let sealed = try readFile(url)
        var plain: [UInt8]
        do {
            plain = try aead.open(sealed, aad: recordAad(lower(contactId)))
        } catch let error as VoiceStoreError where error.kind == .auth {
            try? fm.removeItem(at: url)
            return nil
        }
        defer { for i in plain.indices { plain[i] = 0 } }
        // authentic bytes that are not a record, or a record the engine cannot use: nothing to keep, the contact is learned again
        guard let rec = try? TemplateCodec.decode(plain), rec.isUsable() else {
            try? fm.removeItem(at: url)
            return nil
        }
        return rec
    }

    private func loadCompatibleLocked(_ contactId: String, _ cfg: VoiceStateConstants) throws -> TemplateRecord? {
        guard let rec = try loadLocked(contactId) else { return nil }
        if VoiceTemplateState.isCompatible(rec, modelId: cfg.modelId, frontendVersion: cfg.frontendVersion) { return rec }
        _ = try deleteLocked(contactId)
        return nil
    }

    private func saveLocked(_ contactId: String, _ rec: TemplateRecord) throws {
        var plain = try encodeForStore(rec)
        defer { for i in plain.indices { plain[i] = 0 } }
        try writeAtomic(try fileURL(contactId), try aead.seal(plain, aad: recordAad(lower(contactId))))
    }

    private func encodeForStore(_ rec: TemplateRecord) throws -> [UInt8] {
        do {
            return try TemplateCodec.encode(rec)
        } catch {
            throw VoiceStoreError(.malformed, "record cannot be written")
        }
    }

    /// True when `meta.bin` is loaded or on disk: only then can a record be named. Never creates anything.
    private func hasMeta() -> Bool {
        meta != nil || fm.fileExists(atPath: metaURL.path)
    }

    /// Removes every record file when there is no `meta.bin` to name them by (they cannot be read any more); never creates
    /// `meta.bin` or the key. True when a file was removed.
    private func deleteStrayRecords() -> Bool {
        var any = false
        for name in names() where name.hasSuffix(Self.ext) {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { any = true }
        }
        return any
    }

    /// True when `meta.bin` is there AND the key exists (after the key rule's repeated looks): only then can a record be read or
    /// named. When it is not, nothing is created and NOTHING IS DELETED: a missing key is cleaned up only by `ensureMeta`'s own rule.
    /// A key store that cannot be read now throws.
    private func readableData() throws -> Bool {
        if !hasMeta() { return false }
        return try aead.keyExists()
    }

    private func deleteLocked(_ contactId: String) throws -> Bool {
        if !hasMeta() { return deleteStrayRecords() } // a deletion never creates `meta.bin` or the key
        if try !aead.keyExists() { return false }
        let url = try fileURL(contactId)
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw VoiceStoreError(.io, "record not deletable")
        }
        return true
    }

    /// The record of a contact, or nil when there is none or its file did not authenticate (then the file is deleted). Throws
    /// `VoiceStoreError` for every other failure; nothing is deleted in that case.
    func load(_ contactId: String) throws -> TemplateRecord? {
        try lock.withLock { try loadLocked(contactId) }
    }

    /// `load`, then: a record of another model or front-end version is deleted (relearn).
    func loadCompatible(_ contactId: String, _ cfg: VoiceStateConstants, generation: Int? = nil) throws -> TemplateRecord? {
        try lock.withLock {
            try admit(generation)
            return try loadCompatibleLocked(contactId, cfg)
        }
    }

    /// Encrypts and writes the record (temp file, fsync, rename, directory fsync). Throws and leaves the old file when anything fails.
    func save(_ contactId: String, _ rec: TemplateRecord) throws {
        try lock.withLock { try saveLocked(contactId, rec) }
    }

    /// The one locked operation of a contact: load (and, with `cfg`, drop a record of another model), run `body`, then write
    /// what it returns (nil deletes the record). Nothing else can change this contact's file in between. A failure of the
    /// load throws before `body` runs; a failure of `body` throws before anything is written. Returns what was stored.
    @discardableResult
    func update(contactId: String, compatibleWith cfg: VoiceStateConstants? = nil, generation: Int? = nil,
                _ body: (TemplateRecord?) throws -> TemplateRecord?) throws -> TemplateRecord? {
        try lock.withLock {
            try admit(generation)
            let current: TemplateRecord?
            if let cfg {
                current = try loadCompatibleLocked(contactId, cfg)
            } else {
                current = try loadLocked(contactId)
            }
            let next = try body(current)
            if let next {
                try saveLocked(contactId, next)
            } else {
                _ = try deleteLocked(contactId)
            }
            return next
        }
    }

    /// Forget this voice: contact deleted or blocked, retention, model change. True when a file was there.
    @discardableResult
    func delete(_ contactId: String, generation: Int? = nil) throws -> Bool {
        try lock.withLock {
            try admit(generation)
            return try deleteLocked(contactId)
        }
    }

    /// Runs the sweep on one contact: the record is deleted (retention) or rewritten when something was purged.
    func sweep(_ contactId: String, nowS: Int, _ cfg: VoiceStateConstants, generation: Int? = nil) throws -> SweepResult? {
        try lock.withLock {
            try admit(generation)
            if try !readableData() { return nil } // nothing can be named, and a sweep never creates `meta.bin` or the key
            guard let rec = try loadCompatibleLocked(contactId, cfg) else { return nil }
            let r = VoiceTemplateState.sweep(rec, nowS: nowS, cfg)
            if let kept = r.record {
                if !r.purged.isEmpty || !r.idleSlots.isEmpty { try saveLocked(contactId, kept) }
            } else {
                _ = try deleteLocked(contactId)
            }
            return r
        }
    }

    /// Deletes the record files of contacts that are not in `knownContactIds` (a contact removed while the app did not run)
    /// and returns how many. It does nothing and returns 0 when the contact list is empty or `directorySynced` is false:
    /// an empty or not yet synced list would delete every record.
    func deleteOrphans(knownContactIds: [String], directorySynced: Bool, generation: Int? = nil) throws -> Int {
        guard directorySynced, !knownContactIds.isEmpty else { return 0 }
        return try lock.withLock {
            try admit(generation)
            if try !readableData() { return 0 } // no salt or no key: nothing can be known, and nothing is created
            let salt = try ensureMeta().nameSalt
            let keep = Set(knownContactIds.map { fileName(salt: salt, contactId: $0) })
            var n = 0
            for name in names() where name.hasSuffix(Self.ext) && !keep.contains(name) {
                if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { n += 1 }
            }
            return n
        }
    }

    /// The salt of the file names (creates `meta.bin` when there is none): the device tag of a peer is derived from it.
    func nameSalt(generation: Int? = nil) throws -> [UInt8] {
        try lock.withLock {
            try admit(generation)
            return try ensureMeta().nameSalt
        }
    }

    /// What the owner sees of the learned voices of `contactIds`: only the contacts that have a usable record are in the map. Reads
    /// only: with no `meta.bin` there is nothing to read, and nothing (file, key) is created.
    func summaries(contactIds: [String], cfg: VoiceStateConstants, generation: Int? = nil) throws -> [String: ContactVoiceSummary] {
        try lock.withLock {
            try admit(generation)
            if try !readableData() { return [:] }
            var out: [String: ContactVoiceSummary] = [:]
            for id in contactIds {
                if let rec = try? loadCompatibleLocked(id, cfg) { out[id] = ContactVoiceSummary.of(rec, cfg) }
            }
            return out
        }
    }

    func recordCount() -> Int {
        lock.withLock { names().filter { $0.hasSuffix(Self.ext) }.count }
    }

    // MARK: deletion of everything

    /// Deletes every record and `meta.bin`, keeps the key (a different account logged in). The next call starts a fresh store.
    func deleteAll() {
        lock.withLock { deleteAllLocked() }
    }

    private func deleteAllLocked() {
        meta = nil
        deleteRecordFiles()
        try? fm.removeItem(at: metaURL)
        for name in names() where name.hasSuffix(Self.tmp) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }

    /// The owner turns the learner feature off, logout, account or remote wipe: every record, `meta.bin` and the key. The files
    /// are deleted first; a failure to delete the key is thrown after that.
    func wipeAll() throws {
        try lock.withLock {
            meta = nil
            var failure: Error?
            for name in names() where name.hasSuffix(Self.ext) || name.hasSuffix(Self.tmp) || name == Self.metaFile {
                do {
                    try fm.removeItem(at: dir.appendingPathComponent(name))
                } catch {
                    failure = failure ?? VoiceStoreError(.io, "file not deleted")
                }
            }
            do {
                try aead.deleteKey()
            } catch {
                failure = failure ?? error
            }
            if let failure { throw failure }
        }
    }

    private func deleteRecordFiles() {
        for name in names() where name.hasSuffix(Self.ext) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }

    // MARK: atomic write

    private func writeSynced(_ url: URL, _ bytes: [UInt8]) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw VoiceStoreError(.io, "file not created") }
        defer { _ = close(fd) }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress! + offset, bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw VoiceStoreError(.io, "file not written")
            }
            offset += written
        }
        guard fsync(fd) == 0 else { throw VoiceStoreError(.io, "file not synced") }
    }

    private func writeAtomic(_ target: URL, _ bytes: [UInt8]) throws {
        let temp = dir.appendingPathComponent(target.lastPathComponent + Self.tmp)
        do {
            try writeSynced(temp, bytes)
            #if os(iOS)
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temp.path)
            #endif
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = temp
            try? mutable.setResourceValues(values)
            guard rename(temp.path, target.path) == 0 else { throw VoiceStoreError(.io, "rename failed") }
        } catch {
            try? fm.removeItem(at: temp)
            if let error = error as? VoiceStoreError { throw error }
            throw VoiceStoreError(.io, "file not writable")
        }
        // The rename is done; a directory sync that fails leaves the old record or none after a crash, never a torn file.
        try? dirSync(dir)
    }
}

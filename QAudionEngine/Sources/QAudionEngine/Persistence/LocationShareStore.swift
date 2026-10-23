import Foundation
import GRDB
#if canImport(Security)
import Security
#endif

// The durable side of live location shares (docs/LOCATION_SHARING.md 1.3), on the local database (`live_shares`, migration v10):
//
//  - `GRDBLocationShareStore`: the `LocationShareStore` of ONE 1:1 conversation (the receiver of the shares of one peer). Records, the
//    tombstones of a stop or a delete that overtook its start, and the share key, which lives in the Keychain and nowhere else. A record
//    is keyed by (peer, client message id) and its Keychain item is `<peer>/<client message id>`: the id alone is chosen by the sender.
//  - `GRDBLocationShareJournal`: the note a sending process leaves for the next one (which start, how far it got, whether its stop went
//    out). No key, no counter, no `sid`, no coordinates.
//  - `LocationShareSchema`: the tables, shared by the migration and the tests.
//
// What is stored where, and what is not:
//  - the share key `k` of a received share: Keychain only (`AfterFirstUnlockThisDeviceOnly`: a start arrives while the phone is locked,
//    and a restore or a migration to another phone leaves the key behind, so that share ends as `state_lost` instead of resuming);
//  - the moving position and the counter of the last frame: ONE sealed column (`LocalStoreCipher`, the cipher of the message bodies), so
//    that a position is never a plain column of the database file; a share that ends deletes it;
//  - the client message id and the `sid` of every start, with the end time: plain columns, never deleted by a clear, a delete for me or
//    a logout (WIRE_SPEC 14.6.2 step 1). Only `wipeEverything` (account deletion, a wipe of all app data, a logout that erases the
//    database) takes them away, and `purgeEnded`, once both `TOMBSTONE_KEEP` seconds after the end and `st + du + SKEW` have passed.
// The sender's key and counter are NOT here: they live in the memory of the process that runs the share (14.6.1 rule 9).
//
// Nothing here logs, prints or describes a position, a key or a body.

// MARK: - Schema

public enum LocationShareSchema {

    public static func create(in db: Database) throws {
        try db.create(table: "live_shares") { t in
            // The key of a record is the pair: the client message id of a start is chosen by the sender, so another peer can send a start
            // under the id of one of mine, and that must never reach my record (WIRE_SPEC 14.6.2 step 1 is per conversation).
            t.column("id", .text).notNull()
            t.column("peerUserId", .text).notNull()
            t.column("sid", .blob).notNull()
            t.column("endAt", .integer).notNull()
            t.column("ord", .integer).notNull()
            t.column("arrival", .integer).notNull()
            t.column("endReason", .text)
            t.column("endedAt", .integer)
            t.column("noCard", .boolean).notNull().defaults(to: false)
            // The counter of the last frame, the moment it arrived, the interval it announced and the position, sealed together.
            t.column("liveSealed", .text)
            // `st + du + SKEW` of the start: an ended record is forgotten only after this moment too (see `purgeEnded`).
            t.column("replayUntil", .integer).notNull().defaults(to: 0)
            t.primaryKey(["peerUserId", "id"])
        }
        try db.create(table: "live_share_tombstones") { t in
            t.column("peerUserId", .text).notNull()
            t.column("target", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("until", .integer).notNull()
            t.column("seq", .integer).notNull()
            t.primaryKey(["peerUserId", "target"])
        }
        try db.create(table: "live_share_journal") { t in
            t.column("startClientMsgId", .text).primaryKey()
            t.column("phase", .text).notNull()
            t.column("stopSent", .boolean).notNull().defaults(to: false)
        }
    }
}

// MARK: - Share keys

/// Where the share key of a received share is kept.
public protocol LocationShareKeyStorage: AnyObject {
    func key(forShare id: String) -> Data?
    func save(_ key: Data, forShare id: String) throws
    func delete(forShare id: String)
    func deleteAll()
}

public final class InMemoryLocationShareKeyStorage: LocationShareKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    public init() {}

    public func key(forShare id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys[id]
    }

    public func save(_ key: Data, forShare id: String) throws {
        lock.lock()
        keys[id] = key
        lock.unlock()
    }

    public func delete(forShare id: String) {
        lock.lock()
        keys[id] = nil
        lock.unlock()
    }

    public func deleteAll() {
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }
}

/// The Keychain: a generic password per share, this device only, never synchronised, never in a backup.
public final class KeychainLocationShareKeyStorage: LocationShareKeyStorage, @unchecked Sendable {

    public struct WriteFailure: Error {
        public let status: Int32
    }

    private static let service = "com.bcrypto.qaudion.locshare.key"

    public init() {}

    public func key(forShare id: String) -> Data? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return data
        #else
        return nil
        #endif
    }

    public func save(_ key: Data, forShare id: String) throws {
        #if canImport(Security)
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id
        ]
        SecItemDelete(match as CFDictionary)
        var add: [String: Any] = match
        add[kSecValueData as String] = key
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw WriteFailure(status: status) }
        #else
        throw WriteFailure(status: -1)
        #endif
    }

    public func delete(forShare id: String) {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }

    public func deleteAll() {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ]
        SecItemDelete(query as CFDictionary)
        #endif
    }
}

// MARK: - Rows

struct LiveShareRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "live_shares"

    var id: String
    var peerUserId: String
    var sid: Data
    var endAt: Int64
    var ord: Int64
    var arrival: Int
    var endReason: String?
    var endedAt: Int64?
    var noCard: Bool
    var liveSealed: String?
    var replayUntil: Int64
}

/// The sealed part of a live record. Short keys: it is a value inside a sealed column, not a wire format.
struct LiveShareLivePayload: Codable {
    var c: UInt32
    var f: Int64
    var i: Int64
    var la: Int32
    var lo: Int32
    var ac: Int
    var ap: Bool
    var fx: Int64
}

struct LiveShareTombstoneRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "live_share_tombstones"

    var peerUserId: String
    var target: String
    var reason: String
    var until: Int64
    var seq: Int
}

struct LiveShareJournalRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "live_share_journal"

    var startClientMsgId: String
    var phase: String
    var stopSent: Bool
}

// MARK: - The store of one conversation

public final class GRDBLocationShareStore: LocationShareStore {

    public struct StorageFailure: Error {}

    private let peerUserId: String
    private let writerProvider: () -> DatabaseWriter
    private let keys: LocationShareKeyStorage

    /// The store of the conversation with `peerUserId`, on the app database and the Keychain.
    public convenience init(peerUserId: String) {
        self.init(peerUserId: peerUserId, writerProvider: { QAudionDatabase.shared.writer },
                  keys: KeychainLocationShareKeyStorage())
    }

    public init(peerUserId: String, writerProvider: @escaping () -> DatabaseWriter, keys: LocationShareKeyStorage) {
        self.peerUserId = peerUserId
        self.writerProvider = writerProvider
        self.keys = keys
    }

    public func load() throws -> LocationShareStoreContents {
        let peer = peerUserId
        return try writerProvider().read { db in
            let rows = try LiveShareRow
                .filter(Column("peerUserId") == peer)
                .order(Column("arrival").asc)
                .fetchAll(db)
            let records: [LiveShareRecord] = rows.map { Self.record(from: $0) }
            let tombstoneRows = try LiveShareTombstoneRow
                .filter(Column("peerUserId") == peer)
                .order(Column("seq").asc)
                .fetchAll(db)
            let tombstones: [LocationTombstone] = tombstoneRows.compactMap { row in
                guard let reason = LocationTombstone.Reason(rawValue: row.reason) else { return nil }
                return LocationTombstone(target: row.target, reason: reason, until: row.until)
            }
            return LocationShareStoreContents(records: records, tombstones: tombstones)
        }
    }

    /// Inserts or replaces one record. Durable when it returns: a failure throws, and the receiver then ends the share as `state_lost`.
    public func save(_ record: LiveShareRecord) throws {
        let row: LiveShareRow = try Self.row(from: record, peerUserId: peerUserId)
        try writerProvider().write { db in
            try row.save(db)
        }
    }

    public func saveTombstones(_ tombstones: [LocationTombstone]) throws {
        let peer = peerUserId
        try writerProvider().write { db in
            try LiveShareTombstoneRow.filter(Column("peerUserId") == peer).deleteAll(db)
            var seq = 0
            for tombstone in tombstones {
                let row = LiveShareTombstoneRow(peerUserId: peer, target: tombstone.target,
                                                reason: tombstone.reason.rawValue, until: tombstone.until, seq: seq)
                try row.save(db)
                seq += 1
            }
        }
    }

    /// The Keychain account of the key of a share of this conversation: the peer and the client message id, so that two peers that use
    /// the same client message id never share an item.
    func keyAccount(forShare id: String) -> String {
        peerUserId + "/" + id
    }

    public func shareKey(forShare id: String) -> Data? {
        keys.key(forShare: keyAccount(forShare: id))
    }

    public func saveShareKey(_ key: Data, forShare id: String) throws {
        try keys.save(key, forShare: keyAccount(forShare: id))
    }

    public func deleteShareKey(forShare id: String) {
        keys.delete(forShare: keyAccount(forShare: id))
    }

    // MARK: Mapping

    static func row(from record: LiveShareRecord, peerUserId: String) throws -> LiveShareRow {
        var sealed: String?
        if let live = record.live {
            let payload = LiveShareLivePayload(
                c: live.lastCounter, f: live.lastFrameAt, i: live.interval, la: live.position.latE7, lo: live.position.lonE7,
                ac: live.position.accuracy, ap: live.position.approximate, fx: live.position.fixAt)
            let data = try JSONEncoder().encode(payload)
            sealed = try LocalStoreCipher.seal(String(decoding: data, as: UTF8.self))
        }
        return LiveShareRow(
            id: record.id, peerUserId: peerUserId, sid: record.sid, endAt: record.endAt, ord: record.ord,
            arrival: record.arrival, endReason: record.endReason?.rawValue, endedAt: record.endedAt, noCard: record.noCard,
            liveSealed: sealed, replayUntil: record.replayBound)
    }

    static func record(from row: LiveShareRow) -> LiveShareRecord {
        let reason: LiveShareEndReason? = row.endReason.flatMap { LiveShareEndReason(rawValue: $0) }
        var live: LiveShareLiveState?
        if row.endReason == nil, let sealed = row.liveSealed, let text = LocalStoreCipher.open(sealed),
           let payload = try? JSONDecoder().decode(LiveShareLivePayload.self, from: Data(text.utf8)) {
            let position = LiveSharePosition(latE7: payload.la, lonE7: payload.lo, accuracy: payload.ac,
                                             approximate: payload.ap, fixAt: payload.fx)
            live = LiveShareLiveState(lastCounter: payload.c, lastFrameAt: payload.f, interval: payload.i, position: position)
        }
        // A record that is not ended and whose sealed state cannot be read back has no live state: the receiver ends it as `state_lost`.
        return LiveShareRecord(id: row.id, sid: row.sid, endAt: row.endAt, ord: row.ord, arrival: row.arrival,
                               endReason: reason, endedAt: row.endedAt, noCard: row.noCard, live: live, replayBound: row.replayUntil)
    }

    // MARK: Whole-store operations

    /// The deletion of the whole local store: account deletion, a wipe of all app data, a logout that erases the database. The two
    /// ids of every start go with it, and every key.
    public static func wipeEverything(writer: DatabaseWriter, keys: LocationShareKeyStorage) {
        keys.deleteAll()
        do {
            try writer.write { db in
                _ = try LiveShareRow.deleteAll(db)
                _ = try LiveShareTombstoneRow.deleteAll(db)
                _ = try LiveShareJournalRow.deleteAll(db)
            }
        } catch {
            print("[LocationShareStore] wipe saved=0")
        }
    }

    public static func wipeEverything() {
        wipeEverything(writer: QAudionDatabase.shared.writer, keys: KeychainLocationShareKeyStorage())
    }

    /// Forgets the ids of ended shares that no longer need remembering. A record goes only when BOTH hold: `TOMBSTONE_KEEP` seconds have
    /// passed since it ended, and `now >= st + du + SKEW` (`replayUntil`), the moment after which a redelivered copy of its start is
    /// born ended (its end time is at most that). Before then the two ids are what stops a replayed start from creating a fresh record
    /// with a counter of 0 that would accept every recorded frame again. A live record is never touched. The tombstones whose time has
    /// passed go too. Returns the number of records forgotten.
    @discardableResult
    public static func purgeEnded(writer: DatabaseWriter, now: Int64) -> Int {
        do {
            return try writer.write { db in
                try db.execute(
                    sql: "DELETE FROM live_shares WHERE endReason IS NOT NULL AND endedAt IS NOT NULL AND endedAt + ? <= ? AND replayUntil <= ?",
                    arguments: [LocationWire.tombstoneKeep, now, now])
                let forgotten: Int = db.changesCount
                try db.execute(sql: "DELETE FROM live_share_tombstones WHERE until <= ?", arguments: [now])
                return forgotten
            }
        } catch {
            return 0
        }
    }

    public static func purgeEnded(now: Int64) {
        purgeEnded(writer: QAudionDatabase.shared.writer, now: now)
    }

    /// The live records of every conversation that are not ended, for the list of active shares and the end-of-flag sweep:
    /// `(peerUserId, id, endAt)`.
    public static func activeShares(writer: DatabaseWriter) -> [(peerUserId: String, id: String, endAt: Int64)] {
        do {
            return try writer.read { db in
                try LiveShareRow
                    .filter(Column("endReason") == nil)
                    .fetchAll(db)
                    .map { (peerUserId: $0.peerUserId, id: $0.id, endAt: $0.endAt) }
            }
        } catch {
            return []
        }
    }
}

// MARK: - The sender's journal

public final class GRDBLocationShareJournal: LocationShareJournal {

    private let writerProvider: () -> DatabaseWriter

    public convenience init() {
        self.init(writerProvider: { QAudionDatabase.shared.writer })
    }

    public init(writerProvider: @escaping () -> DatabaseWriter) {
        self.writerProvider = writerProvider
    }

    public func write(_ entry: LocationShareJournalEntry) {
        let row = LiveShareJournalRow(startClientMsgId: entry.startClientMsgId, phase: entry.phase.rawValue, stopSent: entry.stopSent)
        do {
            try writerProvider().write { db in
                try row.save(db)
            }
        } catch {
            print("[LocationShareJournal] write saved=0")
        }
    }

    public func clear(startClientMsgId: String) {
        do {
            try writerProvider().write { db in
                _ = try LiveShareJournalRow.filter(key: startClientMsgId).deleteAll(db)
            }
        } catch {
            print("[LocationShareJournal] clear saved=0")
        }
    }

    public func entries() -> [LocationShareJournalEntry] {
        do {
            return try writerProvider().read { db in
                try LiveShareJournalRow.fetchAll(db).compactMap { row in
                    guard let phase = LocationShareJournalEntry.Phase(rawValue: row.phase) else { return nil }
                    return LocationShareJournalEntry(startClientMsgId: row.startClientMsgId, phase: phase, stopSent: row.stopSent)
                }.sorted { $0.startClientMsgId < $1.startClientMsgId }
            }
        } catch {
            return []
        }
    }
}

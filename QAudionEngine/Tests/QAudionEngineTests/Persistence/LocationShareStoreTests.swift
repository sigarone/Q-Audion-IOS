import XCTest
import GRDB
@testable import QAudionEngine

/// The durable side of live shares (docs/LOCATION_SHARING.md 1.3): the receiver over `GRDBLocationShareStore`, reloaded from the
/// database as a restart would, the sealed position column, the tombstones, the sender's journal and the deletion of the whole store.
final class LocationShareStoreTests: XCTestCase {

    private let selfId = "a353aefc-1716-4516-9ffc-3f8d69ffe0b8"
    private let peerId = "b9d7540f-ece4-4b58-b03b-e0001e522085"
    private let sid = Data((0..<16).map { UInt8($0) })
    private let key = Data((32..<64).map { UInt8($0) })

    private var queue: DatabaseQueue!
    private var keys: InMemoryLocationShareKeyStorage!

    override func setUpWithError() throws {
        try super.setUpWithError()
        LocalStoreCipher.testKeyOverride = Data(repeating: 0x5c, count: 32)
        queue = try DatabaseQueue()
        try queue.write { db in try LocationShareSchema.create(in: db) }
        keys = InMemoryLocationShareKeyStorage()
    }

    override func tearDown() {
        LocalStoreCipher.testKeyOverride = nil
        queue = nil
        keys = nil
        super.tearDown()
    }

    /// The key storage account of the key of share `id` of the conversation with `peer` (default: the main peer of these tests).
    private func account(_ id: String, peer: String? = nil) -> String {
        (peer ?? peerId) + "/" + id
    }

    private func makeStore(peer: String? = nil) -> GRDBLocationShareStore {
        let writer: DatabaseQueue = queue
        return GRDBLocationShareStore(peerUserId: peer ?? peerId, writerProvider: { writer }, keys: keys)
    }

    private func makeReceiver(now: Int64) throws -> LocationShareReceiver {
        try LocationShareReceiver(selfId: selfId, peerId: peerId, store: makeStore(), now: now)
    }

    private func liveStart(sid: Data? = nil, startedAt: Int64 = 1_000, duration: Int64 = 3_600) -> (LocationLiveStart, LocationPosition) {
        (LocationLiveStart(sid: sid ?? self.sid, key: key, startedAt: startedAt, duration: duration),
         LocationPosition(latE7: 454_642_110, lonE7: 91_899_820, accuracy: 12, age: 3, approximate: false))
    }

    private func sealedFrame(counter: UInt32, plaintext: LocationFramePlaintext) throws -> String {
        let frameKeys = try XCTUnwrap(LocationFrameKeys(sid: sid, shareKey: key))
        return try XCTUnwrap(LocationFrameCodec.seal(plaintext, counter: counter, keys: frameKeys, senderId: peerId, recipientId: selfId)).base64
    }

    // MARK: A share survives a restart

    func testTheShareAndItsPositionSurviveAReload() throws {
        let first = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        XCTAssertEqual(first.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000), .applied)
        let frame = try sealedFrame(counter: 4, plaintext: .position(latE7: 5, lonE7: 6, accuracy: 7, age: 2, approximate: true, interval: 60))
        XCTAssertEqual(first.receiveFrame(payload: frame, now: 1_040), .applied)

        // A new process: a new receiver over the same database and the same keychain.
        let second = try makeReceiver(now: 1_050)
        let view = try XCTUnwrap(second.share(id: "c1", now: 1_050))
        XCTAssertEqual(view.state, .active)
        XCTAssertEqual(view.lastCounter, 4)
        XCTAssertEqual(view.lastFrameAt, 1_040)
        XCTAssertEqual(view.position, LiveSharePosition(latE7: 5, lonE7: 6, accuracy: 7, approximate: true, fixAt: 1_038))
        // The counter continues from the stored one: the same frame again is old, the next one applies.
        XCTAssertEqual(second.receiveFrame(payload: frame, now: 1_060), .dropped(.frameOld))
        let next = try sealedFrame(counter: 5, plaintext: .position(latE7: 8, lonE7: 9, accuracy: 7, age: 0, approximate: false, interval: 30))
        XCTAssertEqual(second.receiveFrame(payload: next, now: 1_070), .applied)
    }

    func testThePositionIsNeverAPlainColumn() throws {
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        let raw: [Row] = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM live_shares") }
        XCTAssertEqual(raw.count, 1)
        let sealed: String? = raw[0]["liveSealed"]
        XCTAssertNotNil(sealed)
        XCTAssertTrue(LocalStoreCipher.isSealed(sealed), "the counter and the position are one sealed column")
        for column in raw[0].columnNames {
            let text = String(describing: raw[0][column] as DatabaseValue)
            XCTAssertFalse(text.contains("454642110"), "no plain column holds a coordinate (\(column))")
            XCTAssertFalse(text.contains("91899820"))
        }
        // The key is not in the database at all: it is in the key storage.
        let dump: String = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM live_shares").map { String(describing: $0) }.joined()
        }
        XCTAssertFalse(dump.contains(key.base64EncodedString()))
        XCTAssertEqual(keys.key(forShare: account("c1")), key)
    }

    func testAShareWhoseKeyIsGoneEndsAsStateLostOnReload() throws {
        let first = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = first.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        keys.delete(forShare: account("c1"))  // a restore or a migration left the keychain behind
        let second = try makeReceiver(now: 1_100)
        let view = try XCTUnwrap(second.share(id: "c1", now: 1_100))
        XCTAssertEqual(view.state, .ended)
        XCTAssertEqual(view.reason, .stateLost)
        XCTAssertNil(view.position)
    }

    func testAShareWhoseSealedStateCannotBeReadEndsAsStateLost() throws {
        let first = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = first.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        try queue.write { db in try db.execute(sql: "UPDATE live_shares SET liveSealed = 'QM1:not-base64!!' WHERE id = 'c1'") }
        let second = try makeReceiver(now: 1_100)
        XCTAssertEqual(second.share(id: "c1", now: 1_100)?.reason, .stateLost)
    }

    func testAnEndedShareHoldsNoPositionNoKeyAndKeepsItsIds() throws {
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        XCTAssertEqual(receiver.receiveStop(from: .peer, target: "c1", now: 1_100), .applied)
        XCTAssertNil(keys.key(forShare: account("c1")))
        let raw: [Row] = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM live_shares") }
        XCTAssertNil(raw[0]["liveSealed"] as String?, "the position is deleted when the share ends")
        XCTAssertEqual(raw[0]["endReason"] as String?, "stopped")
        // The client message id and the sid stay: a start redelivered after the end is a duplicate, after a restart too.
        let restarted = try makeReceiver(now: 1_200)
        XCTAssertEqual(restarted.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_200), .dropped(.startDuplicate))
        XCTAssertEqual(restarted.receiveStart(clientMsgId: "c1-again", live: live, position: position, now: 1_200),
                       .dropped(.startDuplicate), "the same sid under a new client message id")
    }

    func testTombstonesSurviveAReloadAndAreForgottenAtTheirTime() throws {
        let first = try makeReceiver(now: 1_000)
        XCTAssertEqual(first.receiveStop(from: .peer, target: "future-start", now: 1_000), .applied)
        XCTAssertEqual(first.receiveDeleteForEveryone(from: .peer, target: "deleted-start", now: 1_010), .applied)

        let second = try makeReceiver(now: 2_000)
        XCTAssertEqual(second.rememberedTombstones(now: 2_000).map { $0.target }, ["future-start", "deleted-start"])
        // The start that arrives under a remembered target is created ended, with no key.
        let (live, position) = liveStart()
        XCTAssertEqual(second.receiveStart(clientMsgId: "future-start", live: live, position: position, now: 2_000), .applied)
        XCTAssertEqual(second.share(id: "future-start", now: 2_000)?.reason, .stopped)
        XCTAssertNil(keys.key(forShare: account("future-start")))

        // After exactly TOMBSTONE_KEEP seconds the target is forgotten, in memory and on disk.
        let later = try makeReceiver(now: 1_000 + LocationWire.tombstoneKeep)
        XCTAssertEqual(later.rememberedTombstones(now: 1_000 + LocationWire.tombstoneKeep).map { $0.target }, ["deleted-start"])
        let rows: Int = try queue.read { db in try LiveShareTombstoneRow.fetchCount(db) }
        XCTAssertEqual(rows, 1)
    }

    func testTheSharesOfOnePeerAreNotThoseOfAnother() throws {
        let one = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = one.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        let otherPeer = "c0ffee00-0000-4000-8000-000000000001"
        let other = try LocationShareReceiver(selfId: selfId, peerId: otherPeer, store: makeStore(peer: otherPeer), now: 1_000)
        XCTAssertTrue(other.shares(now: 1_000).isEmpty)
        let again = try makeReceiver(now: 1_001)
        XCTAssertEqual(again.shares(now: 1_001).count, 1)
    }

    func testAFailedWriteSurfacesAsAThrownError() throws {
        // A store whose database refuses the write: the receiver ends the share as `state_lost` and does not apply the event.
        let broken = GRDBLocationShareStore(peerUserId: peerId, writerProvider: { self.queue }, keys: FailingKeyStorage())
        let receiver = try LocationShareReceiver(selfId: selfId, peerId: peerId, store: broken, now: 1_000)
        let (live, position) = liveStart()
        XCTAssertEqual(receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000), .storeFailed)
        XCTAssertEqual(receiver.share(id: "c1", now: 1_000)?.reason, .stateLost)
    }

    private final class FailingKeyStorage: LocationShareKeyStorage {
        func key(forShare id: String) -> Data? { nil }
        func save(_ key: Data, forShare id: String) throws { throw KeychainLocationShareKeyStorage.WriteFailure(status: -34018) }
        func delete(forShare id: String) {}
        func deleteAll() {}
    }

    // MARK: The sender's journal

    func testTheJournalKeepsNothingSecret() throws {
        let writer: DatabaseQueue = queue
        let journal = GRDBLocationShareJournal(writerProvider: { writer })
        journal.write(LocationShareJournalEntry(startClientMsgId: "s1", phase: .sent, stopSent: false))
        journal.write(LocationShareJournalEntry(startClientMsgId: "s2", phase: .echoed, stopSent: true))
        XCTAssertEqual(journal.entries().map { $0.startClientMsgId }, ["s1", "s2"])
        journal.write(LocationShareJournalEntry(startClientMsgId: "s1", phase: .echoed, stopSent: false))
        XCTAssertEqual(journal.entries().first?.phase, .echoed)
        journal.clear(startClientMsgId: "s1")
        XCTAssertEqual(journal.entries().map { $0.startClientMsgId }, ["s2"])
        let columns: [String] = try queue.read { db in try db.columns(in: "live_share_journal").map { $0.name } }
        XCTAssertEqual(columns, ["startClientMsgId", "phase", "stopSent"])
    }

    /// A process that starts again ends the shares of the one that died, with the stop only (WIRE_SPEC 14.6.1 rule 10).
    func testTheJournalLetsARestartEndAShareWithoutAFrame() throws {
        let writer: DatabaseQueue = queue
        let first = GRDBLocationShareJournal(writerProvider: { writer })
        let secrets = LocationShareSecrets.generate()
        let fix = LocationSenderFix(latE7: 1, lonE7: 2, accuracy: 3, approximate: false, capturedAt: 100)
        let stops = StopBox()
        let effects = LocationShareSenderEffects(sendStop: { id, _ in stops.add(id) }, withdrawStart: { _ in })
        let sender = try XCTUnwrap(LocationShareSender(startClientMsgId: "s1", selfId: peerId, peerId: selfId, sid: secrets.sid,
                                                       shareKey: secrets.key, startedAt: 100, duration: 3_600, fix: fix,
                                                       effects: effects, journal: first))
        _ = sender.startLeftDevice()
        _ = sender.startAcknowledged(now: 110)
        XCTAssertEqual(first.entries().first?.phase, .echoed)

        // The process dies: a new journal object over the same database is all that is left.
        let second = GRDBLocationShareJournal(writerProvider: { writer })
        let entry = try XCTUnwrap(second.entries().first)
        let recovered = LocationShareSender.recoverAfterRestart(entry: entry, now: 500, effects: effects, journal: second)
        XCTAssertEqual(recovered.outcome.stop, .sent)
        XCTAssertNil(recovered.outcome.frame, "a restarted process builds no frame of any kind")
        XCTAssertFalse(recovered.sender.keyHeld)
        XCTAssertEqual(stops.ids, ["s1"])
        XCTAssertTrue(second.entries().isEmpty)
    }

    private final class StopBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    }

    // MARK: The whole store

    func testWipingTheWholeStoreTakesTheIdsAndTheKeysWithIt() throws {
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        _ = receiver.receiveStop(from: .peer, target: "future", now: 1_001)
        let writer: DatabaseQueue = queue
        GRDBLocationShareJournal(writerProvider: { writer }).write(LocationShareJournalEntry(startClientMsgId: "s1", phase: .sent, stopSent: false))

        GRDBLocationShareStore.wipeEverything(writer: queue, keys: keys)

        let counts: [Int] = try queue.read { db in
            [try LiveShareRow.fetchCount(db), try LiveShareTombstoneRow.fetchCount(db), try LiveShareJournalRow.fetchCount(db)]
        }
        XCTAssertEqual(counts, [0, 0, 0])
        XCTAssertNil(keys.key(forShare: account("c1")))
        // The two ids went with it: the same start is now a new one.
        let fresh = try makeReceiver(now: 2_000)
        XCTAssertEqual(fresh.receiveStart(clientMsgId: "c1", live: live, position: position, now: 2_000), .applied)
    }

    func testTheActiveSharesAreListedAcrossConversations() throws {
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        let active = GRDBLocationShareStore.activeShares(writer: queue)
        XCTAssertEqual(active.map { $0.id }, ["c1"])
        XCTAssertEqual(active.first?.peerUserId, peerId)
        _ = receiver.receiveStop(from: .peer, target: "c1", now: 1_010)
        XCTAssertTrue(GRDBLocationShareStore.activeShares(writer: queue).isEmpty)
    }

    // MARK: A record belongs to its conversation

    /// The client message id of a start is chosen by the sender: another peer can send a start under the id of a start of mine. The
    /// two records, and the two keys, stay apart (primary key (peer, id), key account `<peer>/<id>`).
    func testTwoPeersThatUseTheSameClientMessageIdKeepTheirOwnRecordAndKey() throws {
        let otherPeer = "c0ffee00-0000-4000-8000-000000000001"
        let otherSid = Data((100..<116).map { UInt8($0) })
        let otherKey = Data((150..<182).map { UInt8($0) })
        let one = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        XCTAssertEqual(one.receiveStart(clientMsgId: "same-id", live: live, position: position, now: 1_000), .applied)
        let first = try sealedFrame(counter: 1, plaintext: .position(latE7: 5, lonE7: 6, accuracy: 7, age: 0, approximate: false, interval: 30))

        let other = try LocationShareReceiver(selfId: selfId, peerId: otherPeer, store: makeStore(peer: otherPeer), now: 1_001)
        let theirLive = LocationLiveStart(sid: otherSid, key: otherKey, startedAt: 1_000, duration: 3_600)
        XCTAssertEqual(other.receiveStart(clientMsgId: "same-id", live: theirLive, position: position, now: 1_001), .applied,
                       "a start of another conversation is not a duplicate of mine")

        // Both records are in the table, and neither moved to the other conversation.
        let rows: [Row] = try queue.read { db in try Row.fetchAll(db, sql: "SELECT id, peerUserId FROM live_shares ORDER BY peerUserId") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map { $0["peerUserId"] as String }), [peerId, otherPeer])
        // Each key sits under its own account and is the one of its own start.
        XCTAssertEqual(keys.key(forShare: account("same-id")), key)
        XCTAssertEqual(keys.key(forShare: account("same-id", peer: otherPeer)), otherKey)
        XCTAssertNil(keys.key(forShare: "same-id"), "no key is stored under the client message id alone")

        // A restart: my share is still mine and still opens my frames.
        let again = try makeReceiver(now: 1_050)
        XCTAssertEqual(again.share(id: "same-id", now: 1_050)?.state, .active)
        XCTAssertEqual(again.receiveFrame(payload: first, now: 1_050), .applied)

        // Ending the share of the other peer does not touch mine.
        XCTAssertEqual(other.receiveStop(from: .peer, target: "same-id", now: 1_060), .applied)
        XCTAssertNil(keys.key(forShare: account("same-id", peer: otherPeer)))
        XCTAssertEqual(keys.key(forShare: account("same-id")), key)
        XCTAssertEqual(try makeReceiver(now: 1_070).share(id: "same-id", now: 1_070)?.state, .active)
    }

    // MARK: Forgetting ended records

    func testTheRecordKeepsTheMomentAReplayedStartCanStillOpenAShare() throws {
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart(startedAt: 200_000, duration: 86_400)
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        let stored: Int64 = try queue.read { db in try Int64.fetchOne(db, sql: "SELECT replayUntil FROM live_shares WHERE id = 'c1'") ?? -1 }
        XCTAssertEqual(stored, 200_000 + 86_400 + LocationWire.skew, "st + du + SKEW")
        let loaded = try makeStore().load()
        XCTAssertEqual(loaded.records.first?.replayBound, stored)
    }

    func testAnEndedRecordIsForgottenOnlyAfterTheKeepTimeAndTheReplayBound() throws {
        // The sender's clock runs far ahead: its start says st = 200 000 while the receiver reads 1 000.
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart(startedAt: 200_000, duration: 86_400)
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        XCTAssertEqual(receiver.receiveStop(from: .peer, target: "c1", now: 1_100), .applied)
        let bound: Int64 = 200_000 + 86_400 + LocationWire.skew
        let keepEnds: Int64 = 1_100 + LocationWire.tombstoneKeep

        XCTAssertEqual(GRDBLocationShareStore.purgeEnded(writer: queue, now: keepEnds - 1), 0, "TOMBSTONE_KEEP has not passed")
        XCTAssertEqual(GRDBLocationShareStore.purgeEnded(writer: queue, now: keepEnds), 0,
                       "TOMBSTONE_KEEP passed, but a replayed start could still open a share until st + du + SKEW")
        XCTAssertLessThan(keepEnds, bound)
        // Still a duplicate for a fresh process.
        XCTAssertEqual(try makeReceiver(now: keepEnds).receiveStart(clientMsgId: "c1", live: live, position: position, now: keepEnds),
                       .dropped(.startDuplicate))

        XCTAssertEqual(GRDBLocationShareStore.purgeEnded(writer: queue, now: bound - 1), 0)
        XCTAssertEqual(GRDBLocationShareStore.purgeEnded(writer: queue, now: bound), 1)
        let left: Int = try queue.read { db in try LiveShareRow.fetchCount(db) }
        XCTAssertEqual(left, 0)

        // Replayed after the purge: the start is born ended (`expired`), with no key, never a live share with a counter of 0.
        let fresh = try makeReceiver(now: bound)
        XCTAssertEqual(fresh.receiveStart(clientMsgId: "c1", live: live, position: position, now: bound), .applied)
        XCTAssertEqual(fresh.share(id: "c1", now: bound)?.reason, .expired)
        XCTAssertNil(keys.key(forShare: account("c1")))
    }

    func testPurgeNeverTouchesALiveRecordAndForgetsOldTombstones() throws {
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = receiver.receiveStart(clientMsgId: "live-one", live: live, position: position, now: 1_000)
        XCTAssertEqual(receiver.receiveStop(from: .peer, target: "future-start", now: 1_000), .applied)
        let now: Int64 = 1_000 + LocationWire.tombstoneKeep + 10
        XCTAssertEqual(GRDBLocationShareStore.purgeEnded(writer: queue, now: now), 0)
        let live1: Int = try queue.read { db in try LiveShareRow.fetchCount(db) }
        XCTAssertEqual(live1, 1, "a live record stays whatever the clock says")
        let tombstones: Int = try queue.read { db in try LiveShareTombstoneRow.fetchCount(db) }
        XCTAssertEqual(tombstones, 0, "a tombstone whose time passed is forgotten")
    }

    func testTheEndTimeOfAShareIsOnItsView() throws {
        let receiver = try makeReceiver(now: 1_000)
        let (live, position) = liveStart()
        _ = receiver.receiveStart(clientMsgId: "c1", live: live, position: position, now: 1_000)
        XCTAssertNil(receiver.share(id: "c1", now: 1_010)?.endedAt)
        _ = receiver.receiveStop(from: .peer, target: "c1", now: 1_020)
        XCTAssertEqual(receiver.share(id: "c1", now: 1_030)?.endedAt, 1_020)
        // A restart reads it back from the record.
        XCTAssertEqual(try makeReceiver(now: 1_040).share(id: "c1", now: 1_040)?.endedAt, 1_020)
    }

    func testTheSchemaIsTheOneOfTheMigration() throws {
        let tables: [String] = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'live_share%' ORDER BY name")
        }
        XCTAssertEqual(tables, ["live_share_journal", "live_share_tombstones", "live_shares"])
    }
}

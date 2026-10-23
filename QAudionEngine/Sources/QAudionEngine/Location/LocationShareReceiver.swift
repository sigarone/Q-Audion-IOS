import Foundation

// The receiver of the live shares of ONE 1:1 conversation (WIRE_SPEC sections 14.6.2 to 14.7). Pure logic over a durable store that the
// app implements (`LocationShareStore`); the vectors are `receiver_sequences` and `end_time_cases` of `location-kat.json`.
//
// What it guarantees:
//  - the end time of a share is `min(R + du, st + du + SKEW)` and never grows; a share whose end time has been reached is ENDED
//    (`expired`) whether or not anything looked at it (every entry point first runs `advance`);
//  - shares are ordered by `ord = min(st, R)`; a newer start supersedes the running one and an older one is born superseded;
//  - the highest counter wins, a duplicate or late frame is `frame_old`; a frame that does not authenticate or whose plaintext breaks a
//    rule never moves the counter;
//  - `lastCtr`, `lastFrameAt` and the position are written to the store, flushed, BEFORE a position is shown or a final frame acted on
//    (the in-memory state only changes after `save` returned); a share whose counter or key cannot be read back, or whose write
//    failed, ends as `state_lost` and is never resumed with a counter of 0;
//  - a start is a duplicate when its client message id OR its `sid` is already in the store, in any state; it never overwrites or
//    resets a record;
//  - a stop or a delete for everyone that overtakes its start is remembered per conversation for exactly `TOMBSTONE_KEEP` seconds and
//    the last `TOMBSTONE_MAX` targets;
//  - when a share ends for any reason the key and every position are deleted; only the facts of 14.6.6 stay.
//
// Nothing here logs or describes a position or a key.

/// Why a share ended (the closed set `END_REASONS`); the first reason sticks.
public enum LiveShareEndReason: String, CaseIterable, Equatable, Sendable {
    case expired
    case stopped
    case superseded
    case deleted
    case blocked
    case stateLost = "state_lost"
}

/// The state of a share as the card shows it. STALE is a display state only.
public enum LiveShareState: String, Equatable, Sendable {
    case active = "ACTIVE"
    case stale = "STALE"
    case ended = "ENDED"
}

/// Why an inbound start, frame or control was dropped (the closed set `receiver_drops`): a telemetry label only.
public enum LocationReceiveDrop: String, CaseIterable, Equatable, Sendable {
    case frameFormat = "frame_format"
    case frameUnmatched = "frame_unmatched"
    case frameOld = "frame_old"
    case frameBad = "frame_bad"
    case stopSpoof = "stop_spoof"
    case stopUnknown = "stop_unknown"
    case startDuplicate = "start_duplicate"
}

/// What an inbound event did.
public enum LocationReceiveOutcome: Equatable, Sendable {
    /// A share was created, updated or ended, or a tombstone remembered.
    case applied
    /// Dropped, with the telemetry label.
    case dropped(LocationReceiveDrop)
    /// Nothing to do (a stop of an ended share, a repeated tombstone, a blocked sender).
    case ignored
    /// The durable write failed: the share was ended as `state_lost` and the event was NOT applied.
    case storeFailed
}

/// The position a card shows: the first fix of the start or the position of the newest valid frame, with its fix time (`R - age` for the
/// start, `now - age` for a frame). It lives only in the live-share store and is deleted when the share ends.
public struct LiveSharePosition: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let latE7: Int32
    public let lonE7: Int32
    public let accuracy: Int
    public let approximate: Bool
    public let fixAt: Int64

    public init(latE7: Int32, lonE7: Int32, accuracy: Int, approximate: Bool, fixAt: Int64) {
        self.latE7 = latE7
        self.lonE7 = lonE7
        self.accuracy = accuracy
        self.approximate = approximate
        self.fixAt = fixAt
    }

    public var description: String { "LiveSharePosition(redacted)" }
    public var debugDescription: String { description }
}

/// What a share needs while it is live: the counter of the last frame, when it arrived, the interval it announced and the position.
public struct LiveShareLiveState: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var lastCounter: UInt32
    public var lastFrameAt: Int64
    public var interval: Int64
    public var position: LiveSharePosition

    public init(lastCounter: UInt32, lastFrameAt: Int64, interval: Int64, position: LiveSharePosition) {
        self.lastCounter = lastCounter
        self.lastFrameAt = lastFrameAt
        self.interval = interval
        self.position = position
    }

    public var description: String { "LiveShareLiveState(redacted)" }
    public var debugDescription: String { description }
}

/// One share of the conversation, as the store holds it. `id` is the client message id of the start; `sid` is not secret (only `k` and the
/// positions are wiped when a share ends: the two ids stay for the duplicate test, section 14.6.2 step 1). The share key is NOT part of
/// the record: it lives in the Keychain (`LocationShareStore.shareKey`).
public struct LiveShareRecord: Equatable, Sendable {
    public let id: String
    public let sid: Data
    public let endAt: Int64
    /// `min(st, R)`, section 14.6.2 step 4.
    public let ord: Int64
    /// The order of arrival within the conversation (the later arrival is newer when `ord` is equal).
    public let arrival: Int
    /// `nil` while the share is live; the first reason once it ended.
    public var endReason: LiveShareEndReason?
    public var endedAt: Int64?
    /// An ended share that the platform's delete path handles: no live-share card is shown for it (section 14.6.2 step 2).
    public var noCard: Bool
    /// Present while the share is live. A live record without it has lost its counter: it ends as `state_lost`.
    public var live: LiveShareLiveState?
    /// `st + du + SKEW`: the last moment at which a redelivered copy of the start could still open a share (its end time is at most
    /// this). A store that forgets ended records does so only once this moment has passed too, and `TOMBSTONE_KEEP` after the end
    /// (section 14.6.2 step 1): until then the ids of the start are what stops a replay from creating a fresh record with `lastCtr = 0`.
    public let replayBound: Int64

    public init(id: String, sid: Data, endAt: Int64, ord: Int64, arrival: Int, endReason: LiveShareEndReason? = nil,
                endedAt: Int64? = nil, noCard: Bool = false, live: LiveShareLiveState? = nil, replayBound: Int64 = 0) {
        self.id = id
        self.sid = sid
        self.endAt = endAt
        self.ord = ord
        self.arrival = arrival
        self.endReason = endReason
        self.endedAt = endedAt
        self.noCard = noCard
        self.live = live
        self.replayBound = replayBound
    }
}

/// A stop or a delete for everyone that named no known row: the target and the reason, for exactly `TOMBSTONE_KEEP` seconds from the
/// arrival of the control (`until`). It holds no key, no position and no body.
public struct LocationTombstone: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case stopped, deleted
    }

    public let target: String
    public let reason: Reason
    public let until: Int64

    public init(target: String, reason: Reason, until: Int64) {
        self.target = target
        self.reason = reason
        self.until = until
    }
}

public struct LocationShareStoreContents: Sendable {
    public var records: [LiveShareRecord]
    public var tombstones: [LocationTombstone]

    public init(records: [LiveShareRecord], tombstones: [LocationTombstone]) {
        self.records = records
        self.tombstones = tombstones
    }
}

/// The durable live-share store of one conversation (iOS: the `live_shares` table of the app database and the Keychain, for the keys).
///
/// Every method that writes MUST be durable (flushed) when it returns: the receiver changes its in-memory state, shows a position and
/// acts on a final frame only after `save` returned without throwing.
public protocol LocationShareStore: AnyObject {
    /// Every record of the conversation, in order of arrival, and the tombstones, in order of arrival.
    func load() throws -> LocationShareStoreContents
    /// Inserts or replaces one record.
    func save(_ record: LiveShareRecord) throws
    /// Replaces the tombstones of the conversation.
    func saveTombstones(_ tombstones: [LocationTombstone]) throws
    /// The share key of a share, or `nil` when it cannot be loaded (a Keychain item missing after a restore or a migration).
    func shareKey(forShare id: String) -> Data?
    func saveShareKey(_ key: Data, forShare id: String) throws
    /// Deletes the share key. Idempotent.
    func deleteShareKey(forShare id: String)
}

/// A share as the card sees it at a given time.
public struct LiveShareView: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public let state: LiveShareState
    public let reason: LiveShareEndReason?
    public let endAt: Int64
    public let lastCounter: UInt32?
    public let lastFrameAt: Int64?
    public let position: LiveSharePosition?
    public let noCard: Bool
    /// When the share ended (unix seconds), `nil` while it is live: the disappearing-message timer of its row runs from this moment.
    public var endedAt: Int64? = nil

    public var description: String { "LiveShareView(redacted)" }
    public var debugDescription: String { description }
}

public final class LocationShareReceiver: @unchecked Sendable {

    /// Who sent a control: the other account of the conversation, or the receiver's own account (another own device).
    public enum Origin: Sendable {
        case peer
        case selfAccount
    }

    private let lock = NSRecursiveLock()
    private let selfId: String
    private let peerId: String
    private let store: LocationShareStore
    private var records: [LiveShareRecord] = []
    private var tombstones: [LocationTombstone] = []
    private var nextArrival: Int = 0
    private var peerBlocked = false

    /// `selfId` and `peerId` are the user id strings EXACTLY as the server sends them (36-character lowercase UUID text), as the sender
    /// of the frames wrote them: never re-serialised through a platform UUID type (section 14.6.3).
    /// Reads the store and reconciles it (section 14.6.4, durability): a share that is live but whose counter or key cannot be read back
    /// ends as `state_lost` at `now`, with its key and positions deleted. The ids of the ended records are kept.
    public init(selfId: String, peerId: String, store: LocationShareStore, now: Int64) throws {
        self.selfId = selfId
        self.peerId = peerId
        self.store = store
        let contents = try store.load()
        self.records = contents.records
        self.tombstones = contents.tombstones
        self.nextArrival = (contents.records.map { $0.arrival }.max() ?? -1) + 1
        for record in records {
            if record.endReason != nil {
                // A key that outlived the end of its share (a crash between the two writes) is deleted now.
                store.deleteShareKey(forShare: record.id)
            } else if record.live == nil || store.shareKey(forShare: record.id) == nil {
                end(record.id, reason: .stateLost, noCard: false, now: now)
            }
        }
        advanceLocked(now: now)
    }

    // MARK: Observation

    /// Every share of the conversation at `now`, in order of arrival. STALE is derived from the clock; a share whose end time was reached
    /// is ENDED.
    public func shares(now: Int64) -> [LiveShareView] {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        return records.map { view(of: $0, now: now) }
    }

    public func share(id: String, now: Int64) -> LiveShareView? {
        shares(now: now).first { $0.id == id }
    }

    public func rememberedTombstones(now: Int64) -> [LocationTombstone] {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        return tombstones
    }

    // MARK: Clock

    /// Brings the state to `now`: a share whose end time was reached is ENDED (`expired`), a tombstone that reached its time is forgotten.
    public func advance(now: Int64) {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
    }

    private func advanceLocked(now: Int64) {
        for record in records where record.endReason == nil && now >= record.endAt {
            end(record.id, reason: .expired, noCard: false, now: now)
        }
        let kept = tombstones.filter { $0.until > now }
        if kept.count != tombstones.count {
            tombstones = kept
            try? store.saveTombstones(kept)
        }
    }

    // MARK: Start (section 14.6.2)

    /// A valid live start from the peer, delivered in the 1:1 conversation with it, first seen at `now` (`R`). `clientMsgId` is the
    /// client message id of the message row. The start body with `k` is never persisted by this type: the key goes to the store's key
    /// storage and nowhere else.
    public func receiveStart(clientMsgId: String, live: LocationLiveStart, position: LocationPosition,
                             now: Int64) -> LocationReceiveOutcome {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        if peerBlocked { return .ignored }
        // Step 1: a duplicate by client message id OR by sid, in any state. Nothing is created, replaced or reset.
        if records.contains(where: { $0.id == clientMsgId || $0.sid == live.sid }) {
            return .dropped(.startDuplicate)
        }
        // Step 3 (the arithmetic): the end time never grows after this. The first term stops a sender clock that runs ahead from
        // stretching the share, the second stops a start delivered hours late from showing a share that is already over.
        let replayBound = live.startedAt + live.duration + LocationWire.skew
        let endAt = min(now + live.duration, replayBound)
        let ord = min(live.startedAt, now)

        var bornEnded: LiveShareEndReason?
        var noCard = false
        if let tombstone = tombstones.first(where: { $0.target == clientMsgId }) {
            // Step 2: a stop or a delete that overtook this start. No key is stored, no position is shown.
            switch tombstone.reason {
            case .stopped:
                bornEnded = .stopped
            case .deleted:
                bornEnded = .deleted
                noCard = true
            }
        } else if endAt <= now {
            // Step 3: already over on arrival. Other shares are not touched.
            bornEnded = .expired
        } else if records.contains(where: { $0.ord > ord }) {
            // Step 4: an older start than one already known is born superseded.
            bornEnded = .superseded
        }
        if let reason = bornEnded {
            let record = LiveShareRecord(id: clientMsgId, sid: live.sid, endAt: endAt, ord: ord, arrival: takeArrival(),
                                         endReason: reason, endedAt: now, noCard: noCard, live: nil, replayBound: replayBound)
            return persistNew(record) ? .applied : .storeFailed
        }

        // Step 5: the key first (a share without its key is useless), then the record. A failure creates the share ended.
        let first = LiveSharePosition(latE7: position.latE7, lonE7: position.lonE7, accuracy: position.accuracy,
                                      approximate: position.approximate, fixAt: now - Int64(position.age))
        var record = LiveShareRecord(id: clientMsgId, sid: live.sid, endAt: endAt, ord: ord, arrival: takeArrival(), endReason: nil,
                                     endedAt: nil, noCard: false,
                                     live: LiveShareLiveState(lastCounter: 0, lastFrameAt: now, interval: LocationWire.txInterval,
                                                              position: first),
                                     replayBound: replayBound)
        do {
            try store.saveShareKey(live.key, forShare: clientMsgId)
            for other in records where other.endReason == nil {
                end(other.id, reason: .superseded, noCard: false, now: now)
            }
            try store.save(record)
        } catch {
            store.deleteShareKey(forShare: clientMsgId)
            record.endReason = .stateLost
            record.endedAt = now
            record.live = nil
            _ = persistNew(record)
            return .storeFailed
        }
        records.append(record)
        return .applied
    }

    private func takeArrival() -> Int {
        defer { nextArrival += 1 }
        return nextArrival
    }

    /// Writes a record that is created ended; the in-memory list only gets it after the store has it.
    private func persistNew(_ record: LiveShareRecord) -> Bool {
        do {
            try store.save(record)
            records.append(record)
            return true
        } catch {
            records.append(record)
            return false
        }
    }

    // MARK: Frames (section 14.6.4)

    /// An `eph_relay` frame relayed from the peer, received at `now`. `payload` is the canonical base64 text of the frame.
    public func receiveFrame(payload: String, now: Int64) -> LocationReceiveOutcome {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        // Step 1: canonical base64 of exactly FRAME_LEN bytes that begins with FRAME_VERSION.
        guard payload.utf8.count <= LocationWire.ephMaxBase64, let frame = FileV2Base64.decode(payload),
              LocationFrameCodec.checkFormat(frame) == nil else {
            return .dropped(.frameFormat)
        }
        // Frames and stops from a blocked sender are dropped.
        if peerBlocked { return .dropped(.frameUnmatched) }

        // Step 2: the live shares of the peer, newest first (by `ord`, then by arrival), at most MAX_CANDIDATES. The first that
        // authenticates wins. Frames are never buffered for a share that is not known yet.
        let candidates = records.filter { $0.endReason == nil }
            .sorted { ($0.ord, $0.arrival) > ($1.ord, $1.arrival) }
            .prefix(LocationWire.maxCandidates)
        var matched: (record: LiveShareRecord, opened: LocationFrameCodec.Opened)?
        for candidate in candidates {
            guard let key = store.shareKey(forShare: candidate.id), candidate.live != nil,
                  let keys = LocationFrameKeys(sid: candidate.sid, shareKey: key) else {
                // The key cannot be loaded: the share is lost, it is not left ACTIVE with a key it cannot use.
                end(candidate.id, reason: .stateLost, noCard: false, now: now)
                continue
            }
            if let opened = LocationFrameCodec.open(frame, keys: keys, senderId: peerId, recipientId: selfId) {
                matched = (candidate, opened)
                break
            }
        }
        guard let found = matched, let current = found.record.live else { return .dropped(.frameUnmatched) }

        // Step 3: the whole ordering rule. The frame with the highest counter wins; a duplicate or a late one is dropped.
        if found.opened.counter <= current.lastCounter { return .dropped(.frameOld) }

        // Step 4: the plaintext checks. A failure does not move the counter.
        let plaintext: LocationFramePlaintext
        switch LocationFrameCodec.judge(found.opened.plaintext) {
        case .failure: return .dropped(.frameBad)
        case .success(let judged): plaintext = judged
        }

        // Step 5: write first, then apply. A final frame ends the share (`stopped`).
        if plaintext.isFinal {
            var record = found.record
            record.endReason = .stopped
            record.endedAt = now
            record.live = nil
            do {
                try store.save(record)
            } catch {
                end(found.record.id, reason: .stateLost, noCard: false, now: now)
                return .storeFailed
            }
            replace(record)
            store.deleteShareKey(forShare: record.id)
            return .applied
        }
        var updated = found.record
        updated.live = LiveShareLiveState(
            lastCounter: found.opened.counter, lastFrameAt: now, interval: Int64(plaintext.iv),
            position: LiveSharePosition(latE7: plaintext.lat, lonE7: plaintext.lon, accuracy: Int(plaintext.acc),
                                        approximate: plaintext.isApproximate, fixAt: now - Int64(plaintext.age)))
        do {
            try store.save(updated)
        } catch {
            end(found.record.id, reason: .stateLost, noCard: false, now: now)
            return .storeFailed
        }
        replace(updated)
        return .applied
    }

    // MARK: Controls (section 14.7)

    /// A `loc_stop` that names `target`. Applied only when `target` is a live start of THIS conversation and the control comes from the
    /// peer that sent it (the spoof check); otherwise dropped silently. A stop that overtakes its start, from the peer, is remembered.
    public func receiveStop(from origin: Origin, target: String, now: Int64) -> LocationReceiveOutcome {
        receiveEnd(from: origin, target: target, reason: .stopped, now: now)
    }

    /// A delete for everyone of a message of this conversation, under the same author check. A share it ends has no live-share card
    /// (`noCard`): the row is what the platform's delete path leaves. A delete that overtakes its start is remembered like a stop.
    public func receiveDeleteForEveryone(from origin: Origin, target: String, now: Int64) -> LocationReceiveOutcome {
        receiveEnd(from: origin, target: target, reason: .deleted, now: now)
    }

    private func receiveEnd(from origin: Origin, target: String, reason: LiveShareEndReason, now: Int64) -> LocationReceiveOutcome {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        if peerBlocked { return .ignored }
        if let known = records.first(where: { $0.id == target }) {
            // The author check: only the account that sent the start row may end it.
            guard origin == .peer else { return .dropped(.stopSpoof) }
            // Idempotent, and it never changes the reason of a share that has already ended.
            if known.endReason != nil { return .ignored }
            end(known.id, reason: reason, noCard: reason == .deleted, now: now)
            return .applied
        }
        // A control that names no known row and comes from any other account is dropped and nothing is remembered.
        guard origin == .peer else { return .dropped(.stopUnknown) }
        // It may have overtaken its start (they travel on different lanes): remember the target and the reason. A target that is already
        // remembered is not added again, its time is not extended and its reason does not change.
        if tombstones.contains(where: { $0.target == target }) { return .ignored }
        var next = tombstones
        next.append(LocationTombstone(target: target, reason: reason == .deleted ? .deleted : .stopped,
                                      until: now + LocationWire.tombstoneKeep))
        while next.count > LocationWire.tombstoneMax { next.removeFirst() }
        do {
            try store.saveTombstones(next)
        } catch {
            return .storeFailed
        }
        tombstones = next
        return .applied
    }

    // MARK: Other ends (section 14.6.6)

    /// The user blocks the peer: every share held from it ends at once (`blocked`), keys and positions deleted. Frames and stops from a
    /// blocked sender are dropped until `unblockPeer`.
    public func blockPeer(now: Int64) {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        peerBlocked = true
        for record in records where record.endReason == nil {
            end(record.id, reason: .blocked, noCard: false, now: now)
        }
    }

    public func unblockPeer() {
        lock.lock()
        peerBlocked = false
        lock.unlock()
    }

    /// The conversation is cleared, the user logs out or a local wipe runs: every live share ends and its key, positions and card go. The
    /// client message id and the `sid` of each start stay with the end time (the duplicate test of section 14.6.2 step 1), until
    /// `TOMBSTONE_KEEP` after the end at the least; only the deletion of the whole local store takes them away.
    public func endAllForLocalClear(now: Int64) {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        for record in records where record.endReason == nil {
            end(record.id, reason: .deleted, noCard: true, now: now)
        }
    }

    /// "Delete for me" of one start row: the share ends if it is live and its card goes; the two ids and the end time stay.
    public func deleteForMe(id: String, now: Int64) {
        lock.lock()
        defer { lock.unlock() }
        advanceLocked(now: now)
        guard let record = records.first(where: { $0.id == id }) else { return }
        if record.endReason == nil {
            end(id, reason: .deleted, noCard: true, now: now)
        }
    }

    // MARK: Internals

    /// ENDED: the first reason sticks; the key, the counter and every position are deleted. The record is written first, then the key
    /// is deleted (a crash in between leaves a key that `init` deletes). `noCard` only ever turns on with a `deleted` reason.
    private func end(_ id: String, reason: LiveShareEndReason, noCard: Bool, now: Int64) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].endReason == nil else { return }
        var record = records[index]
        record.endReason = reason
        record.endedAt = now
        record.noCard = noCard
        record.live = nil
        // If the write fails the share still ends in memory and its key is still deleted: ending is the safe direction.
        try? store.save(record)
        records[index] = record
        store.deleteShareKey(forShare: id)
    }

    private func replace(_ record: LiveShareRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
    }

    private func view(of record: LiveShareRecord, now: Int64) -> LiveShareView {
        if let reason = record.endReason {
            return LiveShareView(id: record.id, state: .ended, reason: reason, endAt: record.endAt, lastCounter: nil,
                                 lastFrameAt: nil, position: nil, noCard: record.noCard, endedAt: record.endedAt)
        }
        guard let live = record.live else {
            return LiveShareView(id: record.id, state: .ended, reason: .stateLost, endAt: record.endAt, lastCounter: nil,
                                 lastFrameAt: nil, position: nil, noCard: false, endedAt: record.endedAt)
        }
        let threshold = max(LocationWire.staleFactor * live.interval, LocationWire.staleFloor)
        let state: LiveShareState = now - live.lastFrameAt > threshold ? .stale : .active
        return LiveShareView(id: record.id, state: state, reason: nil, endAt: record.endAt, lastCounter: live.lastCounter,
                             lastFrameAt: live.lastFrameAt, position: live.position, noCard: false)
    }
}

/// A store that keeps everything in memory, for the tests and for a process that has no persistence to give (nothing survives it).
public final class InMemoryLocationShareStore: LocationShareStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: LiveShareRecord] = [:]
    private var order: [String] = []
    private var keys: [String: Data] = [:]
    private var tombstones: [LocationTombstone] = []
    /// When set, every write throws (to test a failed durable write).
    public var failWrites = false

    public struct WriteFailure: Error {}

    public init() {}

    public func load() throws -> LocationShareStoreContents {
        lock.lock()
        defer { lock.unlock() }
        return LocationShareStoreContents(records: order.compactMap { records[$0] }, tombstones: tombstones)
    }

    public func save(_ record: LiveShareRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw WriteFailure() }
        if records[record.id] == nil { order.append(record.id) }
        records[record.id] = record
    }

    public func saveTombstones(_ newTombstones: [LocationTombstone]) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw WriteFailure() }
        tombstones = newTombstones
    }

    public func shareKey(forShare id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys[id]
    }

    public func saveShareKey(_ key: Data, forShare id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failWrites { throw WriteFailure() }
        keys[id] = key
    }

    public func deleteShareKey(forShare id: String) {
        lock.lock()
        keys[id] = nil
        lock.unlock()
    }

    /// Test hook: the counter of a share cannot be read back (the record exists, its live state is gone).
    public func loseCounter(forShare id: String) {
        lock.lock()
        records[id]?.live = nil
        lock.unlock()
    }

    /// Test hook: the key of a share cannot be loaded.
    public func loseKey(forShare id: String) {
        lock.lock()
        keys[id] = nil
        lock.unlock()
    }
}

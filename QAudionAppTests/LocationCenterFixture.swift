import XCTest
@testable import QAudionApp
import QAudionEngine

/// What the tests of `LocationShareCenter` run it against: the message rows and the outbox in memory, a journal in memory, an in-memory
/// store per conversation for the receiver, a socket that is up (or not), and the durable stop recorded instead of sent. Nothing here
/// touches the database, the keychain, the network or the location manager (the permission is an override).
///
/// Not a test class: `LocationShareCenterTests` and `LocationShareCenterEndTests` build one in `setUp` and call `tearDown()`.
/// Wired into CI on the include list of `QAudionApp/project-apptests.yml`.

/// The message table and the outbox, as `LocationRowStore`.
@MainActor
final class FakeLocationRows: LocationRowStore {

    struct Stored {
        var rowId: UUID
        var conversationId: UUID
        var peerUserId: String?
        var outgoing: Bool
        var plaintext: String
        var mediaMimeType: String?
        var deleted: Bool = false
        var expiresAt: Date?
        var timerSeconds: Int?
    }

    /// The rows, by client message id.
    var rows: [String: Stored] = [:]
    /// The retry entries of the outbox, by client message id.
    var outbox: Set<String> = []
    /// The client message ids of the rows that were removed, of the outbox entries that were removed, and of the rows that were put
    /// back to "sending", in order.
    var removedRows: [String] = []
    var removedOutbox: [String] = []
    var requeued: [String] = []
    /// How many times a row was given an expiry.
    var expiryWrites: Int = 0

    func add(clientMsgId: String, peerUserId: String, outgoing: Bool, plaintext: String, timerSeconds: Int? = nil) {
        rows[clientMsgId] = Stored(rowId: UUID(), conversationId: UUID(), peerUserId: peerUserId, outgoing: outgoing,
                                   plaintext: plaintext, mediaMimeType: nil, deleted: false, expiresAt: nil, timerSeconds: timerSeconds)
    }

    func plaintext(of clientMsgId: String) -> String? { rows[clientMsgId]?.plaintext }
    func expiry(of clientMsgId: String) -> Date? { rows[clientMsgId]?.expiresAt }

    // MARK: LocationRowStore

    func row(forClientMsgId id: String) -> LocationRowInfo? {
        guard let stored = rows[id] else { return nil }
        return LocationRowInfo(rowId: stored.rowId, conversationId: stored.conversationId, peerUserId: stored.peerUserId,
                               outgoing: stored.outgoing, plaintext: stored.plaintext, mediaMimeType: stored.mediaMimeType,
                               deleted: stored.deleted, hasExpiry: stored.expiresAt != nil, timerSeconds: stored.timerSeconds)
    }

    func hasOutgoingRow(clientMsgId id: String) -> Bool {
        rows[id]?.outgoing == true
    }

    func setExpiresAt(rowId: UUID, to date: Date) {
        for (id, stored) in rows where stored.rowId == rowId {
            var changed = stored
            changed.expiresAt = date
            rows[id] = changed
            expiryWrites += 1
        }
    }

    func replaceContent(rowId: UUID, plaintext: String, mediaMimeType: String?) {
        for (id, stored) in rows where stored.rowId == rowId {
            var changed = stored
            changed.plaintext = plaintext
            changed.mediaMimeType = mediaMimeType
            rows[id] = changed
        }
    }

    func removeRow(rowId: UUID, conversationId: UUID) {
        for (id, stored) in rows where stored.rowId == rowId {
            rows[id] = nil
            removedRows.append(id)
        }
    }

    func requeue(rowId: UUID, conversationId: UUID) {
        for (id, stored) in rows where stored.rowId == rowId {
            requeued.append(id)
            outbox.insert(id)
        }
    }

    func removeOutboxEntry(clientMsgId id: String) {
        outbox.remove(id)
        removedOutbox.append(id)
    }
}

enum LocationFixtureError: Error {
    case startRefused
}

@MainActor
final class LocationCenterFixture {

    static let selfId = "a353aefc-1716-4516-9ffc-3f8d69ffe0b8"
    static let peerId = "b9d7540f-ece4-4b58-b03b-e0001e522085"
    /// A fixed moment (unix seconds) for the tests that pin the clock.
    static let clock: Int64 = 1_800_000_000

    struct Stop: Equatable {
        let peer: String
        let target: String
        /// `true` when the stop was handed over to be held until it can go, `false` when it is dropped if it cannot go at once.
        let held: Bool
    }

    struct Started {
        let id: String
        let body: String
        let conversationId: UUID
        let startedAt: Int64
        let sid: Data
        let key: Data
    }

    struct Inbound {
        let id: String
        let body: String
        let sid: Data
        let key: Data
        let decision: LocationShareCenter.InboundDecision
    }

    let center: LocationShareCenter = LocationShareCenter.shared
    let rows = FakeLocationRows()
    let journal = InMemoryLocationShareJournal()
    private(set) var stores: [String: InMemoryLocationShareStore] = [:]

    /// What `peersWithRecords` answers at launch.
    var knownPeers: [String] = []
    var frames: [(recipient: String, payload: String)] = []
    var stops: [Stop] = []
    var purgeCalls: [Int64] = []
    var socketUp: Bool = true
    var connectionRequests: Int = 0

    init() {
        LocationShareCenter.featureOverride = true
        LocationShareCenter.nowOverride = nil
        LocationShareCenter.suppressNotices = true
        center.authorizationOverride = true
        center.knownBlocked = []
        center.journal = journal
        center.ports = LocationShareCenter.Ports(
            receiverStore: { [weak self] peer in
                guard let self else { return InMemoryLocationShareStore() }
                return self.store(for: peer)
            },
            peersWithRecords: { [weak self] in self?.knownPeers ?? [] },
            purgeEnded: { [weak self] now in self?.purgeCalls.append(now) },
            rows: rows,
            sendStop: { [weak self] peer, json, held in
                guard let self, case .success(let parsed) = LocationStopControl.parse(utf8: Data(json.utf8)) else { return }
                self.stops.append(Stop(peer: peer, target: parsed.target, held: held))
            })
        center.configure(LocationShareCenter.Environment(
            currentUserId: { LocationCenterFixture.selfId },
            socketReady: { [weak self] in self?.socketUp ?? false },
            sendEphemeral: { [weak self] recipient, payload in
                guard let self else { return false }
                self.frames.append((recipient: recipient, payload: payload))
                return true
            },
            requestConnection: { [weak self] in
                self?.connectionRequests += 1
                return NSObject()
            }))
    }

    func tearDown() {
        center.accountLeft()
        center.ports = LocationShareCenter.Ports()
        center.journal = GRDBLocationShareJournal()
        center.authorizationOverride = nil
        center.knownBlocked = []
        LocationShareCenter.featureOverride = nil
        LocationShareCenter.nowOverride = nil
        LocationShareCenter.suppressNotices = false
    }

    func store(for peer: String) -> InMemoryLocationShareStore {
        if let existing = stores[peer] { return existing }
        let made = InMemoryLocationShareStore()
        stores[peer] = made
        return made
    }

    // MARK: Sending

    func reading(age: TimeInterval = 0) -> LocationReading {
        LocationReading(latitude: 45.4642110, longitude: 9.1899820, horizontalAccuracy: 12,
                        timestamp: Date().addingTimeInterval(-age), speed: -1, reducedAccuracy: false)
    }

    /// A share the user confirmed: the dispatch writes the row (the full start body, key included, as the real one does) and the outbox
    /// entry, then the share is running.
    func startShare(duration: Int64 = 900, peer: String? = nil, timerSeconds: Int? = nil) throws -> Started {
        let peerUserId: String = peer ?? Self.peerId
        let conversationId = UUID()
        var captured: (body: String, id: UUID)?
        let result = center.startLive(reading: reading(), duration: duration, peerUserId: peerUserId, conversationId: conversationId) { body, _, id in
            captured = (body: body, id: id)
            self.rows.add(clientMsgId: id.uuidString, peerUserId: peerUserId, outgoing: true, plaintext: body, timerSeconds: timerSeconds)
            self.rows.outbox.insert(id.uuidString)
        }
        guard case .success = result, let made = captured else { throw LocationFixtureError.startRefused }
        guard case .location(.live(let start, _)) = LocationCodec.recognize(made.body, channel: .chat) else {
            throw LocationFixtureError.startRefused
        }
        return Started(id: made.id.uuidString, body: made.body, conversationId: conversationId, startedAt: start.startedAt,
                       sid: start.sid, key: start.key)
    }

    /// The send path reaches its hand-over to the socket.
    @discardableResult
    func handOver(_ started: Started) -> Bool {
        center.startBeingSent(clientMsgId: started.id)
    }

    /// The server acknowledges the start (`msg_sent`).
    func echo(_ started: Started) {
        center.handleMsgSent(clientMsgId: started.id, serverMsgId: "srv-" + started.id) { _, _ in }
    }

    /// A share that is running and acknowledged: handed over and echoed.
    func startAcknowledgedShare(duration: Int64 = 900, peer: String? = nil, timerSeconds: Int? = nil) throws -> Started {
        let started = try startShare(duration: duration, peer: peer, timerSeconds: timerSeconds)
        handOver(started)
        echo(started)
        return started
    }

    func stopTargets() -> [String] {
        stops.map { $0.target }
    }

    // MARK: Receiving

    /// A live start from `peer`, as the inbound path hands it to the center; when the center says to record it, the row is written
    /// the way the inbound path writes it (the local form, no key) and the center is told.
    func receiveStart(id: String, startedAt: Int64? = nil, duration: Int64 = 900, from peer: String? = nil,
                      timerSeconds: Int? = nil, writeRow: Bool = true) -> Inbound {
        let senderId: String = peer ?? Self.peerId
        let secrets = LocationShareSecrets.generate()
        let st: Int64 = startedAt ?? LocationShareCenter.nowUnix()
        let fix = LocationFix(latitude: 45.4642110, longitude: 9.1899820, horizontalAccuracy: 12, elapsedMs: 3_000, approximate: false)
        guard case .success(let body) = LocationCodec.buildLiveStart(fix: fix, sid: secrets.sid, key: secrets.key, startedAt: st, duration: duration) else {
            preconditionFailure("the builder refused a start of the fixture")
        }
        let decision = center.handleInboundBody(Data(body.utf8), senderId: senderId, clientMsgId: id, viaMesh: false)
        if decision == .record && writeRow {
            rows.add(clientMsgId: id, peerUserId: senderId, outgoing: false,
                     plaintext: LocationRowForm.localForm(sid: secrets.sid, startedAt: st, duration: duration), timerSeconds: timerSeconds)
            center.inboundStartRecorded()
        }
        return Inbound(id: id, body: body, sid: secrets.sid, key: secrets.key, decision: decision)
    }

    /// The share of `peer` with this client message id as the receiver of the center sees it now.
    func received(_ id: String, from peer: String? = nil) -> LiveShareView? {
        center.receivers[peer ?? Self.peerId]?.share(id: id, now: LocationShareCenter.nowUnix())
    }

    // MARK: Restart

    /// The process dies and starts again: the memory of the center is gone, what the journal, the rows and the stores hold stays. The
    /// caller then runs `center.start()`.
    func simulateRestart() {
        for timer in center.tickTimers.values { timer.invalidate() }
        for timer in center.endTimers.values { timer.invalidate() }
        center.housekeepingTimer?.invalidate()
        center.housekeepingTimer = nil
        center.tickTimers.removeAll()
        center.endTimers.removeAll()
        center.runs.removeAll()
        center.peerByStart.removeAll()
        center.waitingForEcho.removeAll()
        center.echoedStarts.removeAll()
        center.withdrawnStarts.removeAll()
        center.ownEnded.removeAll()
        center.expirySettled.removeAll()
        center.receivers.removeAll()
        center.liveReceived.removeAll()
        center.activeShares = []
        center.connectionToken = nil
        center.didStart = false
    }
}

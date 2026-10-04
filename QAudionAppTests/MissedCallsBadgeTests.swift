import XCTest
import Combine
@testable import QAudionApp
import QAudionEngine

/// W-MISSEDBADGE (2026-10-04) — the Calls-tab missed-calls number, driven through the object the app uses
/// (`MissedCallsBadge`) with a fake history, a manual clock and a private defaults suite: badge counting and the
/// "seen" mark, the mark surviving a relaunch, and the reset when the account leaves. The rules themselves
/// (`MissedCallsBadgeState`) are tested in the engine; this pins the connection to the history rows.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class MissedCallsBadgeTests: XCTestCase {

    // MARK: - fixtures

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func record(
        _ id: String, _ direction: CallRecord.Direction, started: TimeInterval, ended: TimeInterval? = nil
    ) -> CallRecord {
        CallRecord(
            id: id, peerUserId: "peer-\(id)", peerDisplayName: "Peer \(id)", direction: direction,
            startedAt: at(started), endedAt: ended.map { at($0) }, isVideo: false, peerExtension: nil)
    }

    /// A fake history, a clock the test moves, and a defaults suite of its own.
    @MainActor
    private final class Rig {
        var records: [CallRecord] = []
        var now: Date
        let changes = PassthroughSubject<Void, Never>()
        let suite: String
        let defaults: UserDefaults
        private(set) var saves = 0

        init(now: Date) {
            let name: String = "missedcalls-tests-\(UUID().uuidString)"
            self.now = now
            self.suite = name
            self.defaults = UserDefaults(suiteName: name)!
        }

        func makeBadge() -> MissedCallsBadge {
            MissedCallsBadge(
                records: { [unowned self] in self.records },
                changes: changes.eraseToAnyPublisher(),
                loadSeenUpTo: { [unowned self] in self.defaults.object(forKey: MissedCallsBadge.seenUpToKey) as? Double },
                saveSeenUpTo: { [unowned self] value in
                    self.saves += 1
                    self.defaults.set(value, forKey: MissedCallsBadge.seenUpToKey)
                },
                clock: { [unowned self] in self.now })
        }

        /// A record joins the history and the store announces the change.
        func add(_ record: CallRecord) {
            records.insert(record, at: 0)
            changes.send()
        }

        var persistedMark: Double? { defaults.object(forKey: MissedCallsBadge.seenUpToKey) as? Double }

        func tearDown() { defaults.removePersistentDomain(forName: suite) }
    }

    @MainActor
    private func makeRig() -> Rig {
        let rig = Rig(now: at(1_000))
        addTeardownBlock { rig.tearDown() }
        return rig
    }

    // MARK: - the rows

    /// Only `.missed` rows are missed calls; a missed call is dated by when it became missed (`endedAt`), or by its start
    /// when it never had an end (a call recorded already missed, with no ring on this device: the busy case).
    @MainActor
    func test_onlyMissedRowsAreMissedCalls_datedByWhenTheyBecameMissed() {
        let stamps = MissedCallsBadge.stamps(of: [
            record("a", .missed, started: 10, ended: 20),
            record("b", .missed, started: 30),
            record("c", .incoming, started: 40, ended: 90),
            record("d", .outgoing, started: 50, ended: 60),
        ])
        XCTAssertEqual(stamps, [
            MissedCallStamp(isMissed: true, at: at(20)),
            MissedCallStamp(isMissed: true, at: at(30)),
            MissedCallStamp(isMissed: false, at: at(90)),
            MissedCallStamp(isMissed: false, at: at(60)),
        ])
    }

    // MARK: - counting

    @MainActor
    func test_theBadgeCountsUnreadMissedCalls_andOnlyThose() {
        let rig = makeRig()
        let badge = rig.makeBadge()
        XCTAssertEqual(badge.unreadCount, 0, "an empty history is no badge")
        rig.add(record("m1", .missed, started: 1_100))
        XCTAssertEqual(badge.unreadCount, 1)
        rig.add(record("answered", .incoming, started: 1_110, ended: 1_150))
        rig.add(record("dialled", .outgoing, started: 1_120, ended: 1_130))
        XCTAssertEqual(badge.unreadCount, 1, "answered and outgoing calls are not missed calls")
        rig.add(record("m2", .missed, started: 1_200))
        XCTAssertEqual(badge.unreadCount, 2)
    }

    /// A call that started ringing before the mark and became missed after it is unread: the row appeared after the
    /// user last looked. Dated by `startedAt` it would be swallowed.
    @MainActor
    func test_aCallThatStartedBeforeTheMarkButBecameMissedAfterItCounts() {
        let rig = makeRig()
        let badge = rig.makeBadge()               // mark = now = 1000
        rig.add(record("late", .missed, started: 990, ended: 1_040))
        XCTAssertEqual(badge.unreadCount, 1)
    }

    /// First run: nothing stored, the mark is now: the missed calls already in the history are not announced.
    @MainActor
    func test_aFirstRunAnnouncesNothingAlreadyInTheHistory_andKeepsTheMark() {
        let rig = makeRig()
        rig.records = [record("old1", .missed, started: 100), record("old2", .missed, started: 900)]
        let badge = rig.makeBadge()
        XCTAssertEqual(badge.unreadCount, 0)
        XCTAssertEqual(rig.persistedMark, at(1_000).timeIntervalSince1970, "the first-run mark is stored")
    }

    // MARK: - seen

    /// Opening the Calls tab clears the number, persists the mark, and the next missed call counts again.
    @MainActor
    func test_openingTheCallsTabMarksEverythingSeen() {
        let rig = makeRig()
        let badge = rig.makeBadge()
        rig.add(record("m1", .missed, started: 1_100))
        rig.add(record("m2", .missed, started: 1_200))
        XCTAssertEqual(badge.unreadCount, 2)
        rig.now = at(1_300)
        badge.markSeen()
        XCTAssertEqual(badge.unreadCount, 0)
        XCTAssertEqual(rig.persistedMark, at(1_300).timeIntervalSince1970)
        rig.add(record("m3", .missed, started: 1_350))
        XCTAssertEqual(badge.unreadCount, 1, "a call missed after the user looked")
    }

    /// Nothing unread: opening the tab writes nothing.
    @MainActor
    func test_markSeenWithNothingUnreadWritesNothing() {
        let rig = makeRig()
        let badge = rig.makeBadge()
        let savesAtStart = rig.saves
        rig.now = at(1_500)
        badge.markSeen()
        XCTAssertEqual(rig.saves, savesAtStart)
        XCTAssertEqual(rig.persistedMark, at(1_000).timeIntervalSince1970, "the mark did not move")
    }

    /// The mark survives a relaunch: a new object over the same defaults restores it.
    @MainActor
    func test_theMarkSurvivesARelaunch() {
        let rig = makeRig()
        let badge = rig.makeBadge()
        rig.add(record("m1", .missed, started: 1_100))
        rig.now = at(1_200)
        badge.markSeen()
        rig.add(record("m2", .missed, started: 1_250))
        XCTAssertEqual(badge.unreadCount, 1)

        rig.now = at(2_000)                       // the app is relaunched much later
        let relaunched = rig.makeBadge()
        XCTAssertEqual(relaunched.unreadCount, 1, "m1 was seen, m2 was not: the stored mark, not 'now', is used")
    }

    // MARK: - the account

    /// A logout / remote wipe / account deletion: the count is gone, the mark starts from now and is stored (so a
    /// relaunch does not mistake the new account's first missed calls for old ones), and what the new account misses
    /// afterwards counts.
    @MainActor
    func test_resetForAccountChange_startsAgainFromNow() {
        let rig = makeRig()
        let badge = rig.makeBadge()
        rig.add(record("a1", .missed, started: 1_100))
        rig.add(record("a2", .missed, started: 1_200))
        XCTAssertEqual(badge.unreadCount, 2)

        rig.now = at(3_000)
        badge.resetForAccountChange()
        XCTAssertEqual(badge.unreadCount, 0, "the previous account's unread calls are not the new account's")
        XCTAssertEqual(rig.persistedMark, at(3_000).timeIntervalSince1970, "the new mark is stored")

        rig.add(record("b1", .missed, started: 3_100))
        XCTAssertEqual(badge.unreadCount, 1, "the new account's first missed call counts")

        let relaunched = rig.makeBadge()
        XCTAssertEqual(relaunched.unreadCount, 1, "and still counts after a relaunch")
    }

    /// Wiping the history under the badge empties the count by itself (the store publishes the change).
    @MainActor
    func test_aWipedHistoryEmptiesTheCount() {
        let rig = makeRig()
        let badge = rig.makeBadge()
        rig.add(record("m1", .missed, started: 1_100))
        XCTAssertEqual(badge.unreadCount, 1)
        rig.records = []
        rig.changes.send()
        XCTAssertEqual(badge.unreadCount, 0)
    }

    // MARK: - a call that is not an unread incoming missed call adds nothing (review of #196)

    /// The numbers on the Calls tab through the REAL store and the same markMissed call the remote-hangup path makes
    /// while a call rings. The caller whose callee declined or hung up while it rang gets no number (its outgoing row
    /// stays outgoing and is closed); a call that rang on this device and was not answered gets one.
    @MainActor
    func test_aDeclinedOutgoingCallAddsNothing_anUnansweredIncomingCallAddsOne() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("missedbadge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let suite = "missedbadge-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = PersistentCallRecordStore(
            keyProvider: PersistentCallRecordStoreTests.FakeKeyProvider(),
            fileURL: dir.appendingPathComponent("call_history.enc"),
            notificationCenter: NotificationCenter(), retryNotifications: [], defaults: defaults)
        // The store announces a change before it makes it; the test announces by hand after each step, so the count
        // is read without waiting for the main queue.
        let changes = PassthroughSubject<Void, Never>()
        let badge = MissedCallsBadge(
            records: { store.records },
            changes: changes.eraseToAnyPublisher(),
            loadSeenUpTo: { nil },
            saveSeenUpTo: { _ in },
            clock: { Date(timeIntervalSinceNow: -60) })
        XCTAssertEqual(badge.unreadCount, 0)

        // The caller: dials, the callee declines while it rings (the remote-hangup path asks markMissed, then endCall).
        store.beginCall(id: "dialled", peerUserId: "callee", peerDisplayName: "Callee", direction: .outgoing, isVideo: false)
        XCTAssertFalse(store.markMissed(id: "dialled"))
        store.endCall(id: "dialled", closeReason: nil)
        changes.send()
        XCTAssertEqual(badge.unreadCount, 0, "a call the user placed is never a missed call")
        XCTAssertEqual(store.records.first(where: { $0.id == "dialled" })?.direction, .outgoing)

        // The callee: the call rings here and the caller gives up.
        store.beginCall(id: "rang", peerUserId: "caller", peerDisplayName: "Caller", direction: .incoming, isVideo: false)
        XCTAssertTrue(store.markMissed(id: "rang"))
        changes.send()
        XCTAssertEqual(badge.unreadCount, 1)

        // The same call reported missed again (the cancel push, then the WS hangup): still one.
        XCTAssertFalse(store.markMissed(id: "rang"))
        changes.send()
        XCTAssertEqual(badge.unreadCount, 1)
    }

    // MARK: - the real store

    /// The convenience initialiser the app uses is wired to the real history store: a missed call recorded through
    /// `PersistentCallRecordStore` is counted (the production path, not the fake). Uses a private store, not the
    /// shared one.
    @MainActor
    func test_theCountFollowsARealHistoryStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("missedbadge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let suite = "missedbadge-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let provider = PersistentCallRecordStoreTests.FakeKeyProvider()
        let store = PersistentCallRecordStore(
            keyProvider: provider, fileURL: dir.appendingPathComponent("call_history.enc"),
            notificationCenter: NotificationCenter(), retryNotifications: [], defaults: defaults)

        let badge = MissedCallsBadge(
            records: { store.records },
            changes: store.objectWillChange.receive(on: DispatchQueue.main).eraseToAnyPublisher(),
            loadSeenUpTo: { nil },
            saveSeenUpTo: { _ in },
            clock: { Date(timeIntervalSinceNow: -60) })
        XCTAssertEqual(badge.unreadCount, 0)

        store.beginCall(id: "busy-1", peerUserId: "caller", peerDisplayName: "Caller", direction: .missed, isVideo: false)
        let counted = expectation(description: "the badge follows the store")
        let watch = badge.$unreadCount.dropFirst().sink { count in if count == 1 { counted.fulfill() } }
        wait(for: [counted], timeout: 5)
        watch.cancel()
        XCTAssertEqual(badge.unreadCount, 1)

        store.wipeAccountHistory()
        let emptied = expectation(description: "the wipe empties it")
        let watchWipe = badge.$unreadCount.dropFirst().sink { count in if count == 0 { emptied.fulfill() } }
        wait(for: [emptied], timeout: 5)
        watchWipe.cancel()
        XCTAssertEqual(badge.unreadCount, 0)
    }
}

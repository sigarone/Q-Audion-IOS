import Foundation
import Combine
import QAudionEngine

/// W-MISSEDBADGE (2026-10-04) — the number on the Calls tab: missed calls the user has not looked at yet.
///
/// The owner spec: a call that reaches a user who is busy, or that he did not answer, shows up in the CALLS section
/// (a history row with who and when, a number on the tab), never through the chat mechanism. The row already existed
/// (`AppState.handleMissedCallEvent`, `PersistentCallRecordStore.markMissed`); this is the number. Android parity:
/// `MissedCallsBadge` / `CallsBadgeViewModel` (branch fix2/wt-missedbadge).
///
/// All the rules are in the engine (`MissedCallsBadgeState`, tested there): the count is derived from the history
/// itself against a persisted "seen up to" mark, so it cannot drift from the list; opening the Calls tab moves the
/// mark; a first run starts the mark at "now". This class only connects them to the history store, to
/// `UserDefaults` and to SwiftUI, and takes everything it touches as a parameter so a test can drive it with a fake
/// history and a private defaults suite.
///
/// ## The account
///
/// The mark belongs to the account on the device. `resetForAccountChange()` is called by
/// `AppState.resetAccountScopedRuntimeState()`, which every wipe path (logout, remote wipe, account deletion) runs
/// right after `LocalCryptoWipe.wipeAll()`: the mark starts again from "now" and is persisted, so the next account
/// never inherits the previous one's, and a relaunch does not mistake the new account's first missed calls for old
/// ones.
@MainActor
final class MissedCallsBadge: ObservableObject {

    /// `UserDefaults` key of the persisted mark (seconds since 1970).
    static let seenUpToKey = "qaudion.missedcalls.seen_up_to"

    /// The one instance the app uses (`AppState`, `HomeView`). Created at launch by `AppState`, so the mark of a
    /// first run is the launch time and not the moment `HomeView` first appeared.
    static let shared = MissedCallsBadge()

    typealias RecordsProvider = @MainActor () -> [CallRecord]

    /// Missed calls since the Calls tab was last on screen; 0 means "no badge".
    @Published private(set) var unreadCount: Int = 0

    private var state: MissedCallsBadgeState
    private let recordsProvider: RecordsProvider
    private let persistSeenUpTo: (TimeInterval) -> Void
    private let clock: () -> Date
    private var changesCancellable: AnyCancellable?

    /// - Parameters:
    ///   - records: the call history, newest first (`PersistentCallRecordStore.records`).
    ///   - changes: fires after every change of the history; the history is read again on each.
    ///   - loadSeenUpTo: the persisted mark, `nil` when there is none.
    ///   - saveSeenUpTo: persists the mark.
    ///   - clock: the phone clock (history rows are dated with it).
    init(
        records: @escaping RecordsProvider,
        changes: AnyPublisher<Void, Never>,
        loadSeenUpTo: () -> TimeInterval?,
        saveSeenUpTo: @escaping (TimeInterval) -> Void,
        clock: @escaping () -> Date = Date.init
    ) {
        self.recordsProvider = records
        self.persistSeenUpTo = saveSeenUpTo
        self.clock = clock
        let stored: TimeInterval? = loadSeenUpTo()
        let restored: MissedCallsBadgeState = MissedCallsBadgeState.restored(stored: stored, now: clock())
        self.state = restored
        if stored == nil || (stored ?? 0) <= 0 {
            // First run: the mark is "now" and it is kept, or the next launch would start it again.
            saveSeenUpTo(restored.seenUpTo.timeIntervalSince1970)
        }
        self.changesCancellable = changes.sink { [weak self] _ in
            self?.recount()
        }
        recount()
    }

    /// The app's instance: the call history store and `UserDefaults.standard`.
    convenience init() {
        let store = PersistentCallRecordStore.shared
        let defaults = UserDefaults.standard
        // `objectWillChange` fires BEFORE the change; `receive(on:)` defers the read to the next main-queue turn, by
        // which time `records` holds the new value (the same pattern the CarPlay recents use).
        let changes: AnyPublisher<Void, Never> = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
        self.init(
            records: { store.records },
            changes: changes,
            loadSeenUpTo: { defaults.object(forKey: MissedCallsBadge.seenUpToKey) as? Double },
            saveSeenUpTo: { defaults.set($0, forKey: MissedCallsBadge.seenUpToKey) })
    }

    /// The history rows as the engine counts them: a missed call is dated by when it became missed.
    static func stamps(of records: [CallRecord]) -> [MissedCallStamp] {
        records.map { MissedCallStamp(isMissed: $0.direction == .missed, at: $0.endedAt ?? $0.startedAt) }
    }

    private func recount() {
        let count: Int = state.unreadCount(in: Self.stamps(of: recordsProvider()))
        if count != unreadCount { unreadCount = count }
    }

    /// The Calls tab is on screen (selected, app active): everything missed so far is seen. Does nothing, and writes
    /// nothing, when there is nothing unread.
    func markSeen() {
        let stamps: [MissedCallStamp] = Self.stamps(of: recordsProvider())
        guard state.unreadCount(in: stamps) > 0 else { return }
        guard state.markSeen(now: clock(), in: stamps) else { return }
        persistSeenUpTo(state.seenUpTo.timeIntervalSince1970)
        recount()
    }

    /// The account on this device changed or left (see the type's doc): nothing is unread, the mark starts from now.
    func resetForAccountChange() {
        state = MissedCallsBadgeState.forNewAccount(now: clock())
        persistSeenUpTo(state.seenUpTo.timeIntervalSince1970)
        recount()
    }
}

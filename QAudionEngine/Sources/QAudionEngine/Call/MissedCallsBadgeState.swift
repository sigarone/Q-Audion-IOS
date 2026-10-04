import Foundation

/// W-MISSEDBADGE (2026-10-04) — the pure part of the unread-missed-calls badge on the Calls tab.
///
/// ## The spec
///
/// A call that reaches a user who is busy in another call, or that he did not answer, belongs to the CALLS section:
/// a missed-call row (who and when) in the history and a number on the Calls tab. It never goes through the chat
/// mechanism. The history row already exists on iOS (`AppState.handleMissedCallEvent`, `markMissed`); what was missing
/// is the number. This mirrors Android's `MissedCallsBadge` / `CallsBadgeViewModel`.
///
/// ## The model (the Android one)
///
/// The count is derived from the history itself, not kept as a second counter, so it cannot drift from what the list
/// shows: it is the number of missed calls that happened AFTER a persisted "seen up to" mark, the instant the user
/// last had the Calls tab on screen. Opening the Calls tab moves the mark ("seen"), which is the only way the count
/// goes down. First run (nothing stored): the mark starts at "now", so the missed calls already in the history when
/// this feature first ships are not announced as new. The mark belongs to the account: a logout / remote wipe /
/// account deletion starts it again from "now".
///
/// A missed call is dated by when it BECAME missed (`endedAt`, the moment the ring was cancelled or timed out), and by
/// its start when it never had an end (`handleMissedCallEvent` inserts it already `.missed`, with no ring on this
/// device). A call that started ringing before the user looked at the tab and was missed after it counts, which is
/// the right answer: he has not seen that row.
public struct MissedCallStamp: Equatable, Sendable {
    /// The history row is a missed call.
    public let isMissed: Bool
    /// When it became missed (`endedAt ?? startedAt`).
    public let at: Date

    public init(isMissed: Bool, at: Date) {
        self.isMissed = isMissed
        self.at = at
    }
}

public struct MissedCallsBadgeState: Equatable, Sendable {

    /// Everything missed up to this instant has been seen.
    public private(set) var seenUpTo: Date

    public init(seenUpTo: Date) {
        self.seenUpTo = seenUpTo
    }

    /// The state at start-up: the stored mark, or `now` when there is none (first run: nothing already in the
    /// history is announced).
    public static func restored(stored: TimeInterval?, now: Date) -> MissedCallsBadgeState {
        guard let stored, stored > 0 else { return MissedCallsBadgeState(seenUpTo: now) }
        return MissedCallsBadgeState(seenUpTo: Date(timeIntervalSince1970: stored))
    }

    /// The state for a new account on this device: nothing is unread, whatever the previous account had.
    public static func forNewAccount(now: Date) -> MissedCallsBadgeState {
        MissedCallsBadgeState(seenUpTo: now)
    }

    /// How many missed calls came after the mark.
    public func unreadCount(in stamps: [MissedCallStamp]) -> Int {
        var n = 0
        for stamp in stamps where stamp.isMissed && stamp.at > seenUpTo { n += 1 }
        return n
    }

    /// The user is looking at the Calls tab: everything missed up to now is seen. The mark is the later of `now`
    /// and the newest missed call, so a row dated ahead of the phone clock (a clock that was set back) cannot stay
    /// unread under the eyes of the user. Returns whether the mark moved.
    @discardableResult
    public mutating func markSeen(now: Date, in stamps: [MissedCallStamp]) -> Bool {
        var upTo = now
        for stamp in stamps where stamp.isMissed && stamp.at > upTo { upTo = stamp.at }
        guard upTo > seenUpTo else { return false }
        seenUpTo = upTo
        return true
    }

    /// The Calls tab counts as looked at only while it is selected AND the app is on screen: a tab left selected
    /// in a backgrounded app has not shown anything to anybody.
    public static func countsAsLookedAt(callsTabSelected: Bool, appActive: Bool) -> Bool {
        callsTabSelected && appActive
    }
}

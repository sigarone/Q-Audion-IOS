import Foundation

/// W142 — client-side "last seen at" tracker.
///
/// The engine's `BCryptoPresenceManager` only exposes the *current*
/// online/offline status of a userId, not a timestamp of when the peer
/// was last observed. Most chat UIs expect "ultimo accesso 14:32" when
/// the peer is offline, so we approximate it client-side: every time
/// `recordOnline(_:)` fires for a userId, we stamp `Date()` into
/// UserDefaults. When the bubble or topbar wants to render presence,
/// `lastSeenAt(for:)` reads that timestamp.
///
/// **Trade-offs.**
///   - This is a *local* approximation — two devices observing the
///     same peer will not necessarily agree on "last seen", because
///     each only stamps when its own WS connection saw the peer online.
///   - We don't persist offline transitions; only online observations
///     matter (the peer can't be "last seen" at the moment they went
///     offline, only at the last moment they were known online).
///   - Throttled to one stamp per minute per userId so a chatty
///     presence stream doesn't churn UserDefaults.
///   - We don't expose this on the wire — peers can't read each
///     other's stamps. This is purely a UI nicety.
enum LastSeenTracker {

    /// Throttle window — duplicate online observations within this
    /// many seconds are coalesced into a single UserDefaults write.
    private static let throttleSeconds: TimeInterval = 60

    private static func key(_ userId: String) -> String {
        "qa.lastSeenAt.\(userId)"
    }

    /// Stamp `Date()` for `userId`. Idempotent within `throttleSeconds`.
    /// Empty userId is a no-op (defensive — guards against accidental
    /// `subscribe(["", ...])`).
    static func recordOnline(_ userId: String) {
        guard !userId.isEmpty else { return }
        let k = key(userId)
        let now = Date()
        if let prior = UserDefaults.standard.object(forKey: k) as? Date,
           now.timeIntervalSince(prior) < throttleSeconds {
            return
        }
        UserDefaults.standard.set(now, forKey: k)
    }

    /// Read the most-recent online observation. Returns nil when we've
    /// never seen this peer online on this device.
    static func lastSeenAt(for userId: String) -> Date? {
        UserDefaults.standard.object(forKey: key(userId)) as? Date
    }

    /// Drop the stamp for a single user — used by privacy / reset flows.
    static func clear(for userId: String) {
        UserDefaults.standard.removeObject(forKey: key(userId))
    }

    /// Render an Italian "ultimo accesso …" line for the topbar.
    /// nil → falls back to the caller's default ("offline / cifrato").
    /// Tiers:
    ///   - < 60s : "ultimo accesso ora"
    ///   - same day : "ultimo accesso alle HH:mm"
    ///   - same week : "ultimo accesso <weekday> HH:mm"
    ///   - older : "ultimo accesso il dd/MM"
    static func formatPresenceLabel(for userId: String,
                                    now: Date = Date()) -> String? {
        guard let seen = lastSeenAt(for: userId) else { return nil }
        let elapsed = now.timeIntervalSince(seen)
        if elapsed < 60 {
            return "ultimo accesso ora"
        }
        let cal = Calendar.current
        if cal.isDate(seen, inSameDayAs: now) {
            return "ultimo accesso alle \(timeFormatter.string(from: seen))"
        }
        if cal.isDateInYesterday(seen) {
            return "ultimo accesso ieri \(timeFormatter.string(from: seen))"
        }
        if elapsed < (60 * 60 * 24 * 7) {
            return "ultimo accesso \(weekdayFormatter.string(from: seen)) \(timeFormatter.string(from: seen))"
        }
        return "ultimo accesso il \(shortDateFormatter.string(from: seen))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "dd/MM"
        return f
    }()
}

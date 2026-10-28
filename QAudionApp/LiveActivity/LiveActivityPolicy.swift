import Foundation

/// The pure rules of the Live Activities: which transfers get one, how often it is updated, what it says about the contact, and what
/// has to start, change or end when the set of shares changes. No ActivityKit here, so the unit tests run anywhere.
enum LiveActivityPolicy {

    /// A transfer gets an activity only when the file is larger than this.
    static let fileThresholdBytes: Int64 = 5_000_000

    /// A transfer's activity is updated at most this often (seconds).
    static let minUpdateInterval: TimeInterval = 2

    static func qualifiesFile(totalBytes: Int64) -> Bool {
        totalBytes > fileThresholdBytes
    }

    /// `done / total` as `0...1` (0 when the total is not known).
    static func fraction(done: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// The contact is named only when message previews are allowed in notifications (both gates of the privacy settings: the
    /// preview switch and the "hide notification content" switch). Otherwise `nil`: the activity shows its generic line.
    static func previewsAllowed(messagePreviewInNotifications: Bool, hideNotificationContent: Bool) -> Bool {
        messagePreviewInNotifications && !hideNotificationContent
    }

    static func contactName(_ name: String, previewsAllowed: Bool) -> String? {
        guard previewsAllowed else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A share that is sent from this device, as far as the activity is concerned.
    struct Share: Equatable {
        let id: String
        let peerUserId: String
        let startedAt: Date
        let endAt: Date
    }

    /// The state of a location share's activity.
    static func content(for share: Share, name: String, previewsAllowed: Bool) -> LiveActivityContent {
        LiveActivityContent(
            contactName: contactName(name, previewsAllowed: previewsAllowed),
            startDate: share.startedAt, endDate: share.endAt, progress: 0)
    }

    /// The state of a transfer's activity.
    static func content(startedAt: Date, done: Int64, total: Int64) -> LiveActivityContent {
        LiveActivityContent(contactName: nil, startDate: startedAt, endDate: nil, progress: fraction(done: done, total: total))
    }

    /// What to do to bring the running activities in line with the wanted ones.
    struct Plan: Equatable {
        var start: [String] = []
        var update: [String] = []
        var end: [String] = []
    }

    static func plan(running: [String: LiveActivityContent], wanted: [String: LiveActivityContent]) -> Plan {
        var plan = Plan()
        for id in wanted.keys.sorted() {
            guard let current = running[id] else { plan.start.append(id); continue }
            if current != wanted[id] { plan.update.append(id) }
        }
        for id in running.keys.sorted() where wanted[id] == nil { plan.end.append(id) }
        return plan
    }
}

/// Lets a transfer's activity through at most every `LiveActivityPolicy.minUpdateInterval` seconds, and only when the progress moved.
struct LiveActivityThrottle {
    private var lastAt: TimeInterval?
    private var lastProgress: Double = -1

    init() {}

    /// `true` when this progress should reach the activity now. `now` is any monotonic clock in seconds.
    mutating func accept(progress: Double, now: TimeInterval) -> Bool {
        if let last = lastAt {
            guard now - last >= LiveActivityPolicy.minUpdateInterval else { return false }
            guard progress != lastProgress else { return false }
        }
        lastAt = now
        lastProgress = progress
        return true
    }
}

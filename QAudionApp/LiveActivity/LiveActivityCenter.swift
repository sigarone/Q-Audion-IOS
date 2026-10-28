import Foundation
import Combine
#if canImport(ActivityKit)
import ActivityKit
#endif

/// The Live Activities of the app: a live location share this device is sending, and a file transfer larger than
/// `LiveActivityPolicy.fileThresholdBytes`. Every update is local (ActivityKit push tokens are never requested, so nothing about an
/// activity reaches a server). The rules are in `LiveActivityPolicy`; this file only talks to ActivityKit.
///
/// Callers use `LiveActivities`, which does the availability check: the app targets iOS 16.0 and drives activities from 16.2.
enum LiveActivities {

    /// Binds the activities to the location shares and ends the ones left by a previous process. Idempotent.
    @MainActor static func start() {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) { LiveActivityCenter.shared.start() }
        #endif
    }

    /// The progress of a transfer (`key` names it); the activity begins at the first call for a file above the threshold.
    @MainActor static func transferProgress(key: String, sending: Bool, done: Int64, total: Int64) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) {
            LiveActivityCenter.shared.transferProgress(key: key, sending: sending, done: done, total: total)
        }
        #endif
    }

    /// The transfer is over, done or failed or cancelled: its activity ends.
    @MainActor static func transferEnded(key: String) {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) { LiveActivityCenter.shared.endTransfer(key: key) }
        #endif
    }

    /// Logout, wipe, account deletion: every activity ends.
    @MainActor static func endAll() {
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *) { LiveActivityCenter.shared.endAll() }
        #endif
    }
}

#if canImport(ActivityKit)
@available(iOS 16.2, *)
@MainActor
final class LiveActivityCenter {

    static let shared = LiveActivityCenter()

    private var activities: [String: Activity<QAudionActivityAttributes>] = [:]
    private var contents: [String: LiveActivityContent] = [:]
    private var throttles: [String: LiveActivityThrottle] = [:]
    private var transferStart: [String: Date] = [:]
    private var shareIds: Set<String> = []
    private var latestShares: [LocationShareCenter.ActiveShare] = []
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private init() {}

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        // A process that begins again never resumes a share or a transfer, so an activity found now is a leftover.
        for leftover in Activity<QAudionActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        if #available(iOS 17.0, *) {
            LiveActivityActionHub.stopLocationShare = { id in
                LocationShareCenter.shared.stopShare(startClientMsgId: id, reason: "user", final: .onTick)
            }
        }
        // `@Published` publishes before the property changes: the list is taken from the value it hands over.
        LocationShareCenter.shared.$activeShares
            .sink { [weak self] shares in
                self?.latestShares = shares
                self?.reconcileShares()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.previewSettingMayHaveChanged() }
            .store(in: &cancellables)
    }

    // MARK: Location shares

    private static var previewsAllowed: Bool {
        let hide: Bool = (UserDefaults.standard.object(forKey: "qaudion.privacy.hide_notification_content") as? Bool) ?? false
        return LiveActivityPolicy.previewsAllowed(
            messagePreviewInNotifications: PrivacyGate.messagePreviewInNotifications, hideNotificationContent: hide)
    }

    private func previewSettingMayHaveChanged() {
        guard !shareIds.isEmpty else { return }
        reconcileShares()
    }

    private func reconcileShares() {
        let allowed: Bool = Self.previewsAllowed
        var wanted: [String: LiveActivityContent] = [:]
        for share in latestShares {
            let facts = LiveActivityPolicy.Share(id: share.id, peerUserId: share.peerUserId, startedAt: share.startedAt, endAt: share.endAt)
            wanted[share.id] = LiveActivityPolicy.content(
                for: facts, name: DisplayName.forUser(share.peerUserId), previewsAllowed: allowed)
        }
        var running: [String: LiveActivityContent] = [:]
        for id in shareIds {
            if let current = contents[id] { running[id] = current }
        }
        let plan = LiveActivityPolicy.plan(running: running, wanted: wanted)
        for id in plan.end { finish(id) }
        for id in plan.update {
            if let content = wanted[id] { update(id, content) }
        }
        for id in plan.start {
            if let content = wanted[id] { begin(id: id, kind: .locationShare, content: content) }
        }
        shareIds = Set(wanted.keys).intersection(activities.keys)
    }

    // MARK: Transfers

    func transferProgress(key: String, sending: Bool, done: Int64, total: Int64) {
        guard LiveActivityPolicy.qualifiesFile(totalBytes: total) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fraction = LiveActivityPolicy.fraction(done: done, total: total)
        if activities[key] == nil {
            guard transferStart[key] == nil else { return }
            let began = Date()
            transferStart[key] = began
            var throttle = LiveActivityThrottle()
            _ = throttle.accept(progress: fraction, now: now)
            throttles[key] = throttle
            begin(id: key, kind: sending ? .fileSend : .fileReceive,
                  content: LiveActivityPolicy.content(startedAt: began, done: done, total: total))
            return
        }
        guard var throttle = throttles[key], let began = transferStart[key] else { return }
        let pass = throttle.accept(progress: fraction, now: now)
        throttles[key] = throttle
        if pass { update(key, LiveActivityPolicy.content(startedAt: began, done: done, total: total)) }
    }

    func endTransfer(key: String) {
        transferStart[key] = nil
        throttles[key] = nil
        finish(key)
    }

    // MARK: ActivityKit

    private func begin(id: String, kind: LiveActivityKind, content: LiveActivityContent) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, activities[id] == nil else { return }
        let attributes = QAudionActivityAttributes(kind: kind, itemId: id)
        let activityContent = ActivityContent(state: content, staleDate: content.endDate)
        do {
            // pushType nil: the activity is updated by this process only.
            activities[id] = try Activity<QAudionActivityAttributes>.request(
                attributes: attributes, content: activityContent, pushType: nil)
            contents[id] = content
        } catch {
            RTLog.info("chat", "liveactivity begin failed")
        }
    }

    private func update(_ id: String, _ content: LiveActivityContent) {
        guard let activity = activities[id] else { return }
        contents[id] = content
        let activityContent = ActivityContent(state: content, staleDate: content.endDate)
        Task { await activity.update(activityContent) }
    }

    private func finish(_ id: String) {
        contents[id] = nil
        guard let activity = activities.removeValue(forKey: id) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    func endAll() {
        for id in Array(activities.keys) { finish(id) }
        for leftover in Activity<QAudionActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        shareIds.removeAll()
        transferStart.removeAll()
        throttles.removeAll()
        latestShares = []
    }
}
#endif

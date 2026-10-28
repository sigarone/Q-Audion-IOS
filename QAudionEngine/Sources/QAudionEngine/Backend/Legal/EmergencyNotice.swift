import Foundation

/// Where the "already shown" flag of the emergency notice lives.
public protocol EmergencyNoticeFlagStore: AnyObject {
    var acknowledged: Bool { get set }
}

/// The flag in `UserDefaults`.
public final class UserDefaultsEmergencyNoticeFlag: EmergencyNoticeFlagStore {
    public static let key = "qaudion.legal.emergencyNoticeAcknowledged"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var acknowledged: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The emergency notice (art. 16.3 summary) is shown once, before the first outgoing call, and stays readable in
/// Settings > Legal and in About.
public enum EmergencyNoticePolicy {
    public enum Decision: Equatable, Sendable {
        /// Place the call now.
        case proceed
        /// Show this text first, place the call when it is acknowledged.
        case show(String)
    }

    /// `noticeText` is the server's `emergency_notice`, or nil when it could not be read: a call is never held
    /// back for a text the app does not have, and the notice then waits for the next first call.
    public static func decide(acknowledged: Bool, noticeText: String?) -> Decision {
        guard !acknowledged else { return .proceed }
        guard let text = noticeText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .proceed
        }
        return .show(text)
    }
}

/// Shows the emergency notice before the first outgoing call, and never holds a call back for it.
///
/// `confirmBeforeFirstCall()` returns at once when the notice was acknowledged, when the text cannot be read in a few
/// seconds, when the app is not in the foreground (a call started from Siri, CallKit or the car has no screen to put
/// the notice on), or when nobody answers the alert within `answerTimeoutSeconds`. In every case but the tap on "Ho
/// capito" the flag stays unset, so the notice comes with the next first call that can show it. The caller releases
/// its own start gate after this returns, on every path.
@MainActor
public final class EmergencyNoticeCoordinator: ObservableObject {
    @Published public private(set) var pendingText: String?

    private let flag: EmergencyNoticeFlagStore
    private let isSceneActive: @MainActor () -> Bool
    private let answerTimeoutSeconds: Double
    private let fetchTimeoutSeconds: Double
    private var textProvider: (@MainActor () -> (@Sendable () async -> String?)?)?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var asking = false

    public init(flag: EmergencyNoticeFlagStore = UserDefaultsEmergencyNoticeFlag(),
                isSceneActive: @escaping @MainActor () -> Bool = { true },
                answerTimeoutSeconds: Double = 10,
                fetchTimeoutSeconds: Double = 4) {
        self.flag = flag
        self.isSceneActive = isSceneActive
        self.answerTimeoutSeconds = answerTimeoutSeconds
        self.fetchTimeoutSeconds = fetchTimeoutSeconds
    }

    /// `provider` returns the way to read the notice text (nil when there is no way to reach the server now).
    public func configure(textProvider provider: @escaping @MainActor () -> (@Sendable () async -> String?)?) {
        textProvider = provider
    }

    public var isAcknowledged: Bool { flag.acknowledged }

    public func confirmBeforeFirstCall() async {
        guard !flag.acknowledged else { return }
        guard isSceneActive() else { return }
        if asking {
            // A second start while the first waits for the answer waits for the same answer, for the same time at most.
            await waitForAnswer()
            return
        }
        asking = true
        defer { asking = false }
        let text = await Self.firstResult(of: textProvider?(), timeoutSeconds: fetchTimeoutSeconds)
        // The wait for the text may have outlasted the foreground.
        guard isSceneActive() else { return }
        switch EmergencyNoticePolicy.decide(acknowledged: flag.acknowledged, noticeText: text) {
        case .proceed:
            return
        case .show(let shown):
            pendingText = shown
            await waitForAnswer()
        }
    }

    /// The person tapped "Ho capito".
    public func acknowledge() {
        flag.acknowledged = true
        pendingText = nil
        let all = waiters
        waiters.removeAll()
        all.values.forEach { $0.resume() }
    }

    private func waitForAnswer() async {
        let id = UUID()
        let seconds = answerTimeoutSeconds
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.expire(id)
            }
        }
    }

    /// No answer in time: the waiting call goes ahead, the alert goes away and the flag is left as it was.
    private func expire(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        if waiters.isEmpty { pendingText = nil }
        continuation.resume()
    }

    private static func firstResult(of read: (@Sendable () async -> String?)?, timeoutSeconds: Double) async -> String? {
        guard let read else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await read() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

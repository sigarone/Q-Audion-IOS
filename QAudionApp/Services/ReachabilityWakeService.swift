import Foundation
import Network

/// W-CONNWANT (piece 3) — arms a background `URLSession` the moment the
/// network genuinely goes unreachable, so the OS itself resumes this
/// process — even from full suspension, hours later — the instant it can
/// complete the request.
///
/// **Why this exists.** Once iOS suspends the app, nothing in-process runs
/// anymore: no `NWPathMonitor` callback, no ping/pong timer, no
/// `DispatchSourceTimer`. A device that loses its network overnight and gets
/// it back at 6 AM has nothing left to notice the change until the user
/// manually reopens the app. A background `URLSession` is the one OS-level
/// primitive that keeps working through that: the system itself retries the
/// task and launches/resumes the process when it can finally complete it,
/// independent of whether anything in-process is still alive to ask.
///
/// **What it deliberately does NOT do.** It never force-reconnects the
/// persistent WS from a raw path-status edge — that storm (a `forceReconnect`
/// on every `NWPathMonitor` callback re-triggering the very monitor that
/// fired it) is exactly what the WS client's own path handler was fixed to
/// stop doing. This service only fires a request when the path flips
/// satisfied → unsatisfied (a real edge, not a repeat callback for the same
/// state — `NWPathMonitor` reports plenty of those), and only ever reports
/// "the task completed" — the *caller* (`AppState`) decides what to do with
/// that, through the exact same wake-reconciliation path a manual foreground
/// already uses.
///
/// All mutable state is guarded by `stateLock` — the `URLSessionDownloadDelegate`
/// callbacks below arrive on the session's own delegate queue, not
/// necessarily the main thread, so this can never be assumed single-threaded
/// the way a MainActor type would be. Same shape as `BCryptoWebSocketClient`'s
/// `@unchecked Sendable` + `NSLock` for the identical reason.
final class ReachabilityWakeService: NSObject, @unchecked Sendable {

    static let shared = ReachabilityWakeService()
    static let backgroundSessionIdentifier = "com.qaudion.app.reachability-wake"

    private let stateLock = NSLock()
    private var _pendingSystemCompletionHandler: (() -> Void)?
    private var _onWakeup: (@MainActor () -> Void)?
    private var monitor: NWPathMonitor?
    private var lastSatisfied: Bool?
    private var wakeupURL: URL?
    private var armedTaskInFlight = false

    /// Set by `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Apple's contract: call it once every task belonging to this session
    /// has finished delivering its delegate callbacks.
    var pendingSystemCompletionHandler: (() -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _pendingSystemCompletionHandler }
        set { stateLock.lock(); _pendingSystemCompletionHandler = newValue; stateLock.unlock() }
    }

    /// Forces the background session (and therefore its delegate hookup) to
    /// exist immediately. Called from the `AppDelegate` background-events
    /// entry point, which can run before `start(serverUrl:onWakeup:)` has —
    /// SwiftUI's own launch sequence for a pure background relaunch is not
    /// guaranteed to reach `.onAppear` first. Without this, a background
    /// relaunch that hasn't reached `start()` yet would have no session
    /// object to receive the OS's replayed delegate callbacks on.
    func ensureSessionExists() { _ = session() }

    private var _session: URLSession?

    /// Lazily built under `stateLock` (not a plain `lazy var`, which is not
    /// thread-safe): `ensureSessionExists()` (main thread, from the
    /// `AppDelegate` hook) and `armWakeupTask()` (the path-monitor's own
    /// queue) can plausibly race on first access, and Apple's API does not
    /// tolerate two `URLSession`s created for the same background
    /// identifier at once.
    private func session() -> URLSession {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = _session { return existing }
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = created
        return created
    }

    private override init() { super.init() }

    /// Start watching for the network going away. Idempotent — safe to call
    /// on every launch. `serverUrl` is the same primitive the sibling
    /// services (`LiveLogStreamer`, `TelemetryService`, `SelfTestService`)
    /// already take — no `AppState` reference held here.
    func start(serverUrl: String, onWakeup: @escaping @MainActor () -> Void) {
        stateLock.lock()
        _onWakeup = onWakeup
        wakeupURL = URL(string: serverUrl + "/api/v1/health")
        let alreadyStarted = monitor != nil
        stateLock.unlock()
        guard !alreadyStarted else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(satisfied: path.status == .satisfied)
        }
        stateLock.lock()
        monitor = pathMonitor
        stateLock.unlock()
        pathMonitor.start(queue: DispatchQueue(label: "\(Self.backgroundSessionIdentifier).monitor"))
    }

    private func handlePathUpdate(satisfied: Bool) {
        stateLock.lock()
        // Only act on a genuine edge. NWPathMonitor repeats the same status
        // routinely; reacting to every callback instead of only a real
        // transition is the storm this codebase already learned to avoid
        // elsewhere — same lesson, different call site.
        guard lastSatisfied != satisfied else { stateLock.unlock(); return }
        lastSatisfied = satisfied
        stateLock.unlock()
        guard !satisfied else { return }
        armWakeupTask()
    }

    private func armWakeupTask() {
        stateLock.lock()
        guard !armedTaskInFlight, let url = wakeupURL else { stateLock.unlock(); return }
        armedTaskInFlight = true
        stateLock.unlock()
        let task = session().downloadTask(with: url)
        task.resume()
    }
}

extension ReachabilityWakeService: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The body is never read — only reachability matters here — but the
        // OS-managed temp file must not linger.
        try? FileManager.default.removeItem(at: location)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        armedTaskInFlight = false
        let callback = _onWakeup
        stateLock.unlock()
        Task { @MainActor in callback?() }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = pendingSystemCompletionHandler
        pendingSystemCompletionHandler = nil
        guard let completion else { return }
        DispatchQueue.main.async { completion() }
    }
}

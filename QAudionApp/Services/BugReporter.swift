import Foundation
import UIKit
import AVFoundation
import QAudionEngine

/// W559 — Cross-platform bug report service.
///
/// **Triggers:**
///   - Manual: volume up-then-down (or down-then-up) within 400ms, two presses in the same
///     direction within 600ms, or a shake → overlay sheet. W-BUGREPPHANTOM (2026-10-02):
///     only real button presses count (`VolumeGestureDetector`); the output-volume changes
///     of an audio route change or a call transition used to open the sheet by
///     themselves at every 1:1 -> group hand-over.
///   - Auto: 2+ errors with the same tag in monitored categories within 60s → silent banner.
///
/// **Capture:** a screenshot and the log tail at trigger time, then AGAIN at send time
/// (the sheet can stay up for a while): the uploaded image shows both moments side by
/// side, the log covers from `logWindowMinutes` before the trigger up to the send.
///
/// **API constraint (CLAUDE.md rule #16):** never takes `AppState` as a parameter type.
/// All AppState values are accessed via closures injected from `AppState.initialize()`.
@MainActor
public final class BugReporter: ObservableObject {

    public static let shared = BugReporter()

    // MARK: - Closure types (no AppState in signature)

    public typealias TokenProvider = @MainActor () -> String?
    public typealias ServerUrlProvider = () -> String
    /// W561 — the callId of whatever call (1:1 or group) is active right now,
    /// or nil. Populates the server's `call_id` form field (already accepted
    /// by `reports.SubmitInput` — previously never populated by ANY client,
    /// so a report never self-identified which call it was about) — lets a
    /// report be correlated against `qa-logs.ps1`/`tune-report.py` without
    /// the user having to separately state which call they mean.
    public typealias ActiveCallIdProvider = @MainActor () -> String?
    /// W561 — a compact JSON snapshot (call state, roster, WS connection
    /// state) built entirely inside AppState (primitives across the
    /// boundary — a String, per CLAUDE.md rule #16) and folded into the
    /// report's encrypted body so the report is self-contained: readable
    /// evidence of what the app's OWN state was at trigger time, not just a
    /// screenshot + free-text log tail. See `AppState.buildDiagSnapshotJSON`.
    public typealias DiagSnapshotProvider = @MainActor () -> String

    // MARK: - Published state (SwiftUI overlay observes these)

    @Published public private(set) var isShowingOverlay: Bool = false
    @Published public private(set) var pendingReport: PendingReport?

    // MARK: - Pending report model

    public struct PendingReport {
        /// Trigger-time screenshot; at send time it becomes the trigger-time and the
        /// send-time screenshots side by side.
        public var screenshot: UIImage?
        /// Trigger-time log tail, as a raw (unredacted) copy of the ring; at send time it is
        /// replaced by the longer window. W-REPORTFREEZE: kept as entries, not as text, so the
        /// expensive redaction runs off the main actor (`BugReportAssembler`).
        var logEntries: [LiveLogRawEntry]
        public let trigger: String
        public let capturedAt: Date
        /// Extra plaintext multipart fields (abuse reports: the reported
        /// user/group id so triage can act without decrypting the body).
        /// Defaulted so the existing 4-argument call sites keep compiling.
        public var extraFields: [String: String] = [:]
        /// How a manual report was opened (`TriggerSource.rawValue`; 0 = not manual).
        public var source: Int = 0
        /// Filled at send time, for the report's own "report" block.
        public var sendDelayMs: Int = 0
        public var logWindowMinutes: Double = 0
        public var screenshotCount: Int = 0
    }

    /// How a manual report was opened. Logged (`trig src=<n>`) and shown on the sheet.
    public enum TriggerSource: Int {
        case volumeGesture = 1
        case shake = 2
    }

    /// Minutes of log before the trigger that a report carries; group calls ask for more
    /// (`setLogWindowProvider`).
    public typealias LogWindowProvider = @MainActor () -> Double
    public static let defaultLogWindowMinutes: Double = 2

    // MARK: - Private state

    private var getToken: TokenProvider?
    private var getServerUrl: ServerUrlProvider?
    private var getActiveCallId: ActiveCallIdProvider?
    private var getDiagSnapshot: DiagSnapshotProvider?

    /// W561 — admin X25519 pubkey cache (fetched once, reused for the
    /// process lifetime). Mirrors Android's `cachedAdminPubKey`. No
    /// `@Volatile`/lock needed — this whole class is `@MainActor`.
    private var cachedAdminPubKeyHex: String?

    private var getLogWindowMinutes: LogWindowProvider?

    /// W-RETRYAFTER (2026-10-03) -- reports waiting for the server. A report the user took the
    /// trouble to write used to be thrown away on the first failed upload (a 429 from the
    /// per-IP limiter, a 5xx, a dropped connection: one attempt, one log line, gone). Now it
    /// stays here, in memory, until the server takes it. Bounded: a report holds a screenshot
    /// and a log window, so only `maxQueuedReports` wait at once; when a new one arrives
    /// beyond that the OLDEST is dropped, with a log line.
    ///
    /// `callId` and `diagSnapshot` are fixed when the report is QUEUED and travel with it: a
    /// report kept for a retry 30-300+ s later must still say which call it was about and what
    /// the app's state was at trigger time, not the call (and state) the user is in by then.
    /// The token and the server URL are different: they are read again on every attempt, so a
    /// retry never uses a token that was refreshed or revoked in the meantime.
    struct QueuedReport {
        let id = UUID()
        let report: PendingReport
        let note: String
        let callId: String
        let diagSnapshot: String
        var attempts: Int = 0
    }
    private var queuedReports: [QueuedReport] = []
    /// The uploader's "do not send before" window (the server's `Retry-After`, else a
    /// schedule), shared by every report.
    private var uploadPause = UploadPause()
    private var isDrainingUploads: Bool = false
    static let maxQueuedReports: Int = 3
    /// Attempts per report before it is given up (explicitly logged): with the pause schedule
    /// (30 s doubling to 300 s, or the server's own hint) that is well over ten minutes.
    static let maxUploadAttempts: Int = 6

    /// KVO observation token for AVAudioSession.outputVolume.
    private var volumeObservation: NSKeyValueObservation?
    /// `AVAudioSession.routeChangeNotification` observer: a route change is the system
    /// changing the output volume, never the user.
    private var routeChangeObserver: NSObjectProtocol?
    /// Tells real button presses from the system's volume changes (W-BUGREPPHANTOM).
    private var volumeGesture = VolumeGestureDetector()
    private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume

    /// Auto-detection error event buffer per tag.
    private var errorEvents: [String: [(Date, String)]] = [:]
    private let monitoredTags: Set<String> = ["call", "crypto", "audio", "network", "security"]
    private var autoCooldownUntil: Date = .distantPast

    private init() {}

    /// A reporter of its own for unit tests, so they never touch `shared`. Production code
    /// uses `shared` only.
    init(forTesting: Void) {}

    /// Test seam: stands in for `attemptUpload` (no network). nil in production.
    var attemptOverride: (@MainActor (QueuedReport) async -> UploadAttemptOutcome)?

    // MARK: - Configuration

    public func configure(
        getToken: @escaping TokenProvider,
        getServerUrl: @escaping ServerUrlProvider,
        getActiveCallId: @escaping ActiveCallIdProvider,
        getDiagSnapshot: @escaping DiagSnapshotProvider
    ) {
        self.getToken = getToken
        self.getServerUrl = getServerUrl
        self.getActiveCallId = getActiveCallId
        self.getDiagSnapshot = getDiagSnapshot
    }

    // MARK: - Volume Observer

    public func startVolumeObserver() {
        let session = AVAudioSession.sharedInstance()
        lastVolume = session.outputVolume
        volumeObservation = session.observe(
            \.outputVolume,
            options: [.new, .old]
        ) { [weak self] _, change in
            // W-BUGREPPHANTOM: the time of the change is the time it was DELIVERED.
            // Timestamping inside the main-actor hop (as before) squeezed changes that
            // queued up behind a busy main thread (a call teardown) into a "rapid"
            // pair.
            let deliveredAt = ProcessInfo.processInfo.systemUptime
            let newValue = change.newValue
            let oldValue = change.oldValue
            Task { @MainActor [weak self] in
                self?.handleVolumeChange(newValue: newValue, oldValue: oldValue, at: deliveredAt)
            }
        }
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                let deliveredAt = ProcessInfo.processInfo.systemUptime
                Task { @MainActor [weak self] in
                    self?.volumeGesture.noteSystemVolumeChange(at: deliveredAt, reason: .routeChange)
                }
            }
        }
    }

    public func stopVolumeObserver() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    /// A call transition the app itself is making (a call ending, a 1:1 -> group
    /// hand-over, a group call starting or ending) is about to move the audio route, and
    /// with it the output volume: those changes are not volume-button presses.
    public func noteAudioTransition() {
        volumeGesture.noteSystemVolumeChange(at: ProcessInfo.processInfo.systemUptime,
                                             reason: .transition,
                                             period: VolumeGestureDetector.transitionQuietPeriod)
    }

    /// Group calls carry a longer log window (see `AppState.bugReportLogWindowMinutes`).
    public func setLogWindowProvider(_ provider: @escaping LogWindowProvider) {
        getLogWindowMinutes = provider
    }

    private func handleVolumeChange(newValue: Float?, oldValue: Float?, at deliveredAt: TimeInterval) {
        let current = AVAudioSession.sharedInstance().outputVolume
        let new = newValue ?? current
        let old = oldValue ?? lastVolume
        lastVolume = new
        // Accepted gestures (unchanged): A) up-then-down or down-then-up within 400ms,
        // B) two presses in the SAME direction within 600ms (both volume buttons pressed
        // together register as one direction, twice). What changed is what counts as a
        // press: see `VolumeGestureDetector`.
        switch volumeGesture.observe(old: old, new: new, at: deliveredAt) {
        case .pressed:
            return
        case .ignored(let reason):
            // Only the changes that the old detector would have counted as a press of a
            // possible gesture are worth a line; a cool-down is the gesture just fired.
            guard reason != .cooldown else { return }
            RTLog.info("bugreport", "trig src=1 suppressed=1 why=\(reason.rawValue)")
        case .gesture(let deltaMs):
            RTLog.info("bugreport", "trig src=1 delta=\(deltaMs) vol=\(Int((new * 100).rounded()))")
            triggerManual(source: .volumeGesture)
        }
    }

    // MARK: - Auto-detection

    public func onError(tag: String, message: String) {
        guard monitoredTags.contains(tag) else { return }
        let now = Date()
        var events = errorEvents[tag] ?? []
        events.append((now, message))
        // Prune events older than 60s
        let cutoff = now.addingTimeInterval(-60.0)
        events = events.filter { $0.0 > cutoff }
        errorEvents[tag] = events
        guard events.count >= 2 else { return }
        guard now > autoCooldownUntil else { return }
        autoCooldownUntil = now.addingTimeInterval(30.0)
        errorEvents[tag] = []
        triggerAuto(tag: tag)
    }

    // MARK: - Trigger paths

    /// Public entry point for shake gesture (ShakeDetectorView in ContentView).
    /// Same as the private triggerManual() but callable from outside the class.
    public func triggerManualPublic(source: TriggerSource = .shake) {
        if source == .shake { RTLog.info("bugreport", "trig src=\(source.rawValue)") }
        triggerManual(source: source)
    }

    private func triggerManual(source: TriggerSource) {
        // A second gesture while the sheet is up must not replace the report the user
        // is looking at (its screenshot and log tail are the ones being described).
        guard !isShowingOverlay else { return }
        // W-DIAGOVERRIDE (2026-08-13, user's explicit call): diagnostic
        // capture must work in EVERY situation, even while
        // ScreenshotLockService's secure UITextField sentinel is installed
        // on the key window. That sentinel is the standard iOS "FLAG_SECURE
        // equivalent" trick (see ScreenshotLockService's own kdoc) — it
        // doesn't just block the OS screenshot gesture, it blanks ANY
        // in-process render of that window, including this class's own
        // `captureScreen()` → `window.layer.render(in:)`. That's why the
        // shake/volume debug capture stopped producing a usable screenshot
        // on screens reached from a screenshot-locked chat (e.g. the mesh
        // sheet): the lock silently blanked the diagnostic image too.
        // Bypass it for the duration of this ONE capture, then restore
        // immediately — this does not weaken the protection outside the
        // capture instant. Debug-only escape hatch; will be revisited
        // before production per the user's own note that this won't stay
        // permanent.
        // App Store readiness audit 2026-09-12 (FIX-22): the bypass is
        // dev/TestFlight-only. A store build captures without unlocking —
        // a blank image on a screenshot-locked screen is the correct
        // behaviour for a product marketed on screenshot protection.
        let screenshot = captureScreenForReport()
        let logEntries = RuntimeLogSink.shared.recentRawEntries(minutes: currentLogWindowMinutes())
        var report = PendingReport(
            screenshot: screenshot,
            logEntries: logEntries,
            trigger: "manual",
            capturedAt: Date()
        )
        report.source = source.rawValue
        pendingReport = report
        isShowingOverlay = true
    }

    /// The screenshot for a manual report (trigger time and send time), with the
    /// dev/TestFlight-only screenshot-lock bypass described in `triggerManual`.
    private func captureScreenForReport() -> UIImage? {
        #if QAUDION_DEV_TOOLS
        let wasLocked = ScreenshotLockService.isLocked
        if wasLocked { ScreenshotLockService.unlock() }
        let screenshot = captureScreen()
        if wasLocked { ScreenshotLockService.lock() }
        return screenshot
        #else
        return captureScreen()
        #endif
    }

    /// Minutes of log before the trigger (at least the historical 2).
    private func currentLogWindowMinutes() -> Double {
        let requested = getLogWindowMinutes?() ?? Self.defaultLogWindowMinutes
        return max(Self.defaultLogWindowMinutes, min(requested, 10))
    }

    private func triggerAuto(tag: String) {
        // App Store readiness audit 2026-09-12 (FIX-11): the automatic
        // report is diagnostic egress the user never asked for, so it is
        // gated on the same diagnostics opt-in (default OFF) the privacy
        // manifest and both privacy policies describe. The manual shake /
        // volume path stays: it ends in an explicit "Invia report" tap.
        guard TelemetryService.isEnabled else {
            RTLog.info("bugreport", "auto report suppressed (diagnostics opt-in OFF): " + tag)
            return
        }
        let logEntries = RuntimeLogSink.shared.recentRawEntries(minutes: 2.0)
        let report = PendingReport(
            screenshot: nil,
            logEntries: logEntries,
            trigger: "auto",
            capturedAt: Date()
        )
        // Upload silently without showing the overlay sheet.
        Task {
            await uploadReport(report: report, note: "auto-detected: " + tag)
        }
        // Show a non-intrusive snackbar via NotificationCenter so we
        // don't need to import the snackbar type here.
        NotificationCenter.default.post(
            name: BugReporter.autoReportNotification,
            object: nil,
            userInfo: ["tag": tag]
        )
    }

    /// Posted when an automatic (silent) bug report is triggered.
    public static let autoReportNotification = Notification.Name("qaudion.bugreport.auto")

    // MARK: - Abuse report (App Store 1.2 / Play UGC)

    /// User-initiated report of another user, message or group — the
    /// "Segnala" that must sit next to "Blocca". Reuses the E2EE report
    /// pipeline (`trigger=abuse`, server `reports.TriggerAbuse`): the
    /// category, note and reported ids travel in the encrypted body, the
    /// reported ids ALSO travel as plaintext form fields so triage can
    /// route without decrypting. No log tail, no screenshot, no consent
    /// gate — the user is explicitly asking for this to be sent.
    public func reportAbuse(reportedUserId: String?,
                            reportedGroupId: String?,
                            reportedName: String,
                            category: String,
                            note: String) {
        var fields: [String: String] = ["report_category": category]
        if let u = reportedUserId, !u.isEmpty { fields["reported_user_id"] = u }
        if let g = reportedGroupId, !g.isEmpty { fields["reported_group_id"] = g }
        var report = PendingReport(screenshot: nil, logEntries: [], trigger: "abuse", capturedAt: Date())
        report.extraFields = fields
        var lines: [String] = ["ABUSE REPORT", "category=" + category]
        if let u = reportedUserId, !u.isEmpty { lines.append("reported_user_id=" + u) }
        if let g = reportedGroupId, !g.isEmpty { lines.append("reported_group_id=" + g) }
        lines.append("reported_name=" + reportedName)
        if !note.isEmpty { lines.append("note=" + note) }
        let body = lines.joined(separator: "\n")
        Task {
            await uploadReport(report: report, note: body)
        }
    }

    // MARK: - Send (called by overlay UI)

    public func send(note: String) {
        guard let report = pendingReport else { return }
        isShowingOverlay = false
        pendingReport = nil
        let capturedNote = note
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // Re-sample at SEND time: the sheet can stay up for many seconds and what
            // the user wants to report may have happened (or still be on screen) after
            // the trigger. Wait for the sheet to slide away so the second picture shows
            // the app, not the card.
            try? await Task.sleep(nanoseconds: 700_000_000)
            let resampled = self.resampledAtSend(report)
            RTLog.info("bugreport", "report send age=\(resampled.sendDelayMs) min=\(Int(resampled.logWindowMinutes.rounded(.up))) count=\(resampled.screenshotCount)")
            await self.uploadReport(report: resampled, note: capturedNote)
        }
    }

    /// The trigger-time report with the send-time screenshot next to the trigger-time
    /// one, and the log from `logWindowMinutes` before the trigger up to now.
    private func resampledAtSend(_ report: PendingReport) -> PendingReport {
        var out = report
        let sinceTrigger = max(0, Date().timeIntervalSince(report.capturedAt))
        let windowMinutes = currentLogWindowMinutes() + sinceTrigger / 60
        let logEntries = RuntimeLogSink.shared.recentRawEntries(minutes: windowMinutes)
        if !logEntries.isEmpty { out.logEntries = logEntries }
        let sendShot = captureScreenForReport()
        out.screenshot = Self.sideBySide(report.screenshot, sendShot)
        out.screenshotCount = (report.screenshot == nil ? 0 : 1) + (sendShot == nil ? 0 : 1)
        out.sendDelayMs = Int((sinceTrigger * 1000).rounded())
        out.logWindowMinutes = windowMinutes
        return out
    }

    /// Two screenshots in one image (left: trigger time, right: send time); either one
    /// alone when the other is missing.
    private static func sideBySide(_ left: UIImage?, _ right: UIImage?) -> UIImage? {
        guard let left = left else { return right }
        guard let right = right else { return left }
        let gap: CGFloat = 12
        let size = CGSize(width: left.size.width + gap + right.size.width,
                          height: max(left.size.height, right.size.height))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = min(left.scale, right.scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            left.draw(in: CGRect(origin: .zero, size: left.size))
            right.draw(in: CGRect(origin: CGPoint(x: left.size.width + gap, y: 0), size: right.size))
        }
    }

    public func dismiss() {
        isShowingOverlay = false
        pendingReport = nil
    }

    // MARK: - Upload

    /// W561 — fetch the admin X25519 pubkey (lazy, cached for the process
    /// lifetime). Mirrors Android's `BugReporter.fetchAdminPubKey`. Returns
    /// nil on any failure — the caller aborts rather than falling back to
    /// plaintext (this is the fix for the exact gap that used to exist:
    /// this class previously had NO E2EE path at all, always plaintext, to
    /// the legacy `/api/v1/bugreport` endpoint).
    private func fetchAdminPubKey(serverUrl: String, token: String) async -> AdminPubKeyResult {
        if let cached = cachedAdminPubKeyHex { return .key(cached) }
        guard let url = URL(string: serverUrl + "/api/v1/report-pubkey") else { return .failed }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        // W-AUXPIN: keep the 60 s idle timeout this request always had under
        // URLSession.shared — the pinned session's configuration carries the
        // REST client's 15 s (IOS-E2), and a per-request value takes
        // precedence over it. Behaviour-preserving, not a tuning change.
        request.timeoutInterval = 60
        do {
            // W-AUXPIN (2026-09-01): cert-pinned session (same delegate/pins
            // as the REST client) instead of URLSession.shared — this
            // bearer-token GET had no pin at all (audit memory
            // reference_ios_stability_audit_2026_09_01, P1 item 6).
            let (data, response) = try await PinnedURLSession.auxiliary(for: serverUrl).data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let http = response as? HTTPURLResponse
                RTLog.warn("bugreport", "report-pubkey fetch failed")
                // W-RETRYAFTER: a throttle, a 5xx or an auth hiccup is worth another try later;
                // only a status that condemns the request is final.
                if UploadRetryPolicy.verdict(status: http?.statusCode) == .keep {
                    return .retry(status: http?.statusCode,
                                  retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
                }
                return .failed
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hex = obj["public_key"] as? String, !hex.isEmpty else {
                RTLog.warn("bugreport", "report-pubkey response unparseable")
                return .failed
            }
            cachedAdminPubKeyHex = hex
            return .key(hex)
        } catch {
            RTLog.warn("bugreport", "report-pubkey fetch exception: " + error.localizedDescription)
            return .retry(status: nil, retryAfter: nil)
        }
    }

    /// W-RETRYAFTER -- how the admin-pubkey fetch ended.
    private enum AdminPubKeyResult {
        case key(String)
        /// Worth another try after the pause (`UploadRetryPolicy` says keep).
        case retry(status: Int?, retryAfter: String?)
        case failed
    }

    /// W-RETRYAFTER -- how one upload attempt ended.
    enum UploadAttemptOutcome {
        /// The server took the report.
        case done
        /// Nothing more to try (no token/URL, nothing to assemble, a rejected report).
        case abandon
        /// Keep the report and try again after the pause.
        case retry(status: Int?, retryAfter: String?)
    }

    /// W561 — E2EE upload to `/api/v1/report`, replacing the old plaintext
    /// POST to `/api/v1/bugreport`. Same per-field-ephemeral-key scheme as
    /// Android's `BugReporter.kt.uploadReport` (see `ReportCrypto`'s kdoc):
    /// body/logs/screenshot are each encrypted independently, so a
    /// compromised ephemeral key for one field never exposes another.
    ///
    /// The "body" plaintext folds in BOTH the user's free-text note AND a
    /// structured diagnostic JSON snapshot (call id/state/roster, WS
    /// connection state — see `DiagSnapshotProvider`'s kdoc) so a report is
    /// self-contained evidence of app state at trigger time, not just a
    /// screenshot the reader has to interpret cold.
    ///
    /// W-RETRYAFTER (2026-10-03): this is now the entry point of a small bounded queue, not a
    /// single shot. The report is queued, then the queue is drained one report at a time,
    /// never before the uploader's pause (the server's `Retry-After`) has passed; a failure
    /// that is not the report's fault (429/503/5xx/auth/network) keeps it for another try.
    func uploadReport(report: PendingReport, note: String) async {
        if queuedReports.count >= Self.maxQueuedReports {
            queuedReports.removeFirst()
            RTLog.warn("bugreport", "upload queue full: oldest report dropped cap="
                       + String(Self.maxQueuedReports))
        }
        // The call the report is about and the app's state are read ONCE, here, at trigger/send
        // time (see `QueuedReport`); every retry sends exactly these.
        queuedReports.append(QueuedReport(
            report: report,
            note: note,
            callId: getActiveCallId?() ?? "",
            diagSnapshot: Self.addingReportBlock(to: getDiagSnapshot?() ?? "", report: report)
        ))
        // One drain loop at a time; a report queued while it runs is picked up by it.
        guard !isDrainingUploads else { return }
        isDrainingUploads = true
        defer { isDrainingUploads = false }

        while let next = queuedReports.first {
            if Task.isCancelled { return }
            // The diagnostics opt-in is re-read on EVERY pass, not only when the report was
            // triggered: a kept report is retried minutes later, and an automatic one the user
            // has since opted out of must not leave the phone.
            if Self.isConsentWithdrawn(for: next.report, diagnosticsEnabled: TelemetryService.isEnabled) {
                removeQueuedReport(matching: next)
                RTLog.info("bugreport", "queued auto report dropped: diagnostics opt-in OFF")
                continue
            }
            let now = ProcessInfo.processInfo.systemUptime
            if uploadPause.isPaused(now: now) {
                let wait = uploadPause.remainingSeconds(now: now)
                try? await Task.sleep(nanoseconds: UInt64((wait + 0.05) * 1_000_000_000))
                continue
            }
            let outcome: UploadAttemptOutcome
            if let attemptOverride = attemptOverride {
                outcome = await attemptOverride(next)
            } else {
                outcome = await attemptUpload(queued: next)
            }
            // The queue may have dropped its oldest while that attempt was out: only touch the
            // entry if it is still the one that was tried.
            switch outcome {
            case .done:
                uploadPause.recordSuccess()
                removeQueuedReport(matching: next)
            case .abandon:
                removeQueuedReport(matching: next)
            case .retry(let status, let retryAfter):
                let attempts = next.attempts + 1
                let delay = uploadPause.recordFailure(status: status,
                                                      retryAfterHeader: retryAfter,
                                                      now: ProcessInfo.processInfo.systemUptime,
                                                      wallClock: Date(),
                                                      jitterUnit: Double.random(in: 0...1))
                let statusText = status.map { String($0) } ?? "net"
                let hint = UploadRetryPolicy.parseRetryAfter(retryAfter, now: Date())
                let hintText = UploadRetryPolicy.hintLogSeconds(hint)
                RTLog.warn("bugreport", "upload paused status=" + statusText + " retry_after=" + hintText
                           + " pause=" + String(Int(delay.rounded())) + " queued=" + String(queuedReports.count)
                           + " attempt=" + String(attempts))
                if attempts >= Self.maxUploadAttempts {
                    removeQueuedReport(matching: next)
                    RTLog.warn("bugreport", "report given up after " + String(attempts) + " attempts")
                } else if let index = queuedReports.firstIndex(where: { $0.id == next.id }) {
                    queuedReports[index].attempts = attempts
                }
            }
        }
    }

    private func removeQueuedReport(matching entry: QueuedReport) {
        if let index = queuedReports.firstIndex(where: { $0.id == entry.id }) {
            queuedReports.remove(at: index)
        }
    }

    /// An automatic report is diagnostic egress the user never asked for: it is allowed only
    /// while the diagnostics opt-in is ON (`triggerAuto`). Manual and abuse reports end in an
    /// explicit user action and are never gated. `diagnosticsEnabled` is a parameter so the
    /// rule can be tested without touching the user's real preference.
    static func isConsentWithdrawn(for report: PendingReport, diagnosticsEnabled: Bool) -> Bool {
        return report.trigger == "auto" && !diagnosticsEnabled
    }

    /// The diagnostics opt-in was switched OFF: forget every queued automatic report now, so
    /// none stays in memory through a long pause (the drain loop also re-checks before each
    /// attempt, and `attemptUpload` once more before the POST). Manual and abuse reports
    /// stay: the user asked for those.
    func dropQueuedAutoReports() {
        let before = queuedReports.count
        queuedReports.removeAll { $0.report.trigger == "auto" }
        let dropped = before - queuedReports.count
        if dropped > 0 {
            RTLog.info("bugreport", "queued auto reports dropped: diagnostics opt-in OFF n=" + String(dropped))
        }
    }

    /// What the queue holds, for tests: trigger, the call id and snapshot fixed at queue
    /// time, and the attempts so far.
    var queuedReportsForTesting: [(trigger: String, callId: String, diagSnapshot: String, attempts: Int)] {
        return queuedReports.map { ($0.report.trigger, $0.callId, $0.diagSnapshot, $0.attempts) }
    }

    /// One attempt: pubkey, assemble, POST. Never throws; says what to do with the report.
    /// The call id and the diagnostic snapshot come from the queue entry (fixed when it was
    /// queued), never from the live providers; the token and the server URL are read now.
    private func attemptUpload(queued: QueuedReport) async -> UploadAttemptOutcome {
        let report = queued.report
        let note = queued.note
        guard let getServerUrl = getServerUrl,
              let getToken = getToken else { return .abandon }
        let serverUrl = getServerUrl()
        guard !serverUrl.isEmpty else { return .abandon }
        guard let token = getToken() else { return .abandon }
        guard !token.isEmpty else { return .abandon }

        let adminPubKey: String
        switch await fetchAdminPubKey(serverUrl: serverUrl, token: token) {
        case .key(let hex):
            adminPubKey = hex
        case .retry(let status, let retryAfter):
            RTLog.warn("bugreport", "admin pubkey unavailable — report kept for a later attempt")
            return .retry(status: status, retryAfter: retryAfter)
        case .failed:
            // Admin pubkey unavailable — abort rather than send plaintext.
            RTLog.warn("bugreport", "admin pubkey unavailable — report aborted (no plaintext fallback)")
            return .abandon
        }

        let appVersion = resolveAppVersion()
        let osVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        // FIX-11 (2026-09-12): this used to be `token.prefix(8)` — eight
        // characters of the LIVE bearer token as a plaintext form field.
        // Same convention as LogExportService now: first 8 of the user id.
        let userPrefix = String((TokenVault.loadUserId() ?? "").prefix(8))
        let timestamp = BugReporter.isoFormatter.string(from: report.capturedAt)
        let callId = queued.callId
        let diagSnapshot = queued.diagSnapshot

        let bodyPlaintext: String
        if note.isEmpty {
            bodyPlaintext = diagSnapshot
        } else if diagSnapshot.isEmpty {
            bodyPlaintext = note
        } else {
            bodyPlaintext = note + "\n\n---DIAG---\n" + diagSnapshot
        }

        let endpoint = serverUrl + "/api/v1/report"
        guard let url = URL(string: endpoint) else { return .abandon }

        // W-REPORTFREEZE (2026-10-03): everything heavy -- the log text and its redaction, the
        // diagnostic summary, the PNG encode, the three encryptions, the multipart body -- runs
        // off the main actor, at utility priority so it does not compete with a call's media
        // threads. This method is `@MainActor`; the detached task is not. Run on the main
        // actor it froze the iPhone for ~32 s in the group call of 2026-10-03.
        let input = BugReportAssembler.Input(
            adminPubKeyHex: adminPubKey,
            trigger: report.trigger,
            appVersion: appVersion,
            osVersion: osVersion,
            deviceModel: deviceModel,
            userPrefix: userPrefix,
            timestamp: timestamp,
            callId: callId,
            note: note,
            bodyPlaintext: bodyPlaintext,
            logEntries: report.logEntries,
            extraFields: report.extraFields,
            screenshot: report.screenshot
        )
        let assembledReport = await Task.detached(priority: .utility) {
            BugReportAssembler.assemble(input)
        }.value
        guard let assembled = assembledReport else { return .abandon }

        // The pubkey fetch and the assembly above can take a while: read the opt-in once more,
        // right before the bytes leave the phone.
        if Self.isConsentWithdrawn(for: report, diagnosticsEnabled: TelemetryService.isEnabled) {
            RTLog.info("bugreport", "auto report not sent: diagnostics opt-in OFF")
            return .abandon
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=" + assembled.boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = assembled.body
        // W-AUXPIN: same 60 s idle timeout as before (see fetchAdminPubKey) —
        // this is the multi-MB encrypted upload, the one request here that
        // must not inherit the pinned session's 15 s default.
        request.timeoutInterval = 60

        do {
            // W-AUXPIN (2026-09-01): pinned session, see fetchAdminPubKey.
            let (_, response) = try await PinnedURLSession.auxiliary(for: serverUrl).data(for: request)
            let http = response as? HTTPURLResponse
            if let http {
                RTLog.info("bugreport", "E2EE upload status=" + String(describing: http.statusCode))
            }
            switch UploadRetryPolicy.verdict(status: http?.statusCode) {
            case .success:
                return .done
            case .reject:
                // The server will never take this report (malformed / too large): final.
                RTLog.warn("bugreport", "report rejected by the server, not retried")
                return .abandon
            case .keep:
                return .retry(status: http?.statusCode,
                              retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
            }
        } catch {
            RTLog.warn("bugreport", "upload failed: " + error.localizedDescription)
            return .retry(status: nil, retryAfter: nil)
        }
    }

    /// Adds the report's own facts to the diagnostic JSON snapshot: how the sheet was
    /// opened, how long it stayed up, the log window and how many screenshots the image
    /// holds (a phantom trigger, or a report sent long after what it describes, is then
    /// visible without guessing). Numbers only. A snapshot that is not a JSON object is
    /// left as it is.
    private static func addingReportBlock(to snapshot: String, report: PendingReport) -> String {
        guard report.trigger == "manual",
              let data = snapshot.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return snapshot
        }
        object["report"] = [
            "source": report.source,
            "send_delay_ms": report.sendDelayMs,
            "log_window_min": Int(report.logWindowMinutes.rounded(.up)),
            "screenshots": report.screenshotCount,
        ]
        guard let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: out, encoding: .utf8) else {
            return snapshot
        }
        return json
    }

    // MARK: - Screen capture

    private func captureScreen() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first(where: { $0.isKeyWindow }) else { return nil }
        // W-BLANKCAPTURE (2026-08-13): `window.layer.render(in:)` is the
        // legacy Core Animation offscreen path — it composites the layer
        // tree's raw bitmap, which does NOT reliably include SwiftUI's own
        // rendering backend. Confirmed live via two decrypted reports on
        // 1.0.981: the chat list and the profile/settings screen (both
        // SwiftUI-heavy — List/Form, system materials, environment colors)
        // came back nearly blank/white, structure barely visible, while an
        // earlier UIKit-heavier in-call screen had captured fine — the
        // classic symptom of this exact API gap (extensively documented:
        // layer.render(in:) skips SwiftUI content that isn't backed by a
        // traditional CALayer bitmap). `drawHierarchy(in:afterScreenUpdates:)`
        // drives a real render pass instead, the standard fix, and still
        // respects a ScreenshotLockService secure field the same way the
        // system screenshot gesture does (consistent with the temporary
        // unlock/relock this function's caller already does around it).
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso
    }()

    private func resolveAppVersion() -> String {
        guard let info = Bundle.main.infoDictionary else { return "unknown" }
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        return version
    }
}

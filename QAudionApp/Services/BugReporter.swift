import Foundation
import UIKit
import AVFoundation

/// W559 — Cross-platform bug report service.
///
/// **Triggers:**
///   - Manual: volume up-then-down (or down-then-up) within 400ms → overlay sheet.
///   - Auto: 2+ errors with the same tag in monitored categories within 60s → silent banner.
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
        public let screenshot: UIImage?
        public let logs: String
        public let trigger: String
        public let capturedAt: Date
    }

    // MARK: - Private state

    private var getToken: TokenProvider?
    private var getServerUrl: ServerUrlProvider?
    private var getActiveCallId: ActiveCallIdProvider?
    private var getDiagSnapshot: DiagSnapshotProvider?

    /// W561 — admin X25519 pubkey cache (fetched once, reused for the
    /// process lifetime). Mirrors Android's `cachedAdminPubKey`. No
    /// `@Volatile`/lock needed — this whole class is `@MainActor`.
    private var cachedAdminPubKeyHex: String?

    /// KVO observation token for AVAudioSession.outputVolume.
    private var volumeObservation: NSKeyValueObservation?
    /// Ring buffer of the last two volume change timestamps and directions.
    private struct VolumeEvent { let date: Date; let up: Bool }
    private var volumeEvents: [VolumeEvent] = []
    private var lastVolume: Float = AVAudioSession.sharedInstance().outputVolume
    private var volumeCooldownUntil: Date = .distantPast

    /// Auto-detection error event buffer per tag.
    private var errorEvents: [String: [(Date, String)]] = [:]
    private let monitoredTags: Set<String> = ["call", "crypto", "audio", "network", "security"]
    private var autoCooldownUntil: Date = .distantPast

    private init() {}

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
        ) { [weak self] sess, change in
            Task { @MainActor [weak self] in
                self?.handleVolumeChange(
                    newValue: sess.outputVolume,
                    oldValue: change.oldValue ?? sess.outputVolume
                )
            }
        }
    }

    public func stopVolumeObserver() {
        volumeObservation?.invalidate()
        volumeObservation = nil
    }

    private func handleVolumeChange(newValue: Float, oldValue: Float) {
        let now = Date()
        guard now > volumeCooldownUntil else { return }
        let isUp = newValue > oldValue
        let event = VolumeEvent(date: now, up: isUp)
        volumeEvents.append(event)
        // Keep only last 2 events
        if volumeEvents.count > 2 {
            volumeEvents.removeFirst(volumeEvents.count - 2)
        }
        guard volumeEvents.count == 2 else { return }
        let first = volumeEvents[0]
        let second = volumeEvents[1]
        let delta = second.date.timeIntervalSince(first.date)
        // Accepted gestures:
        //   A) up-then-down or down-then-up within 400ms (original)
        //   B) two rapid presses in the SAME direction within 600ms —
        //      covers the "both volume buttons simultaneously" case: pressing
        //      Vol+ and Vol- at the same instant is registered as a SINGLE
        //      event (one direction), but pressing both within ~300ms produces
        //      two same-direction events in quick succession.
        let isOpposite = (first.up != second.up) && delta <= 0.4
        let isSameRapid = (first.up == second.up) && delta <= 0.6
        let isGesture = isOpposite || isSameRapid
        guard isGesture else { return }
        volumeEvents.removeAll()
        volumeCooldownUntil = now.addingTimeInterval(5.0)
        triggerManual()
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
    public func triggerManualPublic() { triggerManual() }

    private func triggerManual() {
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
        let wasLocked = ScreenshotLockService.isLocked
        if wasLocked { ScreenshotLockService.unlock() }
        let screenshot = captureScreen()
        if wasLocked { ScreenshotLockService.lock() }
        let logs = RuntimeLogSink.shared.recentLogsAsString(minutes: 2.0)
        pendingReport = PendingReport(
            screenshot: screenshot,
            logs: logs,
            trigger: "manual",
            capturedAt: Date()
        )
        isShowingOverlay = true
    }

    private func triggerAuto(tag: String) {
        let logs = RuntimeLogSink.shared.recentLogsAsString(minutes: 2.0)
        let report = PendingReport(
            screenshot: nil,
            logs: logs,
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

    // MARK: - Send (called by overlay UI)

    public func send(note: String) {
        guard let report = pendingReport else { return }
        isShowingOverlay = false
        let capturedReport = report
        let capturedNote = note
        Task {
            await uploadReport(report: capturedReport, note: capturedNote)
        }
        pendingReport = nil
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
    private func fetchAdminPubKey(serverUrl: String, token: String) async -> String? {
        if let cached = cachedAdminPubKeyHex { return cached }
        guard let url = URL(string: serverUrl + "/api/v1/report-pubkey") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                RTLog.warn("bugreport", "report-pubkey fetch failed")
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hex = obj["public_key"] as? String, !hex.isEmpty else {
                RTLog.warn("bugreport", "report-pubkey response unparseable")
                return nil
            }
            cachedAdminPubKeyHex = hex
            return hex
        } catch {
            RTLog.warn("bugreport", "report-pubkey fetch exception: " + error.localizedDescription)
            return nil
        }
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
    private func uploadReport(report: PendingReport, note: String) async {
        guard let getServerUrl = getServerUrl,
              let getToken = getToken else { return }
        let serverUrl = getServerUrl()
        guard !serverUrl.isEmpty else { return }
        guard let token = getToken() else { return }
        guard !token.isEmpty else { return }

        guard let adminPubKey = await fetchAdminPubKey(serverUrl: serverUrl, token: token) else {
            // Admin pubkey unavailable — abort rather than send plaintext.
            RTLog.warn("bugreport", "admin pubkey unavailable — report aborted (no plaintext fallback)")
            return
        }

        let appVersion = resolveAppVersion()
        let osVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        let userPrefix = String(token.prefix(8))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.string(from: report.capturedAt)
        let callId = getActiveCallId?() ?? ""
        let diagSnapshot = getDiagSnapshot?() ?? ""

        let bodyPlaintext: String
        if note.isEmpty {
            bodyPlaintext = diagSnapshot
        } else if diagSnapshot.isEmpty {
            bodyPlaintext = note
        } else {
            bodyPlaintext = note + "\n\n---DIAG---\n" + diagSnapshot
        }

        let diagSummary = ReportCrypto.buildDiagSummary(logs: report.logs, note: note, trigger: report.trigger)

        guard let bodyEnc = try? ReportCrypto.encrypt(
            adminPubKeyHex: adminPubKey, plaintext: Data(bodyPlaintext.utf8)
        ) else {
            RTLog.warn("bugreport", "ReportCrypto.encrypt(body) failed — report aborted")
            return
        }
        guard let logsEnc = try? ReportCrypto.encrypt(
            adminPubKeyHex: adminPubKey, plaintext: Data(report.logs.utf8)
        ) else {
            RTLog.warn("bugreport", "ReportCrypto.encrypt(logs) failed — report aborted")
            return
        }
        let screenshotEnc: ReportCrypto.EncryptedPayload? = report.screenshot
            .flatMap { $0.pngData() }
            .flatMap { try? ReportCrypto.encrypt(adminPubKeyHex: adminPubKey, plaintext: $0) }

        let endpoint = serverUrl + "/api/v1/report"
        guard let url = URL(string: endpoint) else { return }

        let boundary = "BugReportBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")

        var body = Data()
        appendField(&body, boundary: boundary, name: "platform", value: "ios")
        appendField(&body, boundary: boundary, name: "trigger", value: report.trigger)
        appendField(&body, boundary: boundary, name: "app_version", value: appVersion)
        appendField(&body, boundary: boundary, name: "os_version", value: osVersion)
        appendField(&body, boundary: boundary, name: "device_model", value: deviceModel)
        appendField(&body, boundary: boundary, name: "user_id", value: userPrefix)
        appendField(&body, boundary: boundary, name: "timestamp", value: timestamp)
        if !callId.isEmpty {
            appendField(&body, boundary: boundary, name: "call_id", value: callId)
        }
        appendField(&body, boundary: boundary, name: "diag_summary", value: diagSummary)
        appendField(&body, boundary: boundary, name: "ephemeral_pub", value: bodyEnc.ephemeralPubHex)
        appendField(&body, boundary: boundary, name: "logs_ephemeral_pub", value: logsEnc.ephemeralPubHex)
        appendFilePart(&body, boundary: boundary, name: "body_enc",
                       filename: "body.enc", mimeType: "application/octet-stream", data: bodyEnc.ciphertext)
        appendFilePart(&body, boundary: boundary, name: "logs_enc",
                       filename: "logs.enc", mimeType: "application/octet-stream", data: logsEnc.ciphertext)
        if let screenshotEnc = screenshotEnc {
            appendField(&body, boundary: boundary, name: "screenshot_ephemeral_pub",
                        value: screenshotEnc.ephemeralPubHex)
            appendFilePart(&body, boundary: boundary, name: "screenshot_enc",
                           filename: "screenshot.enc", mimeType: "application/octet-stream",
                           data: screenshotEnc.ciphertext)
        }
        let closingBoundary = "--" + boundary + "--\r\n"
        if let closingData = closingBoundary.data(using: .utf8) {
            body.append(closingData)
        }
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                RTLog.info("bugreport", "E2EE upload status=" + String(describing: http.statusCode))
            }
        } catch {
            RTLog.warn("bugreport", "upload failed: " + error.localizedDescription)
        }
    }

    // MARK: - Multipart helpers

    private func appendField(_ body: inout Data, boundary: String, name: String, value: String) {
        var part = "--" + boundary + "\r\n"
        part += "Content-Disposition: form-data; name=\"" + name + "\"\r\n\r\n"
        part += value + "\r\n"
        if let data = part.data(using: .utf8) {
            body.append(data)
        }
    }

    private func appendFilePart(_ body: inout Data, boundary: String,
                                name: String, filename: String,
                                mimeType: String, data: Data) {
        var header = "--" + boundary + "\r\n"
        header += "Content-Disposition: form-data; name=\"" + name
        header += "\"; filename=\"" + filename + "\"\r\n"
        header += "Content-Type: " + mimeType + "\r\n\r\n"
        if let headerData = header.data(using: .utf8) {
            body.append(headerData)
        }
        body.append(data)
        if let tail = "\r\n".data(using: .utf8) {
            body.append(tail)
        }
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

    private func resolveAppVersion() -> String {
        guard let info = Bundle.main.infoDictionary else { return "unknown" }
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        return version
    }
}

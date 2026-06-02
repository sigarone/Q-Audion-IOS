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
        getServerUrl: @escaping ServerUrlProvider
    ) {
        self.getToken = getToken
        self.getServerUrl = getServerUrl
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
        // up-then-down or down-then-up within 400ms
        let isGesture = (first.up != second.up) && delta <= 0.4
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

    private func triggerManual() {
        let screenshot = captureScreen()
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

    private func uploadReport(report: PendingReport, note: String) async {
        guard let getServerUrl = getServerUrl,
              let getToken = getToken else { return }
        let serverUrl = getServerUrl()
        guard !serverUrl.isEmpty else { return }
        guard let token = getToken() else { return }
        guard !token.isEmpty else { return }

        let endpoint = serverUrl + "/api/v1/bugreport"
        guard let url = URL(string: endpoint) else { return }

        let appVersion = resolveAppVersion()
        let osVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        let userPrefix = String(token.prefix(8))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.string(from: report.capturedAt)

        let boundary = "BugReportBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let contentType = "multipart/form-data; boundary=" + boundary
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let authHeader = "Bearer " + token
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        var body = Data()
        appendField(&body, boundary: boundary, name: "platform", value: "ios")
        appendField(&body, boundary: boundary, name: "trigger", value: report.trigger)
        appendField(&body, boundary: boundary, name: "app_version", value: appVersion)
        appendField(&body, boundary: boundary, name: "os_version", value: osVersion)
        appendField(&body, boundary: boundary, name: "device_model", value: deviceModel)
        appendField(&body, boundary: boundary, name: "user_id", value: userPrefix)
        appendField(&body, boundary: boundary, name: "timestamp", value: timestamp)
        if !note.isEmpty {
            appendField(&body, boundary: boundary, name: "note", value: note)
        }
        appendField(&body, boundary: boundary, name: "logs", value: report.logs)
        if let screenshot = report.screenshot,
           let pngData = screenshot.pngData() {
            appendFilePart(&body, boundary: boundary, name: "screenshot",
                           filename: "screenshot.png", mimeType: "image/png", data: pngData)
        }
        let closingBoundary = "--" + boundary + "--\r\n"
        if let closingData = closingBoundary.data(using: .utf8) {
            body.append(closingData)
        }
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                let code = http.statusCode
                let codeStr = String(describing: code)
                let logLine = "[BugReporter] upload status=" + codeStr
                RTLog.info("bugreport", logLine)
            }
        } catch {
            let desc = error.localizedDescription
            RTLog.warn("bugreport", "upload failed: " + desc)
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
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size)
        return renderer.image { _ in
            window.layer.render(in: UIGraphicsGetCurrentContext()!)
        }
    }

    // MARK: - Helpers

    private func resolveAppVersion() -> String {
        guard let info = Bundle.main.infoDictionary else { return "unknown" }
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        return version
    }
}

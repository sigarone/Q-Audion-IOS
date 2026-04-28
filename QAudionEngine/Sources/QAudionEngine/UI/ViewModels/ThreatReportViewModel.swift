import Foundation

public struct ThreatReportViewModel: ViewModelProtocol {

    public enum Severity: String, Sendable, CaseIterable {
        case low, medium, high, critical
    }

    public enum ThreatKind: String, Sendable, CaseIterable {
        case deepfakeDetected      = "deepfake_detected"
        case voiceMismatch         = "voice_mismatch"
        case keyTampering          = "key_tampering"
        case suspiciousNetwork     = "suspicious_network"
        case panicWipeTriggered    = "panic_wipe_triggered"
        case other                 = "other"
    }

    public let threatKind: ThreatKind
    public let severity: Severity
    public let detail: String
    public let detectedAt: Date
    public let sessionId: String?
    public let userTypedDetail: String     // user can add free-form text

    public init(threatKind: ThreatKind, severity: Severity, detail: String,
                detectedAt: Date, sessionId: String?, userTypedDetail: String = "") {
        self.threatKind = threatKind
        self.severity = severity
        self.detail = detail
        self.detectedAt = detectedAt
        self.sessionId = sessionId
        self.userTypedDetail = userTypedDetail
    }

    public static let mock = ThreatReportViewModel(
        threatKind: .deepfakeDetected,
        severity: .high,
        detail: "Confidence index dropped below 30% during 14:23 call session",
        detectedAt: Date(timeIntervalSince1970: 1_745_000_000),
        sessionId: "session-abc-123",
        userTypedDetail: ""
    )
}

import Foundation
import Network

/// What a report says about its log attachment (`report.log_capture` in the encrypted header).
enum ReportLogCapture: String {
    /// The user kept the checkbox on and the report carries log lines.
    case reportConsent = "report_consent"
    /// The user switched the checkbox off: no log line leaves the phone.
    case userDeclined = "user_declined"
    /// The checkbox was on but the ring had nothing for the window.
    case empty = "empty"
    /// A report sent by the automatic path, which only runs while the diagnostics opt-in is on.
    case on = "on"

    static func resolve(attach: Bool, lineCount: Int, automatic: Bool = false) -> ReportLogCapture {
        if !attach { return .userDeclined }
        if lineCount == 0 { return .empty }
        return automatic ? .on : .reportConsent
    }
}

/// The call a report is about: the live one, else the one that ended no more than ten minutes
/// ago. Pure value type, the clock is a parameter.
struct ReportCallMemory {
    static let retention: TimeInterval = 600

    private(set) var lastId: String?
    private(set) var lastSeenAt: Date?

    /// Remembers the live call id (nil / empty = no live call) and returns the id a report
    /// should carry.
    mutating func resolve(live: String?, at now: Date) -> String? {
        if let live, !live.isEmpty {
            lastId = live
            lastSeenAt = now
            return live
        }
        guard let id = lastId, let seen = lastSeenAt,
              now.timeIntervalSince(seen) <= Self.retention else { return nil }
        return id
    }

    mutating func reset() {
        lastId = nil
        lastSeenAt = nil
    }
}

enum ReportLogSupport {

    /// The ring keeps debug lines too; a report carries INFO and above only.
    static func infoAndAbove(_ entries: [LiveLogRawEntry]) -> [LiveLogRawEntry] {
        return entries.filter { $0.level != "debug" }
    }

    /// `{"id":"<uuid>","status":"received"}` -> the id, or nil.
    static func reportId(fromResponse data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.count <= 64 else { return nil }
        return id
    }

    static func id8(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "0" }
        return String(id.prefix(8))
    }

    /// The line that lets a report be found from its call.
    static func sentLine(reportId: String, callId: String?, logLines: Int) -> String {
        return "W-REPORT sent id=\(id8(reportId)) call=\(id8(callId)) logs=\(logLines)"
    }

    /// Hardware identifier ("iPhone15,2"), not the generic "iPhone" of `UIDevice.model`.
    static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return model.isEmpty ? "unknown" : model
    }
}

/// The interface type of the current network path, for the report snapshot. Interface TYPE only,
/// never a network name.
final class ReportNetworkProbe: @unchecked Sendable {
    static let shared = ReportNetworkProbe()

    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var current = "unknown"

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            self?.set(Self.kind(of: path))
        }
        m.start(queue: DispatchQueue(label: "report.network.probe", qos: .utility))
        monitor = m
    }

    var kind: String {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func set(_ value: String) {
        lock.lock()
        current = value
        lock.unlock()
    }

    static func kind(of path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }
}

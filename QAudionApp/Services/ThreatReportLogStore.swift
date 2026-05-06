import Foundation
import QAudionEngine

/// Local UserDefaults-backed log of threat reports the user has submitted.
///
/// Q-Audion's `/security/threat-report` endpoint is a fire-and-forget POST
/// (per W12.A Android-shape contract). The server doesn't yet expose a
/// "list my submitted reports" GET, so without a local log the user has
/// no way to revisit what they reported. This store closes that loop on
/// the App layer alone — no engine / server changes needed.
///
/// Schema is forward-compatible: every field is required for new entries,
/// but `Codable` synthesis tolerates older JSON missing fields if any get
/// added later (Optional types only).
///
/// Concurrency: NOT actor-isolated. UserDefaults is thread-safe per call
/// (Apple guarantees atomic reads/writes), but the read-modify-write inside
/// `append` / `remove` is technically TOCTOU. We tolerate that:
/// 1. all real call sites today run on MainActor (`ThreatReportContainer`
///    + `ThreatReportListView`'s @MainActor model), so concurrent mutation
///    cannot happen in practice;
/// 2. this is a best-effort history log, not a crypto / financial ledger —
///    in the worst case (concurrent appends from two threads) one entry
///    gets dropped; the user simply re-files. No data corruption is
///    possible because UserDefaults atomically replaces the value blob;
/// 3. an earlier draft of this class was `@MainActor` but that broke the
///    `ThreatReportContainer` default-arg pattern (default args are
///    evaluated in nonisolated context, so calling a MainActor init from
///    a default value is an error). Reverting to non-isolated keeps the
///    callers ergonomic without losing safety in our actual usage.
public final class ThreatReportLogStore {

    /// One row in the local log. Mirrors the shape submitted to
    /// `SecurityApi.reportThreat(category:details:severity:)` so playing
    /// the row back into a future server-side history fetch is trivial.
    public struct Entry: Codable, Equatable, Identifiable {
        public let id: UUID
        /// Snake_case raw value of `ThreatReportViewModel.ThreatKind`
        /// (e.g. `"deepfake_detected"`). Stored verbatim to survive future
        /// enum additions/renames without breaking historic rows.
        public let category: String
        /// Lowercase raw value of `ThreatReportViewModel.Severity`.
        public let severity: String
        /// Combined auto-detail + user-typed note, exactly as POSTed.
        public let details: String
        /// Local clock at the moment the user tapped Submit and the
        /// server returned 2xx. Drives the list ordering.
        public let submittedAt: Date
        /// Echo of the call/session id when the report was filed
        /// mid-call (nil when filed from Settings).
        public let sessionId: String?

        public init(id: UUID = UUID(),
                    category: String,
                    severity: String,
                    details: String,
                    submittedAt: Date,
                    sessionId: String?) {
            self.id = id
            self.category = category
            self.severity = severity
            self.details = details
            self.submittedAt = submittedAt
            self.sessionId = sessionId
        }
    }

    private let defaults: UserDefaults
    private let key = "qaudion.threat-report-log"
    /// Cap to keep UserDefaults size bounded. Older rows roll off; the user
    /// rarely needs to scroll past ~100 historical reports anyway.
    private let maxEntries = 200

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// All stored reports, newest first.
    public func load() -> [Entry] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return list
    }

    /// Append a new entry. Older rows beyond `maxEntries` are dropped from
    /// the tail (oldest-first) so the cap holds.
    public func append(_ entry: Entry) {
        var current = load()
        current.insert(entry, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: key)
        }
    }

    /// Delete by id (for "remove this row" gestures).
    public func remove(id: UUID) {
        var current = load()
        current.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: key)
        }
    }

    public func wipeAll() {
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Helpers for ThreatReportViewModel → Entry

public extension ThreatReportLogStore.Entry {
    /// Build a log entry from the same fields the server endpoint receives,
    /// keeping wire shape and storage shape byte-identical.
    static func from(submitted vm: ThreatReportViewModel,
                     submittedAt: Date = Date()) -> ThreatReportLogStore.Entry {
        let details: String = {
            if vm.userTypedDetail.isEmpty {
                return vm.detail
            }
            return vm.detail + "\n\n" + vm.userTypedDetail
        }()
        return ThreatReportLogStore.Entry(
            category: vm.threatKind.rawValue,
            severity: vm.severity.rawValue,
            details: details,
            submittedAt: submittedAt,
            sessionId: vm.sessionId
        )
    }
}

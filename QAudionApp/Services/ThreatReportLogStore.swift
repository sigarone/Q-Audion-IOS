import Foundation
import QAudionEngine
import CryptoKit
import Security

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

    /// SECURITY M-19 — on-disk row. Identical to `Entry` EXCEPT
    /// `detailsCiphertext` holds the base64 AES-256-GCM sealed box of
    /// the user-typed report text instead of plaintext. The public
    /// `Entry` API is unchanged; encryption/decryption happens at the
    /// persistence boundary so callers never see ciphertext. A legacy
    /// `details` field is decoded too so pre-M-19 plaintext rows
    /// still load (and get re-encrypted on the next write).
    private struct StoredRow: Codable {
        let id: UUID
        let category: String
        let severity: String
        let detailsCiphertext: String?
        let details: String?          // legacy plaintext (pre-M-19)
        let submittedAt: Date
        let sessionId: String?
    }

    /// All stored reports, newest first. Ciphertext is decrypted
    /// transparently; rows that fail to decrypt are surfaced with a
    /// placeholder rather than dropped so history stays consistent.
    public func load() -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        if let rows = try? JSONDecoder().decode([StoredRow].self, from: data) {
            return rows.map { row in
                let plain: String = Self.decryptDetails(row)
                return Entry(id: row.id,
                             category: row.category,
                             severity: row.severity,
                             details: plain,
                             submittedAt: row.submittedAt,
                             sessionId: row.sessionId)
            }
        }
        // Fallback: legacy [Entry] blob written before M-19.
        if let legacy = try? JSONDecoder().decode([Entry].self, from: data) {
            return legacy
        }
        return []
    }

    /// Append a new entry. Older rows beyond `maxEntries` are dropped from
    /// the tail (oldest-first) so the cap holds.
    public func append(_ entry: Entry) {
        var current = load()
        current.insert(entry, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        persist(current)
    }

    /// Delete by id (for "remove this row" gestures).
    public func remove(id: UUID) {
        var current = load()
        current.removeAll { $0.id == id }
        persist(current)
    }

    public func wipeAll() {
        defaults.removeObject(forKey: key)
    }

    // MARK: - SECURITY M-19 — encrypted persistence

    /// Re-encode the full list with `details` encrypted, then write.
    private func persist(_ entries: [Entry]) {
        let rows: [StoredRow] = entries.map { e in
            let ct: String? = Self.encryptDetails(e.details)
            return StoredRow(id: e.id,
                             category: e.category,
                             severity: e.severity,
                             detailsCiphertext: ct,
                             details: nil,
                             submittedAt: e.submittedAt,
                             sessionId: e.sessionId)
        }
        if let data = try? JSONEncoder().encode(rows) {
            defaults.set(data, forKey: key)
        }
    }

    /// AES-256-GCM seal → base64. Returns nil only if CryptoKit
    /// itself fails (then the row persists with no readable detail
    /// rather than leaking plaintext).
    private static func encryptDetails(_ plaintext: String) -> String? {
        guard let key = threatLogKey() else { return nil }
        let pt: Data = Data(plaintext.utf8)
        guard let sealed = try? AES.GCM.seal(pt, using: key),
              let combined = sealed.combined else { return nil }
        return combined.base64EncodedString()
    }

    /// Decrypt a stored row. Order: encrypted field first, then any
    /// legacy plaintext, else a clear placeholder.
    private static func decryptDetails(_ row: StoredRow) -> String {
        if let b64 = row.detailsCiphertext,
           let blob = Data(base64Encoded: b64),
           let key = threatLogKey(),
           let box = try? AES.GCM.SealedBox(combined: blob),
           let pt = try? AES.GCM.open(box, using: key),
           let s = String(data: pt, encoding: .utf8) {
            return s
        }
        if let legacy = row.details { return legacy }
        return "(unreadable — encrypted with a key no longer available)"
    }

    /// Fetch (or lazily create) the 32-byte AES key from the
    /// Keychain. Service `com.qaudion.threatlog`,
    /// AfterFirstUnlockThisDeviceOnly so background list refreshes
    /// work but the key never leaves the device / iCloud backup.
    private static let keychainService = "com.qaudion.threatlog"
    private static let keychainAccount = "details-aes-256"

    private static func threatLogKey() -> SymmetricKey? {
        if let existing = keychainLoad() {
            return SymmetricKey(data: existing)
        }
        var raw = Data(count: 32)
        let ok: Int32 = raw.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard ok == errSecSuccess else { return nil }
        guard keychainStore(raw) else { return nil }
        return SymmetricKey(data: raw)
    }

    private static func keychainLoad() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }

    private static func keychainStore(_ data: Data) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
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

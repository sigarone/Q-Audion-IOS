import Foundation
import GRDB

public struct SecurityEvent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "security_events"

    public enum Kind: String, Codable {
        case reKey = "RE_KEY"
        case threat = "THREAT"
        case deepfake = "DEEPFAKE"
        case sessionStart = "SESSION_START"
    }

    public enum Severity: String, Codable {
        case info = "INFO"
        case warning = "WARNING"
        case critical = "CRITICAL"
    }

    public let id: String
    public let kind: Kind
    public let severity: Severity
    public let timestamp: Date
    public let details: String?
    public let confidenceScore: Double?
    public let peerUserId: String?

    public init(id: String = UUID().uuidString,
                kind: Kind,
                severity: Severity,
                timestamp: Date = Date(),
                details: String? = nil,
                confidenceScore: Double? = nil,
                peerUserId: String? = nil) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.timestamp = timestamp
        self.details = details
        self.confidenceScore = confidenceScore
        self.peerUserId = peerUserId
    }
}

public final class SecurityEventStore {
    private let db: QAudionDatabase

    public init(db: QAudionDatabase = .shared) {
        self.db = db
    }

    public func logEvent(_ event: SecurityEvent) {
        // SECURITY M-18 — never persist the full peer user id in the
        // local SQLite security log. Truncate to the first 8 chars
        // (the codebase-wide `prefix(8)` identifier convention) so a
        // device compromise can't recover the complete peer identity
        // from deepfake / threat history rows. Schema unchanged.
        let sanitized: SecurityEvent
        if let pid = event.peerUserId {
            let shortPid: String = String(pid.prefix(8))
            sanitized = SecurityEvent(
                id: event.id,
                kind: event.kind,
                severity: event.severity,
                timestamp: event.timestamp,
                details: event.details,
                confidenceScore: event.confidenceScore,
                peerUserId: shortPid)
        } else {
            sanitized = event
        }
        do {
            try db.writer.write { db in
                try sanitized.save(db)
            }
        } catch {
            print("[SecurityEventStore] logEvent failed: \(error)")
        }
    }

    public func loadRecentEvents(limit: Int = 50) -> [SecurityEvent] {
        do {
            return try db.reader.read { db in
                try SecurityEvent.order(Column("timestamp").desc).limit(limit).fetchAll(db)
            }
        } catch {
            print("[SecurityEventStore] loadRecentEvents failed: \(error)")
            return []
        }
    }

    public func clearAll() {
        do {
            _ = try db.writer.write { db in
                try SecurityEvent.deleteAll(db)
            }
        } catch {
            print("[SecurityEventStore] clearAll failed: \(error)")
        }
    }
}

import Foundation
import GRDB

/// Hardened SQLite database for Q-Audion iOS.
///
/// Implements at-rest encryption via SQLCipher and forensic hardening
/// (secure_delete, auto_vacuum) to match the Android security posture.
public final class QAudionDatabase {
    
    public static let shared = QAudionDatabase()
    
    private let dbQueue: DatabaseQueue
    private let keyStore = QAudionKeyStore()
    private static let dbPassphraseKey = "qaudion.db.passphrase.v1"
    
    private init() {
        do {
            let dbURL = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("qaudion.sqlite")
            
            // 1. Resolve or mint the 32-byte encryption key
            let passphrase = try QAudionDatabase.resolvePassphrase(keyStore: keyStore)
            
            // 2. Configure GRDB with SQLCipher
            var config = Configuration()
            config.prepareDatabase { db in
                // Anti-Forensic Hardening:
                // secure_delete = ON ensures deleted data is zeroed out immediately.
                // auto_vacuum = FULL ensures empty pages are removed from the file.
                try db.execute(sql: "PRAGMA secure_delete = ON")
                try db.execute(sql: "PRAGMA auto_vacuum = FULL")
            }
            
            // 3. Set the encryption key (raw 32-byte key as SQLCipher hex blob x'...')
            let hexKey = "x'" + passphrase.map { String(format: "%02x", $0) }.joined() + "'"
            config.passphrase = hexKey
            
            self.dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
            
            // 4. Run migrations
            try migrator.migrate(dbQueue)
            
        } catch {
            fatalError("Failed to initialize secure database: \(error)")
        }
    }
    
    private static func resolvePassphrase(keyStore: QAudionKeyStore) throws -> Data {
        if let existing = keyStore.loadKey(identifier: dbPassphraseKey) {
            return existing
        }
        // Mint a fresh 32-byte raw key
        var key = Data(count: 32)
        let result = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard result == errSecSuccess else {
            throw NSError(domain: "QAudionDatabase", code: -1, userInfo: [NSLocalizedDescriptionKey: "PRNG failure"])
        }
        try keyStore.storeKey(identifier: dbPassphraseKey, keyData: key)
        return key
    }
    
    // MARK: - Migrations
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("v1-initial-schema") { db in
            try db.create(table: "conversations") { t in
                t.column("id", .text).primaryKey()
                t.column("peerUserId", .text)
                t.column("peerDisplayName", .text).notNull()
                t.column("lastMessagePreview", .text).notNull()
                t.column("lastActivity", .datetime).notNull()
                t.column("unreadCount", .integer).notNull().defaults(to: 0)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("kind", .text).notNull()
                t.column("muted", .boolean).notNull().defaults(to: false)
            }
            
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("conversationId", .text).notNull().references("conversations", onDelete: .cascade)
                t.column("direction", .text).notNull()
                t.column("plaintext", .text).notNull()
                t.column("sentAt", .datetime).notNull()
                t.column("deliveredAt", .datetime)
                t.column("readAt", .datetime)
                t.column("status", .text).notNull()
                t.column("senderUserId", .text)
                t.column("serverMessageId", .text)
                t.column("mediaLocalPath", .text)
                t.column("mediaDurationMs", .integer)
                t.column("mediaMimeType", .text)
                t.column("clientMsgId", .text)
                t.column("edited", .boolean)
                t.column("deletedAt", .datetime)
                t.column("reactionsJson", .text) // Map encoded as JSON
                
                t.indexed(on: "conversationId")
                t.indexed(on: "sentAt")
            }
            
            try db.create(table: "security_events") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull() // RE_KEY, THREAT, DEEPFAKE, SESSION_START
                t.column("severity", .text).notNull() // INFO, WARNING, CRITICAL
                t.column("timestamp", .datetime).notNull()
                t.column("details", .text)
                t.column("confidenceScore", .double)
                t.column("peerUserId", .text)
                
                t.indexed(on: "timestamp")
            }
        }
        
        return migrator
    }
    
    // MARK: - Access
    
    public var reader: DatabaseReader { dbQueue }
    public var writer: DatabaseWriter { dbQueue }
}

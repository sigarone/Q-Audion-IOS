import Foundation
import QAudionEngine

/// Coordinates backup encryption / decryption for the Settings → Backup screen.
///
/// Uses BackupContainer (W12.B) with QAUD container format (Android parity):
///   scrypt(N=2^17, r=8, p=1) key derivation + AES-256-GCM AEAD.
/// Local-file based for now; server upload via /backup/upload is Phase 2 work
/// (multipart transport not yet wired per audit §3.6).
@MainActor
final class BackupCoordinator: ObservableObject {

    // MARK: - Errors

    enum Error: Swift.Error, LocalizedError {
        case emptyPassword
        case fileWriteFailed(String)
        case fileReadFailed(String)
        case invalidContainer
        case decryptFailed(String)
        case unsupportedVersion(UInt8)

        var errorDescription: String? {
            switch self {
            case .emptyPassword:
                return "Password cannot be empty"
            case .fileWriteFailed(let m):
                return "Backup write failed: \(m)"
            case .fileReadFailed(let m):
                return "Backup read failed: \(m)"
            case .invalidContainer:
                return "Backup file is not a valid Q-Audion backup"
            case .decryptFailed(let m):
                return "Decrypt failed (wrong password?): \(m)"
            case .unsupportedVersion(let v):
                return "Backup version \(v) not supported"
            }
        }
    }

    // MARK: - Payload schema

    /// JSON payload written inside the QAUD container.
    /// Forward-compatible — unknown fields are tolerated on decode.
    struct BackupPayload: Codable {
        let version: Int
        let createdAt: Date
        let conversations: [Conversation]
        let messages: [Message]
        let contacts: [ContactsStore.StoredContact]
        // Settings (UserDefaults) NOT included — OS handles those independently.
    }

    // MARK: - Constants

    static let backupFilename = "qaudion-backup.qabk"

    // MARK: - Dependencies

    let conversationStore: ConversationStore
    let contactsStore: ContactsStore

    // MARK: - Published state

    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?
    @Published var lastBackupUrl: URL?
    @Published var lastBackupAt: Date?
    @Published var lastBackupSizeBytes: Int64?

    // MARK: - Init

    init(
        conversationStore: ConversationStore = ConversationStore(),
        contactsStore: ContactsStore = ContactsStore()
    ) {
        self.conversationStore = conversationStore
        self.contactsStore = contactsStore
    }

    // MARK: - Backup

    /// Collect state, encrypt with QAUD container, write to Documents/qaudion-backup.qabk.
    /// Returns the file URL on success; throws on any failure.
    @discardableResult
    func backupNow(password: String) async throws -> URL {
        guard !password.isEmpty else { throw Error.emptyPassword }

        isProcessing = true
        defer { isProcessing = false }

        // Gather data from local stores.
        let conversations = conversationStore.loadConversations()
        var allMessages: [Message] = []
        for c in conversations {
            allMessages.append(contentsOf: conversationStore.loadMessages(conversationId: c.id))
        }
        let contacts = contactsStore.load()

        let payload = BackupPayload(
            version: 1,
            createdAt: Date(),
            conversations: conversations,
            messages: allMessages,
            contacts: contacts
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let plaintextData: Data
        do {
            plaintextData = try encoder.encode(payload)
        } catch {
            throw Error.fileWriteFailed("JSON encode: \(error)")
        }

        // Encrypt via BackupContainer (QAUD magic + scrypt N=2^17 + AES-256-GCM).
        // BackupContainer.seal(plaintext:password:) is the W12.B entry point.
        let containerBytes: Data
        do {
            containerBytes = try BackupContainer.seal(plaintext: plaintextData, password: password)
        } catch {
            throw Error.fileWriteFailed("BackupContainer.seal: \(error)")
        }

        // Write to Documents with complete file protection.
        let fm = FileManager.default
        let docs = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = docs.appendingPathComponent(BackupCoordinator.backupFilename)
        do {
            try containerBytes.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw Error.fileWriteFailed("write to disk: \(error)")
        }

        // Update published state so the UI refreshes.
        lastBackupUrl = url
        lastBackupAt = Date()
        lastBackupSizeBytes = Int64(containerBytes.count)

        return url
    }

    // MARK: - Restore

    /// Decrypt a backup and replay state into local stores.
    /// Uses Documents/qaudion-backup.qabk by default; pass `from:` to override.
    @discardableResult
    func restore(password: String, from url: URL? = nil) async throws -> BackupPayload {
        guard !password.isEmpty else { throw Error.emptyPassword }

        isProcessing = true
        defer { isProcessing = false }

        let fm = FileManager.default
        let resolved: URL
        if let u = url {
            resolved = u
        } else {
            let docs = try fm.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            resolved = docs.appendingPathComponent(BackupCoordinator.backupFilename)
        }

        guard fm.fileExists(atPath: resolved.path) else {
            throw Error.fileReadFailed("\(resolved.lastPathComponent) not found")
        }

        let containerBytes: Data
        do {
            containerBytes = try Data(contentsOf: resolved)
        } catch {
            throw Error.fileReadFailed("read from disk: \(error)")
        }

        // Decrypt via BackupContainer.open(_:password:).
        let plaintextData: Data
        do {
            plaintextData = try BackupContainer.open(containerBytes, password: password)
        } catch {
            throw Error.decryptFailed(String(describing: error))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let payload: BackupPayload
        do {
            payload = try decoder.decode(BackupPayload.self, from: plaintextData)
        } catch {
            throw Error.invalidContainer
        }

        // Replay into local stores.
        for c in payload.conversations {
            conversationStore.upsertConversation(c)
        }
        for m in payload.messages {
            conversationStore.appendMessage(m)
        }
        for ct in payload.contacts {
            contactsStore.upsert(ct)
        }

        return payload
    }

    // MARK: - Helpers

    /// True if a local backup file exists in the Documents directory.
    var localBackupExists: Bool {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return false }
        let url = docs.appendingPathComponent(BackupCoordinator.backupFilename)
        return FileManager.default.fileExists(atPath: url.path)
    }
}

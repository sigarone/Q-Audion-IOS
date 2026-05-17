import Foundation
import CryptoKit
import Security

// MARK: - CallRecord

/// A single persisted call record. Codable for encrypted file storage.
/// Sendable-safe: all stored properties are value types.
public struct CallRecord: Codable, Identifiable, Sendable {
    public let id: String               // UUID string minted at beginCall
    public let peerUserId: String
    public let peerDisplayName: String  // resolved at record time from ContactsStore / wire
    public let direction: Direction
    public let startedAt: Date
    public var endedAt: Date?           // nil while call is ongoing
    public let isVideo: Bool
    public let peerExtension: Int?      // PBX short number if known

    public enum Direction: String, Codable, Sendable {
        case incoming, outgoing, missed
    }

    /// Positive call duration in whole seconds. nil for missed or still-ongoing calls.
    public var durationSeconds: Int? {
        guard let e = endedAt else { return nil }
        let d = Int(e.timeIntervalSince(startedAt))
        return d > 0 ? d : nil
    }
}

// MARK: - Keychain helpers (file-private, synchronous)

private enum CallHistoryKeychain {
    private static let service = "com.qaudion.callhistory"
    private static let account = "aes-key"

    /// Load the AES-256 key from Keychain, or generate + store a new one.
    static func loadOrCreateKey() -> SymmetricKey {
        if let existing = loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        storeKey(key)
        return key
    }

    private static func loadKey() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func storeKey(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        let attrs: [CFString: Any] = [
            kSecClass:                   kSecClassGenericPassword,
            kSecAttrService:             service,
            kSecAttrAccount:             account,
            kSecAttrAccessible:          kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData:               keyData
        ]
        // Delete any stale entry first, then add.
        SecItemDelete(attrs as CFDictionary)
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

// MARK: - PersistentCallRecordStore

/// AES-GCM encrypted file-backed store for call history records.
///
/// Storage layout:
///   - Encrypted file: Application Support/qaudion/call_history.enc
///   - File protection: .completeUnlessOpen
///   - Encryption: CryptoKit AES.GCM (256-bit key)
///   - Key storage: iOS Keychain, accessibility .whenUnlockedThisDeviceOnly
///
/// CONSTRAINT (CLAUDE.md §16): this class MUST NOT take AppState as a
/// parameter anywhere. All integration points must pass primitive values
/// (String, Bool, Int) or closures.
@MainActor
public final class PersistentCallRecordStore: ObservableObject {
    public static let shared = PersistentCallRecordStore()

    @Published public private(set) var records: [CallRecord] = []

    // Legacy UserDefaults key — used only during one-time migration.
    private static let legacyStorageKey = "qaudion.callHistory.v2"
    private static let maxRecords = 200

    public init() {
        load()
    }

    // MARK: - Encrypted file URL

    private static var encryptedFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("qaudion", isDirectory: true)
        // Create directory if needed; ignore errors (idempotent).
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: nil
        )
        return dir.appendingPathComponent("call_history.enc")
    }

    // MARK: - Private persistence

    private func load() {
        migrateFromUserDefaultsIfNeeded()
        let key = CallHistoryKeychain.loadOrCreateKey()
        let url = Self.encryptedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let combined = try? Data(contentsOf: url) else {
            print("[CallHistory] warn: could not read encrypted file")
            return
        }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            records = (try? JSONDecoder().decode([CallRecord].self, from: plaintext)) ?? []
        } catch {
            print("[CallHistory] warn: decryption failed — starting empty")
            records = []
        }
    }

    private func save() {
        let capped = Array(records.prefix(Self.maxRecords))
        records = capped
        guard let plaintext = try? JSONEncoder().encode(capped) else { return }
        let key = CallHistoryKeychain.loadOrCreateKey()
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            let combined = sealedBox.combined!
            let url = Self.encryptedFileURL
            try combined.write(to: url, options: .atomic)
            // Apply file protection so the OS encrypts at rest when device is locked.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: url.path
            )
        } catch {
            print("[CallHistory] warn: failed to save encrypted file")
        }
    }

    // MARK: - Migration from UserDefaults

    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard let legacyData = defaults.data(forKey: Self.legacyStorageKey) else { return }
        let migrated = (try? JSONDecoder().decode([CallRecord].self, from: legacyData)) ?? []
        // Encrypt and write to the new file before clearing UserDefaults.
        let key = CallHistoryKeychain.loadOrCreateKey()
        if let plaintext = try? JSONEncoder().encode(migrated),
           let sealedBox = try? AES.GCM.seal(plaintext, using: key),
           let combined = sealedBox.combined {
            let url = Self.encryptedFileURL
            if (try? combined.write(to: url, options: .atomic)) != nil {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUnlessOpen],
                    ofItemAtPath: url.path
                )
            }
        }
        defaults.removeObject(forKey: Self.legacyStorageKey)
        print("[CallHistory] migrated legacy UserDefaults records to encrypted file")
    }

    // MARK: - Public API

    /// Register a call that is starting. Call from the outgoing or incoming
    /// call setup path. Parameters are all primitives — no AppState reference.
    ///
    /// - Parameters:
    ///   - id: The UUID string that also tracks this call in CallKit / engine.
    ///   - peerUserId: BCrypto userId of the remote peer.
    ///   - peerDisplayName: Human-readable display name resolved at call time.
    ///   - direction: `.incoming`, `.outgoing`, or `.missed`.
    ///   - isVideo: Whether the call was started as a video call.
    ///   - peerExtension: Optional PBX short number if known.
    public func beginCall(
        id: String,
        peerUserId: String,
        peerDisplayName: String,
        direction: CallRecord.Direction,
        isVideo: Bool,
        peerExtension: Int? = nil
    ) {
        // Deduplicate: if the same callId was already registered (e.g.
        // double-tap guard fired too late) just return without inserting a duplicate.
        if records.firstIndex(where: { $0.id == id }) != nil { return }
        let record = CallRecord(
            id: id,
            peerUserId: peerUserId,
            peerDisplayName: peerDisplayName,
            direction: direction,
            startedAt: Date(),
            endedAt: nil,
            isVideo: isVideo,
            peerExtension: peerExtension
        )
        records.insert(record, at: 0)
        save()
    }

    /// Mark a call as ended (sets `endedAt` to now).
    /// Call from `AppState.endCall()`.
    public func endCall(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[idx]
        // Only set endedAt once — idempotent on double endCall.
        guard old.endedAt == nil else { return }
        let updated = CallRecord(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            direction: old.direction,
            startedAt: old.startedAt,
            endedAt: Date(),
            isVideo: old.isVideo,
            peerExtension: old.peerExtension
        )
        records[idx] = updated
        save()
    }

    /// Transition an in-progress record to `.missed` direction.
    /// Call when an incoming call is rejected or times out before being answered.
    public func markMissed(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let old = records[idx]
        let updated = CallRecord(
            id: old.id,
            peerUserId: old.peerUserId,
            peerDisplayName: old.peerDisplayName,
            direction: .missed,
            startedAt: old.startedAt,
            endedAt: Date(),
            isVideo: old.isVideo,
            peerExtension: old.peerExtension
        )
        records[idx] = updated
        save()
    }

    /// Remove a single record by id.
    public func deleteRecord(_ id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    /// Wipe all records.
    public func clearAll() {
        records.removeAll()
        save()
    }

    // MARK: - Display name helper

    /// Resolve a display name for a peer userId using the same priority
    /// as the inbound call_incoming handler in AppState:
    ///   1. `wireDisplay` if non-nil and non-empty (caller_display from wire)
    ///   2. ContactsStore rubrica match
    ///   3. Legacy `user-<name>` prefix strip
    ///   4. UUID truncation to prefix(8)…suffix(4)
    ///   5. Raw userId fallback
    ///
    /// Static so callers don't need an instance reference and the logic
    /// stays unit-testable without touching persistence.
    public static func resolveDisplayName(
        userId: String,
        wireDisplay: String?,
        nameByUserId: [String: String]
    ) -> String {
        // NIM-fix3: sanitise server-supplied wireDisplay — trim whitespace,
        // cap at 100 chars, strip Unicode bidi override codepoints.
        if let wd = wireDisplay, !wd.isEmpty {
            let bidiRange1: ClosedRange<UInt32> = 0x202A...0x202E
            let bidiRange2: ClosedRange<UInt32> = 0x2066...0x2069
            var clean: String = wd.trimmingCharacters(in: .whitespacesAndNewlines)
            clean = clean.unicodeScalars
                .filter { !bidiRange1.contains($0.value) && !bidiRange2.contains($0.value) }
                .reduce(into: "") { $0 += String($1) }
            let capped: String = String(clean.prefix(100))
            if !capped.isEmpty { return capped }
        }
        if let name = nameByUserId[userId], !name.isEmpty { return name }
        if userId.hasPrefix("user-") {
            return String(userId.dropFirst(5)).capitalized
        }
        if userId.count > 12 {
            return String(userId.prefix(8)) + "…" + String(userId.suffix(4))
        }
        return userId
    }
}

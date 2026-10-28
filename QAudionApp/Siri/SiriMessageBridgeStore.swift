import Foundation
import CryptoKit

/// App-Group-shared bridge between `QAudionApp` and `QAudionIntents` for the
/// CarPlay/Siri state-of-the-art plan S2 (Siri messaging via
/// `INSendMessageIntent`/`INSearchForMessagesIntent`).
///
/// SECURITY DESIGN (cryptography-security-expert consultation, 2026-09-06,
/// see `docs/superpowers/plans/2026-09-06-carplay-state-of-the-art.md`):
/// this store deliberately carries NO ratchet/session material and the
/// Intents Extension NEVER advances this app's E2EE send-ratchet. Two
/// strictly single-writer channels, each with exactly one writer and one
/// reader process, so there is no cross-process race on any shared crypto
/// state:
///   - `recentMessages` — written ONLY by the main app (plaintext it has
///     already decrypted through the real ratchet anyway), read-only from
///     the extension. Powers `INSearchForMessagesIntent`. Gated by
///     `SiriMessagingConsent.isEnabled` (default OFF, opt-in Settings
///     toggle) — this is a second, extension-reachable on-disk copy of
///     recent plaintext, a real privacy trade-off, never on by default.
///   - `outbox` — appended ONLY by the extension (it never encrypts
///     anything itself, just queues plaintext + recipient), drained (read +
///     cleared) ONLY by the main app, which remains the sole process that
///     ever touches the real ratchet. Powers `INSendMessageIntent` —
///     Siri's response is "queued", never "sent", because delivery only
///     happens once the main app drains the queue.
///
/// This file is compiled into BOTH targets directly (see `project.yml`'s
/// `QAudionIntents.sources`) rather than shipped from `QAudionEngine` — the
/// extension must not link that product (onnxruntime/GRDB/CLiboqs/COpus/
/// WebRTC), same rationale as `QAudionBroadcastExtension`'s own
/// `LiveKitBroadcast` package comment.
///
/// Storage: the shared App Group container (`FileManager
/// .containerURL(forSecurityApplicationGroupIdentifier:)`), NOT a shared
/// Keychain access group — this project's App Group convention (see
/// `QAudionPacketTunnel`/`QAudionBroadcastExtension` `.entitlements`) has
/// never used a shared Keychain access group, only App Groups, so this
/// follows the established pattern. AES-256-GCM via the exact idiom already
/// shipped in `PersistentCallRecord.swift` (`AES.GCM.seal` /
/// `.combined` / `FileManager.setAttributes` for Data Protection) — chosen
/// `.completeUntilFirstUserAuthentication`, matching `QAudionDatabase`
/// (not `.completeUnlessOpen`, matching `PersistentCallRecord`), because
/// Siri can invoke the extension in the background while the device is
/// locked, the same operating condition the main chat database is built
/// for.
public final class SiriMessageBridgeStore {

    public static let appGroupId = "group.com.bcrypto.qaudion.siri"
    public static let shared = SiriMessageBridgeStore()

    public struct CachedMessage: Codable, Equatable {
        public let peerUserId: String
        public let peerDisplayName: String
        public let text: String
        public let sentAt: Date
        public let isOutgoing: Bool
        /// True for an incoming message the user has not read yet. nil when the writer did not say, which a search
        /// for unread messages treats as "not unread".
        public let isUnread: Bool?

        public init(peerUserId: String, peerDisplayName: String, text: String, sentAt: Date, isOutgoing: Bool,
                    isUnread: Bool? = nil) {
            self.peerUserId = peerUserId
            self.peerDisplayName = peerDisplayName
            self.text = text
            self.sentAt = sentAt
            self.isOutgoing = isOutgoing
            self.isUnread = isUnread
        }
    }

    /// Deliberately carries NO resolved Q-Audion `userId` — the extension
    /// has no `QAudionEngine`/`ContactsStore` access (see this file's own
    /// header), so it can't do that resolution itself. `handle`/
    /// `spokenName` are the raw Siri-provided phone/email + display name;
    /// the main app's drain loop resolves them via `SiriCallResolution`
    /// (QAudionEngine) — the exact same resolver S1 already uses for
    /// `INStartCallIntent` — right before actually sending.
    public struct OutboxMessage: Codable, Equatable {
        public let id: String
        public let handle: String?
        public let spokenName: String
        public let text: String
        public let queuedAt: Date
        /// `INSendMessageIntent.conversationIdentifier`: the peer user id a CarPlay conversation row carries. When it
        /// is set it names the target exactly and the main app uses it instead of matching a name.
        public let conversationIdentifier: String?
        /// `INPerson.customIdentifier` of the recipient: the Q-Audion user id of a person this app donated itself.
        public let customIdentifier: String?

        public init(id: String = UUID().uuidString, handle: String?, spokenName: String,
                    text: String, queuedAt: Date = Date(),
                    conversationIdentifier: String? = nil, customIdentifier: String? = nil) {
            self.id = id
            self.handle = handle
            self.spokenName = spokenName
            self.text = text
            self.queuedAt = queuedAt
            self.conversationIdentifier = conversationIdentifier
            self.customIdentifier = customIdentifier
        }
    }

    /// A request, queued by the extension, to mark the messages of the conversation with `peerUserId` as read, up to
    /// `upToSentAt` (the system sends `INSetMessageAttributeIntent` after it has read messages aloud). Only the main
    /// app applies it.
    public struct ReadMark: Codable, Equatable {
        public let id: String
        public let peerUserId: String
        /// The newest message Siri was given, as the whole seconds of its `sentAt`. The mark covers the messages up to
        /// it and nothing that came after.
        public let upToSentAt: Int
        public let queuedAt: Date

        public init(id: String = UUID().uuidString, peerUserId: String, upToSentAt: Int, queuedAt: Date = Date()) {
            self.id = id
            self.peerUserId = peerUserId
            self.upToSentAt = upToSentAt
            self.queuedAt = queuedAt
        }
    }

    private static let cacheFileName = "siri_recent_messages.v1"
    private static let outboxFileName = "siri_outbox.v1"
    private static let readMarksFileName = "siri_read_marks.v1"
    private static let keyFileName = "siri_bridge.key"
    private static let maxCachedMessages = 300

    private let containerURL: URL?

    public init(appGroupId: String = SiriMessageBridgeStore.appGroupId) {
        self.containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    // MARK: - Recent messages cache (main app writes, extension reads)

    /// Overwrites the whole cache. Call with the most recent messages across
    /// all conversations whenever the main app has fresh plaintext (e.g.
    /// after loading/receiving a message) — capped, oldest dropped. No-op
    /// when `SiriMessagingConsent.isEnabled` is false, so a user who never
    /// opted in never has plaintext written to this second location at all.
    public func replaceRecentMessages(_ messages: [CachedMessage]) {
        guard SiriMessagingConsent.isEnabled else {
            clearFile(named: Self.cacheFileName)
            return
        }
        let capped = Array(messages.suffix(Self.maxCachedMessages))
        write(capped, fileName: Self.cacheFileName)
    }

    /// Read-only. Optionally filtered to one peer. Returns empty when the
    /// user never opted in (the file is simply absent/cleared in that case).
    public func recentMessages(peerUserId: String? = nil, limit: Int = 20) -> [CachedMessage] {
        let all: [CachedMessage] = read(fileName: Self.cacheFileName) ?? []
        let filtered = peerUserId.map { pid in all.filter { $0.peerUserId == pid } } ?? all
        return Array(filtered.suffix(limit))
    }

    // MARK: - Outbox (extension appends, main app drains)

    public func enqueueOutboxMessage(_ message: OutboxMessage) {
        var current: [OutboxMessage] = read(fileName: Self.outboxFileName) ?? []
        current.append(message)
        write(current, fileName: Self.outboxFileName)
        SiriBridgeSignal.post()
    }

    /// Reads and clears the outbox. Only the main app's drain loop calls
    /// this — the extension only ever appends, never drains, so there is no
    /// reader/writer race on this file across the two processes.
    public func drainOutbox() -> [OutboxMessage] {
        let current: [OutboxMessage] = read(fileName: Self.outboxFileName) ?? []
        if !current.isEmpty { clearFile(named: Self.outboxFileName) }
        return current
    }

    // MARK: - Read marks (extension appends, main app drains)

    public func enqueueReadMark(_ mark: ReadMark) {
        var current: [ReadMark] = read(fileName: Self.readMarksFileName) ?? []
        current.append(mark)
        write(current, fileName: Self.readMarksFileName)
        SiriBridgeSignal.post()
    }

    /// Reads and clears the read marks. Only the main app calls this, same single-reader rule as the outbox.
    public func drainReadMarks() -> [ReadMark] {
        let current: [ReadMark] = read(fileName: Self.readMarksFileName) ?? []
        if !current.isEmpty { clearFile(named: Self.readMarksFileName) }
        return current
    }

    // MARK: - Encrypted storage primitives

    private func write<T: Codable>(_ value: T, fileName: String) {
        guard let containerURL, let plaintext = try? JSONEncoder().encode(value),
              let key = encryptionKey() else { return }
        do {
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else { return }
            let url = containerURL.appendingPathComponent(fileName)
            try combined.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        } catch {
            // Best-effort: a dropped cache/outbox write self-heals on the
            // next call (recent messages are re-pushed; a lost outbox entry
            // just means that one Siri-queued message never sends — no
            // crash, no crypto-state corruption).
        }
    }

    private func read<T: Codable>(fileName: String) -> T? {
        guard let containerURL else { return nil }
        let url = containerURL.appendingPathComponent(fileName)
        guard let combined = try? Data(contentsOf: url),
              let key = encryptionKey(),
              let sealedBox = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(sealedBox, using: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: plaintext)
    }

    private func clearFile(named fileName: String) {
        guard let containerURL else { return }
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(fileName))
    }

    /// Reads the shared symmetric key from the App Group container,
    /// generating and persisting one on first use. A first-launch race
    /// between the two processes creating the key simultaneously is
    /// possible but self-healing: whichever write lands last simply makes
    /// the other process's not-yet-flushed cache/outbox entries
    /// undecryptable, so `read` treats them as absent — never a crash, and
    /// this key protects only this feature's own bridge files, never any
    /// ratchet/session material.
    private func encryptionKey() -> SymmetricKey? {
        guard let containerURL else { return nil }
        let keyURL = containerURL.appendingPathComponent(Self.keyFileName)
        if let existing = try? Data(contentsOf: keyURL), existing.count == 32 {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        do {
            try raw.write(to: keyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: keyURL.path)
        } catch {
            return nil
        }
        return key
    }
}

/// The extension posts this after it queues a message or a read mark, so a running app picks the queue up at once
/// instead of at its next foreground. A Darwin notification has no payload: the queue is the data.
public enum SiriBridgeSignal {
    public static let name = "com.bcrypto.qaudion.siri.bridge.changed"

    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Calls `handler` on the main queue each time `SiriBridgeSignal` arrives, from this process or from the extension.
/// Observing stops when the object is released.
public final class SiriBridgeSignalObserver {
    private let handler: () -> Void

    public init(handler: @escaping () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let target = Unmanaged<SiriBridgeSignalObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { target.handler() }
            },
            SiriBridgeSignal.name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(SiriBridgeSignal.name as CFString), nil)
    }
}

/// What the Intents extension needs from the bridge. The extension talks to this, never to the class, so a test can
/// stand in for the App Group container.
public protocol SiriBridgeStoring: AnyObject {
    func enqueueOutboxMessage(_ message: SiriMessageBridgeStore.OutboxMessage)
    func enqueueReadMark(_ mark: SiriMessageBridgeStore.ReadMark)
    func recentMessages(peerUserId: String?, limit: Int) -> [SiriMessageBridgeStore.CachedMessage]
}

extension SiriMessageBridgeStore: SiriBridgeStoring {}

/// Opt-in consent flag for `SiriMessageBridgeStore.recentMessages` (S2).
/// Default OFF — sharing a second, extension-reachable copy of recent
/// message plaintext is a real privacy trade-off, not something to enable
/// silently. Same `UserDefaults`-backed static-flag shape as
/// `CallsGate.callKitFreeMode`. Read from both processes; only the main
/// app's Settings UI ever writes it (the extension has no UI to change it).
public enum SiriMessagingConsent {
    public static let key = "qaudion.siri.messagingConsent"
    public static var isEnabled: Bool {
        UserDefaults(suiteName: SiriMessageBridgeStore.appGroupId)?.bool(forKey: key) ?? false
    }
    public static func setEnabled(_ value: Bool) {
        UserDefaults(suiteName: SiriMessageBridgeStore.appGroupId)?.set(value, forKey: key)
    }
}

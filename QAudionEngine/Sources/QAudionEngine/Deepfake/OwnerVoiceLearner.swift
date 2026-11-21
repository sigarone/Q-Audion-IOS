import Foundation
#if canImport(Security)
import Security
#endif

/// Learns the owner's voice template from the owner's own calls (see `OwnerVoiceLearning` for the rules) and keeps
/// what it needs between calls.
///
/// Two things are stored, both in the Keychain, `ThisDeviceOnly`, never synchronised, never sent anywhere:
///  - the template, in the existing item of `VoiceprintStore` (`VoiceprintStore.deviceOwnerId`), written only when a
///    set of windows passes MIN and agrees with itself;
///  - the learning record: the account the learning belongs to, the embedding format it was made in, the windows
///    kept so far and whether the template is final.
///
/// The record binds the learning to the signed-in account. A Keychain item survives a reinstall, so without it a
/// second account on the same phone would inherit the first one's template and read as a different voice. A template
/// that a record of another account vouches for is removed and the learning starts again for this account: a few
/// calls give a new template, nothing is asked of the person. When there is no record at all (a template made before
/// the record existed) the template is adopted: it is bound to the current account and treated as the starting
/// template.
///
/// A new embedding format (`VoiceprintCodec.formatVersion`) drops the windows of the old one and starts again, the
/// same way a template of an old format already reads as no template.
///
/// Everything is serialised on one lock shared by all instances (the monitor, the announce and Settings each make
/// their own). Reads and writes are Keychain calls: call this from a background queue,
/// never from the audio thread.
public final class OwnerVoiceLearner: @unchecked Sendable {

    /// What a call learns from, before it starts.
    public enum Preparation: Equatable {
        /// Nothing can be learned or trusted now: no signed-in account, or the Keychain cannot be read (a phone not
        /// yet unlocked since the restart). The caller scores with whatever template it already holds and learns
        /// nothing; nothing is written or removed.
        case unavailable
        /// `template` is this account's template (`nil` while there is none); `collect` says whether this call's
        /// windows are still worth keeping (no template yet, or one that is not REFINED yet).
        case ready(template: [Float]?, collect: Bool)
    }

    private let templates: VoiceprintStore
    private let progress: OwnerVoiceProgressBacking
    private static let sharedLock = NSLock()
    /// Bumped, under `sharedLock`, by every `wipe()`/`reset()`. A call remembers the value it started with and hands it
    /// back with its windows (`record(windows:userId:generation:)`), so windows that were collected before a wipe
    /// (logout, account deletion, remote wipe, the Settings reset) are refused afterwards instead of being written back.
    private static nonisolated(unsafe) var generationValue: UInt64 = 0
    private var lock: NSLock { Self.sharedLock }

    /// The current generation (see `generationValue`): read it before `prepare`, when a call starts.
    public var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return Self.generationValue
    }

    /// The learner of the app: the Keychain items described above.
    public convenience init() {
        self.init(templates: VoiceprintStore(), progress: KeychainOwnerVoiceProgress())
    }

    init(templates: VoiceprintStore, progress: OwnerVoiceProgressBacking) {
        self.templates = templates
        self.progress = progress
    }

    // MARK: - Before a call

    /// Settles the template and the learning record of `userId` for a call that is about to start (once per call, on
    /// the first window): see the type's doc for what is kept and what is removed.
    public func prepare(userId: String) -> Preparation {
        guard !userId.isEmpty else { return .unavailable }
        lock.lock(); defer { lock.unlock() }

        let template: [Float]?
        switch templates.lookup(contactId: VoiceprintStore.deviceOwnerId) {
        case .unreadable: return .unavailable
        case .absent: template = nil
        case .present(let t): template = t
        }
        let stored: OwnerVoiceRecord?
        switch readRecord() {
        case .unreadable: return .unavailable
        case .absent: stored = nil
        case .present(let r): stored = r
        }

        if let record = stored, record.userId == userId {
            // This account's record. A record of an older embedding format loses its windows, and a template that is
            // gone (a reset) takes the final mark with it.
            var current = record
            if record.embeddingVersion != VoiceprintCodec.formatVersion {
                current = OwnerVoiceRecord(userId: userId, embeddingVersion: VoiceprintCodec.formatVersion,
                                           refined: false, windows: [])
            } else if template == nil, record.refined {
                current.refined = false
                current.windows = []
            }
            if current != record, !writeRecord(current) { return .unavailable }
            return .ready(template: template, collect: template == nil || !current.refined)
        }

        // No record at all (absent or not decodable) and a template: made before the record existed, so it is adopted
        // for this account as the starting template.
        if stored == nil, template != nil {
            let adopted = OwnerVoiceRecord(userId: userId, embeddingVersion: VoiceprintCodec.formatVersion,
                                           refined: false, windows: [])
            guard writeRecord(adopted) else { return .unavailable }
            return .ready(template: template, collect: true)
        }

        // A record of another account: the template, if there is one, is not this account's. Removed first, the
        // record written after, so a failure in between never leaves a template that a record then adopts.
        if template != nil, !templates.delete(contactId: VoiceprintStore.deviceOwnerId) { return .unavailable }
        let fresh = OwnerVoiceRecord(userId: userId, embeddingVersion: VoiceprintCodec.formatVersion,
                                     refined: false, windows: [])
        guard writeRecord(fresh) else { return .unavailable }
        return .ready(template: nil, collect: true)
    }

    /// Whether this account has a template to announce: `prepare`'s check first, so another account's template is
    /// removed and never counted. Without an account the stored template is reported as it is; when the store cannot
    /// be trusted for a signed-in account the answer is no.
    public func hasTemplate(userId: String) -> Bool {
        if userId.isEmpty { return templates.hasTemplate(contactId: VoiceprintStore.deviceOwnerId) }
        if case .ready(let template, _) = prepare(userId: userId) { return template != nil }
        return false
    }

    /// What Settings shows about the learning of one account.
    public enum Status: Equatable, Sendable {
        /// No window kept yet.
        case notStarted
        /// No template yet. `percent` is capped at 99 (100 would mean there is one); `calls` and `speechSeconds` are
        /// capped at what MIN asks for.
        case learning(percent: Int, calls: Int, speechSeconds: Int)
        /// A template is in use and still improving; `percent` is the progress towards REFINED.
        case active(percent: Int)
        /// The template is final.
        case refined
    }

    /// Where the learning of `userId` stands, or `nil` when it cannot be told (no account, or the Keychain cannot be
    /// read). `prepare` runs first, so another account's template is removed and never shown as this account's.
    /// Keychain reads: call from a background queue.
    public func status(userId: String) -> Status? {
        guard case .ready(let template, _) = prepare(userId: userId) else { return nil }
        lock.lock(); defer { lock.unlock() }
        let record: OwnerVoiceRecord?
        switch readRecord() {
        case .unreadable: return nil
        case .absent: record = nil
        case .present(let r): record = r.userId == userId ? r : nil
        }
        let gate = OwnerVoiceLearning.gateStatus(record?.windows ?? [])
        if template == nil {
            guard gate.windows > 0 else { return .notStarted }
            return .learning(
                percent: min(Int((gate.fraction * 100).rounded(.down)), 99),
                calls: min(gate.distinctCalls, OwnerVoiceLearning.minDistinctCalls),
                speechSeconds: min(gate.netSpeechMs / 1000, OwnerVoiceLearning.minNetSpeechMs / 1000))
        }
        if record?.refined == true { return .refined }
        return .active(percent: Int((OwnerVoiceLearning.maturity(gate) * 100).rounded(.down)))
    }

    // MARK: - After a call

    /// Adds the windows a call kept (once per call, when it ends) and, when they pass MIN and agree, stores the new
    /// template. Returns the stage reached, or `nil` when nothing was recorded or when the fused template was refused
    /// because it is too far from the one in use (the windows are kept in that case).
    ///
    /// A template is always fused from all the retained windows together, never blended into the stored one, so the
    /// medoid trim still means something and the result does not depend on the order of the calls. Once the material
    /// reaches REFINED the template is final: the windows are dropped and the record is marked, so later calls stop
    /// paying for the embeddings and do not start the collection again.
    ///
    /// The stage returned is what reached the Keychain: REFINED only when the final mark was written, MIN only when a
    /// template is stored, and `nil` when nothing of this call was kept (the record could not be written, or a wipe
    /// came in between: pass the `generation` read when the call started and windows of an earlier one are refused).
    @discardableResult
    public func record(
        windows: [OwnerVoiceLearning.Window], userId: String, generation: UInt64? = nil
    ) -> OwnerVoiceLearning.Stage? {
        guard !userId.isEmpty, let first = windows.first else { return nil }
        lock.lock(); defer { lock.unlock() }
        // A wipe or a reset ran since the call started: these windows belong to what was removed.
        if let generation, generation != Self.generationValue { return nil }

        var base = OwnerVoiceRecord(userId: userId, embeddingVersion: VoiceprintCodec.formatVersion,
                                    refined: false, windows: [])
        switch readRecord() {
        case .unreadable: return nil
        case .absent: break
        case .present(let r):
            // Another account's learning is never added to.
            guard r.userId == userId else { return nil }
            if r.embeddingVersion == VoiceprintCodec.formatVersion { base = r }
        }
        let alreadyEnrolled: Bool
        var current: [Float]?
        switch templates.lookup(contactId: VoiceprintStore.deviceOwnerId) {
        case .unreadable: return nil
        case .absent: alreadyEnrolled = false
        case .present(let t): alreadyEnrolled = true; current = t
        }
        if alreadyEnrolled, base.refined { return .refined }
        if !alreadyEnrolled, base.refined {
            // The template is gone (a reset): the final mark goes with it.
            base.refined = false
            base.windows = []
        }

        // One call counts once and up to `maxWindowsPerCall` windows.
        let dim = first.embedding.count
        let known = Set(base.windows.map(\.callId))
        let fresh = Array(windows
            .filter { !known.contains($0.callId) && $0.embedding.count == dim }
            .prefix(OwnerVoiceLearning.maxWindowsPerCall))
        guard !fresh.isEmpty else { return nil }

        let now = fresh.map(\.capturedAtEpochMs).max() ?? 0
        let merged = OwnerVoiceLearning.retained(
            base.windows.filter { $0.embedding.count == dim } + fresh, now: now)
        let status = OwnerVoiceLearning.gateStatus(merged)

        var next = base
        next.windows = merged
        // In the three branches below the final mark is not set in `next`, so no stage above MIN can have reached the
        // Keychain there; and none at all when the record itself could not be written.
        let withoutFinalMark: OwnerVoiceLearning.Stage = {
            let stage = OwnerVoiceLearning.stage(status)
            return stage == .refined ? .min : stage
        }()
        guard status.met, let fusion = OwnerVoiceLearning.fuse(merged) else {
            guard writeRecord(next) else { return nil }
            return current == nil ? .learning : withoutFinalMark
        }
        // A fused template far from the one in use is not trusted to replace it: the windows may include another
        // voice. The current template stays, the windows are kept, and the line says so without a score.
        if let current, (OwnerVoiceLearning.cosine(current, fusion.centroid) + 1) / 2 < OwnerContinuityMonitor.uncertainThreshold {
            if writeRecord(next) {
                print("[OwnerCont] learn_stage=keep")
            }
            return nil
        }
        guard templates.save(contactId: VoiceprintStore.deviceOwnerId, template: fusion.centroid) else {
            // The template could not be stored: keep collecting.
            guard writeRecord(next) else { return nil }
            return current == nil ? .learning : withoutFinalMark
        }
        if !OwnerVoiceLearning.shouldRefine(status) {
            next.refined = true
            next.windows = []
        }
        // The template is stored. When the record is not, the final mark did not reach the Keychain either: the stage
        // is MIN and the learning goes on.
        guard writeRecord(next) else { return .min }
        return OwnerVoiceLearning.stage(status)
    }

    /// What a `wipe()` could not remove.
    public enum Leftover: String, Sendable {
        /// The template of the owner's voice is still in the Keychain, or the Keychain cannot be read to tell.
        case template
        /// The learning record (the windows, the account, the final mark) is still there, or cannot be read to tell.
        case record
    }

    /// Removes everything of the owner's voice that this device keeps: the template and the learning record (the windows
    /// kept so far, the account they belong to and the final mark). Both removals are tried whatever the first one
    /// answers, then each item is checked again (the template by whether the Keychain item exists at all, so an unusable
    /// item that is still there counts), and what is still there or cannot be checked is returned: empty means nothing
    /// is left. Bumps the generation first, in the same critical section, so a call that is running keeps no window of
    /// the account that leaves. The learning then starts again from the next call.
    ///
    /// A template that cannot be removed must not be adopted by the next account: a template without a record is taken as
    /// one made before the record existed. So in that case the record is not deleted but replaced by an empty one that
    /// belongs to no account, and the next `prepare` for any account removes the template first.
    public func wipe() -> [Leftover] {
        lock.lock(); defer { lock.unlock() }
        Self.generationValue &+= 1
        _ = templates.delete(contactId: VoiceprintStore.deviceOwnerId)
        let templateLeft = templates.itemExists(contactId: VoiceprintStore.deviceOwnerId) != false
        var purgeMarker = false
        if templateLeft {
            purgeMarker = writeRecord(OwnerVoiceRecord(
                userId: "", embeddingVersion: VoiceprintCodec.formatVersion, refined: false, windows: []))
        } else {
            _ = progress.delete()
        }
        var left: [Leftover] = []
        if templateLeft { left.append(.template) }
        if !purgeMarker {
            if case .absent = progress.read() {} else { left.append(.record) }
        }
        return left
    }

    /// `wipe()` as a yes or no: `true` when nothing of the owner's voice is left.
    @discardableResult
    public func reset() -> Bool {
        wipe().isEmpty
    }

    // MARK: - Record

    private enum RecordRead {
        case absent
        case present(OwnerVoiceRecord)
        case unreadable
    }

    /// A record in a layout this version does not use reads as absent, like a template does.
    private func readRecord() -> RecordRead {
        switch progress.read() {
        case .unreadable: return .unreadable
        case .absent: return .absent
        case .present(let data):
            guard let record = OwnerVoiceRecordCodec.decode(data) else { return .absent }
            return .present(record)
        }
    }

    private func writeRecord(_ record: OwnerVoiceRecord) -> Bool {
        progress.write(OwnerVoiceRecordCodec.encode(record))
    }
}

// MARK: - Record format

/// What the learner keeps between calls (`OwnerVoiceRecordCodec`).
struct OwnerVoiceRecord: Equatable {
    var userId: String
    /// `VoiceprintCodec.formatVersion` the windows were embedded in.
    var embeddingVersion: UInt32
    /// The template is final: collection has stopped.
    var refined: Bool
    var windows: [OwnerVoiceLearning.Window]
}

/// `magic | format | embedding version | refined | user id | windows`, little endian, every length checked. Anything
/// that does not match exactly decodes to `nil`.
enum OwnerVoiceRecordCodec {
    private static let magic: UInt32 = 0x5251_4F4C // "LOQR"
    private static let format: UInt32 = 1
    private static let maxUserIdBytes = 1024
    private static let maxCallIdBytes = 255
    private static let maxDimension = 4096

    static func encode(_ record: OwnerVoiceRecord) -> Data {
        var out = Data()
        out.put(magic)
        out.put(format)
        out.put(record.embeddingVersion)
        out.append(record.refined ? 1 : 0)
        let user = Data(record.userId.utf8)
        out.put(UInt32(user.count))
        out.append(user)
        out.put(UInt32(record.windows.count))
        for w in record.windows {
            let call = Data(w.callId.utf8)
            out.put(UInt32(call.count))
            out.append(call)
            out.put(UInt64(bitPattern: w.capturedAtEpochMs))
            out.put(UInt32(truncatingIfNeeded: w.netSpeechMs))
            out.put(UInt32(w.embedding.count))
            for f in w.embedding { out.put(f.bitPattern) }
        }
        return out
    }

    static func decode(_ data: Data) -> OwnerVoiceRecord? {
        var r = Reader(data)
        guard r.u32() == magic, r.u32() == format, let version = r.u32(), let flag = r.u8(), flag <= 1,
              let userLen = r.u32(), userLen <= maxUserIdBytes, let user = r.string(Int(userLen)),
              let count = r.u32(), count <= UInt32(OwnerVoiceLearning.maxRetainedWindows) else { return nil }
        var windows: [OwnerVoiceLearning.Window] = []
        var dimension: Int?
        for _ in 0..<Int(count) {
            guard let callLen = r.u32(), callLen >= 1, callLen <= maxCallIdBytes, let call = r.string(Int(callLen)),
                  let at = r.u64(), let speech = r.u32(), let dim = r.u32(), dim >= 1, dim <= maxDimension,
                  dimension == nil || dimension == Int(dim) else { return nil }
            dimension = Int(dim)
            var embedding = [Float](repeating: 0, count: Int(dim))
            for i in 0..<Int(dim) {
                guard let bits = r.u32() else { return nil }
                embedding[i] = Float(bitPattern: bits)
            }
            guard embedding.allSatisfy(\.isFinite) else { return nil }
            windows.append(OwnerVoiceLearning.Window(
                embedding: embedding, callId: call, capturedAtEpochMs: Int64(bitPattern: at),
                netSpeechMs: Int(Int32(bitPattern: speech))))
        }
        guard r.isAtEnd else { return nil }
        return OwnerVoiceRecord(userId: user, embeddingVersion: version, refined: flag == 1, windows: windows)
    }

    private struct Reader {
        private let data: Data
        private var offset: Int
        init(_ data: Data) { self.data = data; self.offset = data.startIndex }
        var isAtEnd: Bool { offset == data.endIndex }

        mutating func u8() -> UInt8? {
            guard offset < data.endIndex else { return nil }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func u32() -> UInt32? {
            guard data.endIndex - offset >= 4 else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[offset + i]) << UInt32(8 * i) }
            offset += 4
            return v
        }
        mutating func u64() -> UInt64? {
            guard data.endIndex - offset >= 8 else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[offset + i]) << UInt64(8 * i) }
            offset += 8
            return v
        }
        mutating func string(_ length: Int) -> String? {
            guard length >= 0, data.endIndex - offset >= length else { return nil }
            defer { offset += length }
            return String(data: data[offset..<(offset + length)], encoding: .utf8)
        }
    }
}

private extension Data {
    mutating func put(_ value: UInt32) {
        for i in 0..<4 { append(UInt8(truncatingIfNeeded: value >> UInt32(8 * i))) }
    }
    mutating func put(_ value: UInt64) {
        for i in 0..<8 { append(UInt8(truncatingIfNeeded: value >> UInt64(8 * i))) }
    }
}

// MARK: - Storage of the record

/// What reading the record can say: the same three answers as `VoiceprintLookup`.
enum OwnerVoiceProgressRead {
    case absent
    case present(Data)
    case unreadable
}

/// Storage of the learning record, so the learner can be tested without the Keychain.
protocol OwnerVoiceProgressBacking: AnyObject {
    func read() -> OwnerVoiceProgressRead
    /// `true` only when the record is really stored.
    func write(_ data: Data) -> Bool
    /// `true` when the record is gone afterwards (it may not have existed).
    func delete() -> Bool
}

/// One Keychain item of its own: not in the service of `VoiceprintStore`, whose clean-up removes everything there that
/// is not the owner's template. `AfterFirstUnlockThisDeviceOnly` like the template (a call can be answered from the
/// lock screen), and no `kSecAttrSynchronizable` anywhere: the windows are embeddings of the owner's voice and never
/// leave this phone.
final class KeychainOwnerVoiceProgress: OwnerVoiceProgressBacking {
    private static let service = "com.bcrypto.qaudion.voiceprint.learning.v1"
    private static let account = "owner"

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> OwnerVoiceProgressRead {
        var query = Self.identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess, let data = item as? Data else { return .unreadable }
        return .present(data)
    }

    func write(_ data: Data) -> Bool {
        let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var add = Self.identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecSuccess { return true }
        guard added == errSecDuplicateItem else { return false }
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: accessible]
        return SecItemUpdate(Self.identity as CFDictionary, update as CFDictionary) == errSecSuccess
    }

    func delete() -> Bool {
        let status = SecItemDelete(Self.identity as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

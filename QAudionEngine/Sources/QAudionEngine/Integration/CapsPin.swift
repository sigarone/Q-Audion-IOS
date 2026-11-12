import Foundation

/// Why a call shows the safety-code warning for a contact device. One reason at this step; the shared table names the text of each.
public enum CapsPinReason: String, CaseIterable, Sendable {
    /// The device pinned with `capsBindV1` presented a round-1 bundle without it.
    case capsBindV1Missing = "capsBindV1_missing"
}

/// The warning of the live call: which call and which missing protections, the signature reason first.
public struct CapsPinWarning: Equatable, Sendable {
    public let callId: String
    public let reasons: [PqWarnReason]

    /// The first reason.
    public var reason: PqWarnReason { reasons.first ?? .capsBindV1Missing }

    public init(callId: String, reasons: [PqWarnReason]) {
        self.callId = callId
        self.reasons = reasons
    }

    /// The same warning with `added` in front when it is not there yet (a rekey round refused later in the call).
    public func adding(_ added: [PqWarnReason]) -> CapsPinWarning {
        var merged = reasons
        for reason in added.reversed() where !merged.contains(reason) { merged.insert(reason, at: 0) }
        return CapsPinWarning(callId: callId, reasons: merged)
    }
}

/// The record kept for one (contact, signer key) pair.
public struct CapsPinRecord: Codable, Equatable, Sendable {
    /// The pinned tags (`capsBindV1` is the only one at this step).
    public var caps: [String]
    /// Reserved for the signature step; kept so the stored shape does not change then.
    public var mldsaKeyId: String?
    public var pqState: String?

    public init(caps: [String] = [], mldsaKeyId: String? = nil, pqState: String? = nil) {
        self.caps = caps
        self.mldsaKeyId = mldsaKeyId
        self.pqState = pqState
    }
}

/// Everything that is persisted: the pin records and the arming flag.
public struct CapsPinState: Codable, Equatable, Sendable {
    public var pins: [String: CapsPinRecord]
    public var pinHoldArmed: Bool

    public init(pins: [String: CapsPinRecord] = [:], pinHoldArmed: Bool = false) {
        self.pins = pins
        self.pinHoldArmed = pinHoldArmed
    }
}

/// The decision rules of the sticky capability pins and their constants.
public enum CapsPinPolicy {
    /// Server flag name. Read and stored, never able to arm a hold while `holdEnabled` is false.
    public static let holdFlagName = "calls.pqc_pin_hold"
    /// A pin anomaly shows the visible warning and never holds media.
    public static let holdEnabled = false
    /// Compiled-in arming of the hold. False in every build.
    public static let armedDefault = false

    public enum Pin: String, Sendable {
        case unpinned
        case ok
        case anomaly
    }

    public struct Decision: Equatable, Sendable {
        public let pin: Pin
        public let hold: Bool
        public let reason: CapsPinReason?
    }

    /// Round-1 decision for the peer's bundle against the record of its verified signer key. `armed` is already gated by
    /// `holdEnabled` (`isArmedForHold`). A `capsWithdrawn` marker naming `capsBindV1` changes nothing here: it is carried under the tag.
    public static func decideRound1(record: CapsPinRecord?, peerHasCapsBind: Bool, armed: Bool) -> Decision {
        guard let record, record.caps.contains(CapsBind.tag) else {
            return Decision(pin: .unpinned, hold: false, reason: nil)
        }
        if peerHasCapsBind { return Decision(pin: .ok, hold: false, reason: nil) }
        return Decision(pin: .anomaly, hold: armed, reason: .capsBindV1Missing)
    }

    /// Whether an anomaly would be held: never, while `holdEnabled` is false, whatever the flag, the ratchet or the compiled default say.
    public static func isArmedForHold(book: CapsPinBook, flagValue: Bool?,
                                      holdEnabled: Bool = CapsPinPolicy.holdEnabled,
                                      compiledArming: Bool = CapsPinPolicy.armedDefault) -> Bool {
        guard holdEnabled else { return false }
        return book.isArmed(compiledDefault: compiledArming) || flagValue == true
    }

    /// `QA-PQLEVEL` words of a judged round: `pin=`, `withdraw=`.
    public static func lineWord(for pin: Pin) -> String {
        pin == .unpinned ? "" : pin.rawValue
    }
}

/// Where the pin state lives. Thread safe.
public protocol CapsPinPersistence: AnyObject, Sendable {
    func snapshot() -> CapsPinState
    func update(_ mutator: (inout CapsPinState) -> Void)
}

/// In memory (tests, and the fallback when nothing is wired).
public final class MemoryCapsPinPersistence: CapsPinPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var state = CapsPinState()

    public init() {}

    public func snapshot() -> CapsPinState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func update(_ mutator: (inout CapsPinState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        mutator(&state)
    }
}

/// Persisted in the app's defaults, which an uninstall removes: a reinstall starts with no record and no arming flag.
public final class UserDefaultsCapsPinPersistence: CapsPinPersistence, @unchecked Sendable {
    public static let defaultKey = "com.qaudion.capsbind.pins.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsCapsPinPersistence.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    private func load() -> CapsPinState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(CapsPinState.self, from: data) else { return CapsPinState() }
        return state
    }

    public func snapshot() -> CapsPinState {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    public func update(_ mutator: (inout CapsPinState) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var state = load()
        mutator(&state)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}

/// The sticky capability pins and the arming flag.
///
/// A record is keyed by `(lowercase peer user id, signer identity key)`: two devices of one contact have two records and a reinstall
/// (new key) starts with none. The records are cleared at explicit sites only (`clearPins`: logout, session expiry, account switch;
/// `clearAll`: a full local or remote wipe, which also clears the arming flag). Nothing about a call ending, a teardown, the app
/// going to the background or the process ending touches them.
public final class CapsPinBook: @unchecked Sendable {
    /// The book of the running app.
    public static let shared = CapsPinBook(persistence: UserDefaultsCapsPinPersistence())

    private let persistence: CapsPinPersistence

    public init(persistence: CapsPinPersistence) {
        self.persistence = persistence
    }

    public static func pinKey(peerUserId: String, signerKey: Data) -> String {
        peerUserId.lowercased() + "|" + signerKey.map { String(format: "%02x", $0) }.joined()
    }

    public func record(peerUserId: String, signerKey: Data) -> CapsPinRecord? {
        persistence.snapshot().pins[Self.pinKey(peerUserId: peerUserId, signerKey: signerKey)]
    }

    public var recordCount: Int { persistence.snapshot().pins.count }

    /// Rule Set: a verified round-1 key confirmation under `ext_1`. Monotonic: setting it again changes nothing.
    public func setCapsBind(peerUserId: String, signerKey: Data) {
        let k = Self.pinKey(peerUserId: peerUserId, signerKey: signerKey)
        persistence.update { state in
            var record = state.pins[k] ?? CapsPinRecord()
            if !record.caps.contains(CapsBind.tag) { record.caps = (record.caps + [CapsBind.tag]).sorted() }
            state.pins[k] = record
        }
    }

    /// Exit 1: the user confirmed the safety code from the warning, so the record drops the tag. A record left with nothing is no record.
    public func dropCapsBind(peerUserId: String, signerKey: Data) {
        let k = Self.pinKey(peerUserId: peerUserId, signerKey: signerKey)
        persistence.update { state in
            guard var record = state.pins[k] else { return }
            record.caps.removeAll { $0 == CapsBind.tag }
            if record.caps.isEmpty && record.mldsaKeyId == nil && record.pqState == nil {
                state.pins.removeValue(forKey: k)
            } else {
                state.pins[k] = record
            }
        }
    }

    /// Replaces the whole record of a key with the result of the pin policy (`HybridSigPolicy`), or deletes it (nil). The policy is the
    /// one place that knows every exit of the record, so what it returns is written as it is.
    public func putRecord(peerUserId: String, signerKey: Data, record: CapsPinRecord?) {
        let k = Self.pinKey(peerUserId: peerUserId, signerKey: signerKey)
        persistence.update { state in
            if let record {
                state.pins[k] = record
            } else {
                state.pins.removeValue(forKey: k)
            }
        }
    }

    /// The identity-change flow replaced `signerKey` for this contact: its record goes.
    public func dropKey(peerUserId: String, signerKey: Data) {
        let k = Self.pinKey(peerUserId: peerUserId, signerKey: signerKey)
        persistence.update { state in
            state.pins.removeValue(forKey: k)
        }
    }

    /// The identity-change flow wrote the pin of this exact (contact, device) entry. Only an overwrite replaces a key: a first-time
    /// device (`.added`, whose lookup may have fallen back to another device's pin), an unchanged pin and a failed write drop
    /// nothing, so one device can never delete the record of another.
    public func noteRepin(_ outcome: PeerIdentityPinStore.RepinOutcome, peerUserId: String, replacedKey: Data?, newKey: Data) {
        guard case .overwritten = outcome, let old = replacedKey, old != newKey else { return }
        dropKey(peerUserId: peerUserId, signerKey: old)
    }

    // MARK: - Arming flag (gates nothing while `CapsPinPolicy.holdEnabled` is false)

    /// The first time the flag is read ON the arming flag is stored; a later OFF, a missing flag or a failed fetch change nothing.
    public func observeFlag(_ value: Bool?) {
        guard value == true else { return }
        persistence.update { state in state.pinHoldArmed = true }
    }

    public func isArmed(compiledDefault: Bool = CapsPinPolicy.armedDefault) -> Bool {
        compiledDefault || persistence.snapshot().pinHoldArmed
    }

    public func applyCompiledArming(_ compiledDefault: Bool = CapsPinPolicy.armedDefault) {
        guard compiledDefault else { return }
        persistence.update { state in state.pinHoldArmed = true }
    }

    // MARK: - Explicit clearing sites

    /// Logout, session expiry, account switch: the records go (account data), the arming flag stays.
    public func clearPins() {
        persistence.update { state in state.pins.removeAll() }
    }

    /// A full local or remote wipe: the records and the arming flag.
    public func clearAll() {
        persistence.update { state in state = CapsPinState() }
    }

    public var isArmedFlagStored: Bool { persistence.snapshot().pinHoldArmed }
}

/// Fixed-word log lines of the decisions, handed to the app's log (`RTLog` in the app). Words and digits only: no id, key or name.
public enum CapsBindLog {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sink: (@Sendable (String) -> Void)?

    public static func setSink(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        sink = handler
        lock.unlock()
    }

    static func line(_ text: String) {
        lock.lock()
        let handler = sink
        lock.unlock()
        handler?(text)
    }
}

/// The per-call facts the integration keeps for the role of the legacy outer layer (a same-account call) and for the log words.
/// Written once at round 1, read by the app when it installs the sealers. The entry of a call that is still live is pinned and never
/// evicted; once the call is released, the oldest released entries fall out beyond the bound.
public enum CapsBindCallRegistry {
    public struct Round1: Equatable, Sendable {
        public let ownTag: Bool
        public let peerTag: Bool
        public let selfIsCaller: Bool
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var order: [String] = []
    private nonisolated(unsafe) static var rounds: [String: Round1] = [:]
    private nonisolated(unsafe) static var pinned: Set<String> = []
    private static let capacity = 16

    public static func noteRound1(callId: String, ownTag: Bool, peerTag: Bool, selfIsCaller: Bool) {
        let key = callId.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if rounds[key] == nil { order.append(key) }
        rounds[key] = Round1(ownTag: ownTag, peerTag: peerTag, selfIsCaller: selfIsCaller)
        pinned.insert(key)
        trim()
    }

    /// The call is over: its entry may now be evicted, oldest first, beyond the bound. It stays readable until then.
    public static func release(callId: String) {
        lock.lock()
        defer { lock.unlock() }
        pinned.remove(callId.lowercased())
        trim()
    }

    /// Caller holds the lock. Only released entries are ever evicted.
    private static func trim() {
        while order.count > capacity {
            guard let index = order.firstIndex(where: { !pinned.contains($0) }) else { return }
            let old = order.remove(at: index)
            rounds.removeValue(forKey: old)
        }
    }

    public static func round1(callId: String) -> Round1? {
        lock.lock()
        defer { lock.unlock() }
        return rounds[callId.lowercased()]
    }

    public static func reset() {
        lock.lock()
        order.removeAll()
        rounds.removeAll()
        pinned.removeAll()
        lock.unlock()
    }

    /// The role of this side for the legacy outer layer of the call: the user-id rule, or, when the two lowercase user ids are equal
    /// (two devices of one account), the table of `CapsBindRole`.
    public static func selfIsRoleA(callId: String, selfUserId: String, peerUserId: String) -> Bool {
        let round = round1(callId: callId)
        let context = round.map {
            CapsBindRole.Context(selfIsCaller: $0.selfIsCaller, ownCapsBind: $0.ownTag, peerCapsBind: $0.peerTag)
        }
        return CapsBindRole.selfIsRoleA(selfUserId: selfUserId, peerUserId: peerUserId, context: context)
    }
}

/// The role of a side of the legacy outer layer, including the tie rule for two devices of one account.
///
/// Role A is the side whose lowercase user id is bytewise smaller or equal. When the lowercase ids are equal both sides took role A
/// and neither opened the other's audio. With `capsBindV1` a tie is decided from the two round-1 bundles, on the pair
/// (own advertises, peer advertises):
///
///     own yes, peer no   -> B         the peer behaves as an older build and takes A
///     own yes, peer yes  -> caller A, callee B
///     own no,  peer yes  -> A         exactly as an older build; the peer takes B
///     own no,  peer no   -> A         as before
///
/// A build that does not advertise the tag never reads the table. Shared vectors: section `roleTie`.
public enum CapsBindRole {
    public struct Context: Equatable, Sendable {
        public let selfIsCaller: Bool
        public let ownCapsBind: Bool
        public let peerCapsBind: Bool

        public init(selfIsCaller: Bool, ownCapsBind: Bool, peerCapsBind: Bool) {
            self.selfIsCaller = selfIsCaller
            self.ownCapsBind = ownCapsBind
            self.peerCapsBind = peerCapsBind
        }
    }

    public static func idsTie(_ selfUserId: String, _ peerUserId: String) -> Bool {
        Array(selfUserId.lowercased().utf8) == Array(peerUserId.lowercased().utf8)
    }

    /// Does this side take role A (sends with a2b, opens with b2a)? `context` absent is "no tag on either side".
    public static func selfIsRoleA(selfUserId: String, peerUserId: String, context: Context?) -> Bool {
        guard idsTie(selfUserId, peerUserId) else { return PqcRtpFrameSealer.selfIsRoleA(selfUserId, peerUserId) }
        guard let context, context.ownCapsBind else { return true }
        if !context.peerCapsBind { return false }
        return context.selfIsCaller
    }
}

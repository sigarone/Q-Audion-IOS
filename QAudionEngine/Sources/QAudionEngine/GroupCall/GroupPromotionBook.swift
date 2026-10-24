import Foundation

// The state a device keeps for the live 1:1 call so that it can judge a promotion token (GROUP_CALLS_V2
// 2.7, Consent and Promotion token): the anchor of the call, the book of tokens received, and the receiver
// that applies steps R1 to R14. Plain value types with injected clocks: nothing here reads a
// clock, a socket or the app. All of it lives in memory for the life of the 1:1 call and is never
// persisted or logged.

// MARK: - Anchor (GROUP_CALLS_V2 2.7, Consent)

/// What this device knows about the key that signed the peer's round-1 handshake bundle of the live
/// 1:1 call. The token is verified under this key and under no other.
///
/// The anchor is DEFINED when round 1 is bound on this device and the verdict on the peer's round-1
/// bundle was authenticated (the signature verified under a key that matched the pin, the
/// server-fetched key or the server-published set). A verdict of any other kind leaves it undefined
/// for the rest of the call, even after a SAS confirmation and even when a call-scoped pin lets
/// later rounds verify. A later round whose bundle is not authenticated, or is signed by another
/// key, poisons it for good.
public struct OneToOneAnchor: Equatable, Sendable {
    public private(set) var signerKey: Data?
    /// `SHA-256(ACCEPT_v6)` of round 1: the same value SAS-INFO and the REVEAL use.
    public private(set) var acceptBinding1: Data?
    /// The identity key that signed THIS device's round-1 bundle.
    public private(set) var ownSignerKey: Data?
    public private(set) var roundOneNoted = false
    public private(set) var authenticated = false
    /// Round 1 is bound on this device: the caller bound the ACCEPT, the callee's REVEAL verified.
    public private(set) var bound = false
    /// The peer's round-1 KCMAC verified.
    public private(set) var kcmacVerified = false
    public private(set) var poisoned = false

    public init() {}

    public var isDefined: Bool {
        return authenticated && bound && signerKey != nil && acceptBinding1 != nil
    }

    /// Round 1 is bound on this device and the binding and this device's own signing key are known:
    /// enough to sign a promotion token (GROUP_CALLS_V2 2.7, Promotion token).
    public var canSign: Bool {
        return bound && acceptBinding1 != nil && ownSignerKey != nil
    }

    /// The first key round of the call arms its confirmation (`bound`: the caller already bound the
    /// ACCEPT it processes; the callee binds later, `noteBound()`). Only the first call counts.
    public mutating func noteRoundOne(sigOk: Bool, signerKey: Data?, acceptBinding: Data?, ownSignerKey: Data?,
                                      bound: Bool) {
        guard !roundOneNoted else { return }
        roundOneNoted = true
        self.bound = bound
        let keyOk = (signerKey?.count == GroupPromotionToken.keyLength)
        let bindingOk = (acceptBinding?.count == GroupPromotionToken.bindingLength)
        // What this device needs to SIGN a token of its own (the binding and its own key) does not depend on
        // how the peer's bundle was judged.
        if bindingOk { self.acceptBinding1 = acceptBinding }
        if ownSignerKey?.count == GroupPromotionToken.keyLength { self.ownSignerKey = ownSignerKey }
        // The peer's key is the anchor to VERIFY a token under: only an authenticated verdict makes it one.
        guard sigOk, keyOk, bindingOk else { return }
        authenticated = true
        self.signerKey = signerKey
    }

    /// The callee's REVEAL verified (R-COMMIT-CHECK): round 1 is bound on this device.
    public mutating func noteBound() {
        guard roundOneNoted else { return }
        bound = true
    }

    /// The peer's KCMAC of `round` verified. Only round 1 counts.
    public mutating func noteKcMacVerified(round: Int) {
        guard round == 1, roundOneNoted else { return }
        kcmacVerified = true
    }

    /// A later key round armed with this verdict and this signer key.
    public mutating func noteLaterRound(sigOk: Bool, signerKey: Data?) {
        guard roundOneNoted else { return }
        if !sigOk || signerKey != self.signerKey { poisoned = true }
    }
}

// MARK: - Tokens received (steps R13 and R14 below, GROUP_CALLS_V2 2.7, Promotion token)

/// The tokens a device received for one live 1:1 call, at most `GroupPromotionToken.maxHeld`.
public struct PromotionTokenBook: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        public let groupCallId: String
        public let creatorUserId: String
        public let invitees: [String]
        public let issuedAtMs: UInt64
        public let lifetimeMs: UInt32
        /// This device's monotonic clock at receipt.
        public let receiptMonoMs: Int64
        public let token: Data
        public var consumed: Bool

        init(groupCallId: String, creatorUserId: String, invitees: [String], issuedAtMs: UInt64, lifetimeMs: UInt32,
             receiptMonoMs: Int64, token: Data, consumed: Bool = false) {
            self.groupCallId = groupCallId
            self.creatorUserId = creatorUserId
            self.invitees = invitees
            self.issuedAtMs = issuedAtMs
            self.lifetimeMs = lifetimeMs
            self.receiptMonoMs = receiptMonoMs
            self.token = token
            self.consumed = consumed
        }
    }

    public private(set) var entries: [Entry] = []
    /// Every group id a token was ever stored for in the life of the call, evicted ones included: one
    /// token per group id.
    public private(set) var usedGroupIds: Set<String> = []

    public init() {}

    public enum StoreResult: Equatable, Sendable {
        case stored
        /// Stored; the oldest token (by receipt) was removed to stay within the limit.
        case storedEvicting(groupCallId: String)
        /// A byte-identical copy of a token already stored (a re-send): nothing changes.
        case identicalCopy
        /// Another token for a group id that already has one: dropped, the first one stays.
        case duplicateGroup
    }

    /// R13 and R14.
    public mutating func store(_ parsed: GroupPromotionToken.Parsed, receiptMonoMs: Int64) -> StoreResult {
        let group = parsed.fields.groupCallId
        if let existing = entries.first(where: { $0.groupCallId == group }) {
            return existing.token == parsed.token ? .identicalCopy : .duplicateGroup
        }
        if usedGroupIds.contains(group) { return .duplicateGroup }
        entries.append(Entry(
            groupCallId: group, creatorUserId: parsed.fields.creatorUserId, invitees: parsed.fields.invitees,
            issuedAtMs: parsed.fields.issuedAtMs, lifetimeMs: parsed.fields.lifetimeMs,
            receiptMonoMs: receiptMonoMs, token: parsed.token))
        usedGroupIds.insert(group)
        guard entries.count > GroupPromotionToken.maxHeld else { return .stored }
        var oldest = 0
        for index in 1..<entries.count where entries[index].receiptMonoMs < entries[oldest].receiptMonoMs {
            oldest = index
        }
        let removed = entries.remove(at: oldest)
        return .storedEvicting(groupCallId: removed.groupCallId)
    }

    public func entry(forGroupCallId id: String) -> Entry? {
        let key = GroupCallIds.lower(id)
        return entries.first(where: { $0.groupCallId == key })
    }

    public enum Freshness: Equatable, Sendable {
        /// No token for this group call.
        case absent
        /// The token was used for an automatic join already.
        case consumed
        /// Outside its window by the wall clock, or held for longer than its lifetime by the
        /// monotonic clock (a jump of the wall clock cannot revive it).
        case stale
        case fresh
    }

    /// GROUP_CALLS_V2 2.7, Consent: whether the token of `id` can admit a join right now.
    public func state(forGroupCallId id: String, nowWallMs: Int64, nowMonoMs: Int64) -> Freshness {
        guard let entry = entry(forGroupCallId: id) else { return .absent }
        if entry.consumed { return .consumed }
        let drop = GroupPromotionToken.freshnessDrop(
            issuedAtMs: entry.issuedAtMs, lifetimeMs: entry.lifetimeMs, nowWallMs: nowWallMs)
        if drop != nil { return .stale }
        if nowMonoMs - entry.receiptMonoMs > Int64(entry.lifetimeMs) { return .stale }
        return .fresh
    }

    /// One use: marks the token consumed and returns it, or nil when there is none or it was used.
    public mutating func consume(groupCallId id: String) -> Entry? {
        let key = GroupCallIds.lower(id)
        guard let index = entries.firstIndex(where: { $0.groupCallId == key && !$0.consumed }) else { return nil }
        entries[index].consumed = true
        return entries[index]
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        usedGroupIds.insert(entry.groupCallId)
    }
}

// MARK: - The live 1:1 call's context

/// Everything the token logic keeps for the 1:1 call that is live on this device.
public struct PromotionCallContext: Equatable, Sendable {
    /// The call id as this device knows it (compared with `ieq`).
    public let callId: String
    /// The user on the other end of the call.
    public let peerUserId: String
    public var anchor = OneToOneAnchor()
    public var book = PromotionTokenBook()

    public init(callId: String, peerUserId: String) {
        self.callId = callId
        self.peerUserId = peerUserId
    }
}

// MARK: - Receiver (GROUP_CALLS_V2 2.7, Promotion token)

public enum GroupPromotionReceiver {

    public enum Outcome: Equatable, Sendable {
        case stored(groupCallId: String)
        case storedEvicting(groupCallId: String, evicted: String)
        /// A re-send: nothing changed, nothing is logged.
        case identicalCopy
        case dropped(GroupPromotionToken.Drop)
    }

    /// Steps R1 to R14 for one `opaque_message` whose data carries a `GRPPROMO:` tag. `senderId` is
    /// the server-stamped sender, `selfUserId` this device's account, `context` the live 1:1 call (nil
    /// when there is none). Every failure is a silent drop; the 1:1 call is never touched.
    public static func receive(data: String, senderId: String, selfUserId: String,
                               context: inout PromotionCallContext?,
                               nowWallMs: Int64, nowMonoMs: Int64) -> Outcome {
        // R1 route.
        guard let split = GroupPromotionToken.splitWire(data) else { return .dropped(.malformed) }
        // R2 size.
        guard data.utf8.count <= GroupPromotionToken.maxDataLength else { return .dropped(.tooLong) }
        // R3 live call. Sibling devices of the peer have none and create no state.
        guard var live = context, GroupCallIds.ieq(split.callId, live.callId) else { return .dropped(.noCall) }
        // R4 sender.
        guard GroupCallIds.ieq(senderId, live.peerUserId) else { return .dropped(.notPeer) }
        // R5 anchor. A KCMAC still pending does not block the reception.
        guard live.anchor.isDefined, !live.anchor.poisoned,
              let anchorKey = live.anchor.signerKey, let binding = live.anchor.acceptBinding1 else {
            return .dropped(.noAnchor)
        }
        // R6 to R8.
        let parsed: GroupPromotionToken.Parsed
        switch GroupPromotionToken.parse(encoded: split.encoded) {
        case .failure(let drop): return .dropped(drop)
        case .success(let value): parsed = value
        }
        // R9 signer key.
        guard parsed.fields.signerKey == anchorKey else { return .dropped(.signerDiff) }
        // R10 signature.
        guard GroupPromotionToken.verifySignature(parsed, signerKey: anchorKey) else { return .dropped(.badSig) }
        // R11 bindings, each in turn.
        guard GroupCallIds.ieq(parsed.fields.fromCallId, live.callId) else { return .dropped(.fromDiff) }
        guard parsed.fields.acceptBinding1 == binding else { return .dropped(.bindDiff) }
        guard GroupCallIds.ieq(parsed.fields.creatorUserId, live.peerUserId) else { return .dropped(.creatorDiff) }
        guard GroupCallIds.contains(parsed.fields.invitees, selfUserId) else { return .dropped(.notInvited) }
        // R12 freshness.
        if let drop = GroupPromotionToken.freshnessDrop(
            issuedAtMs: parsed.fields.issuedAtMs, lifetimeMs: parsed.fields.lifetimeMs, nowWallMs: nowWallMs) {
            return .dropped(drop)
        }
        // R13 and R14.
        let result = live.book.store(parsed, receiptMonoMs: nowMonoMs)
        switch result {
        case .duplicateGroup:
            return .dropped(.dupGroup)
        case .identicalCopy:
            return .identicalCopy
        case .stored:
            context = live
            return .stored(groupCallId: parsed.fields.groupCallId)
        case .storedEvicting(let evicted):
            context = live
            return .storedEvicting(groupCallId: parsed.fields.groupCallId, evicted: evicted)
        }
    }
}

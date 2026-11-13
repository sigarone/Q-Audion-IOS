import Foundation

/// The key state of one call: the rounds that exist, the chain keys kept for them and the small decisions that depend on both.
/// One object per call, owned by `QAudionCallIntegration` (guarded by its lock), created when the round-1 session is installed
/// and closed when the call ends.
///
/// Rules of the file:
/// - one `NSLock` inside the object; every method is one critical section; nothing suspends and nothing is called out under it
///   (no closure parameter, no callback); a method returns a value and the caller reacts after every lock is released;
/// - lock order: integration `offerInstallLock` -> integration `lock` -> `LiveCallCrypto.lock` -> `InnerSealV2Session.lock` /
///   `OuterSealerSet.lock` / `ChainLease.lock`, never the reverse; the ports of the two layers never take `LiveCallCrypto.lock`;
/// - no table is keyed by a call id, no round is evicted to make room: at most `KcMacRoundBook.maxPendingRounds` rounds are
///   undecided, the seventeenth is refused;
/// - key bytes live only in `ChainKeyBuffer` (wiped on every path); a lease and a reservation own COPIES.

/// A copy of the chain key of the base round, handed to one round in flight. Its own lock: any holder may close it, the first
/// close wipes the copy, a derive after that returns nil, a derive that is running finishes with the bytes it started with.
public final class ChainLease: @unchecked Sendable {
    private let lock = NSLock()
    private var key: ChainKeyBuffer?
    public let base: Int32

    init(base: Int32, key: ChainKeyBuffer) {
        self.base = base
        self.key = key
    }

    /// The session key of the round this lease belongs to, or nil once the lease is closed or an input has the wrong size.
    public func deriveSessionKey(pqcSharedSecret: Data, x25519Shared: Data, psk: Data?, acceptHash: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = key else { return nil }
        return RekeyChain.deriveSessionKeyChained(
            pqcSharedSecret: pqcSharedSecret, x25519Shared: x25519Shared, ckB: key, base: base, psk: psk, acceptHash: acceptHash)
    }

    /// Idempotent, from any holder.
    public func close() {
        lock.lock()
        let held = key
        key = nil
        lock.unlock()
        held?.wipe()
    }

    public var isWipedForTesting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return key == nil
    }
}

/// The slot an acceptor holds for a rekey OFFER it admitted, from the gate until the round is staged or given up. A handle, not
/// a counter: it owns its lease and is consumed exactly once.
public final class AcceptReservation: @unchecked Sendable {
    public let epoch: Int32
    public let lease: ChainLease?
    /// Guarded by the lock of the `LiveCallCrypto` that issued it.
    fileprivate var consumed = false

    fileprivate init(epoch: Int32, lease: ChainLease?) {
        self.epoch = epoch
        self.lease = lease
    }
}

/// What the outer relay layer of round 1 is built from.
enum OuterRound1Input {
    /// No exchange in effect.
    case none
    case kem(secrets: RelaySecrets, acceptBinding: Data)
    /// The local derivation failed after the ACCEPT was received: the outer layer of the call is off.
    case failed
    /// The offerer read an all-zero X25519 output: no outer layer of this exchange (the features already dropped it).
    case zero
}

/// What a rekey round hands to the outer layer.
enum OuterStageInput {
    /// The round has no outer step (the layer does not rotate).
    case none
    /// This side installs no key for the round, and says why.
    case hold(OuterHoldReason)
    case kem(secrets: RelaySecrets, acceptBinding: Data)
}

enum OuterStatus: Int, Equatable, Sendable {
    case none = 0
    case ok = 1
    case failed = 2
    case off = 3
}

public final class LiveCallCrypto: @unchecked Sendable {

    public enum Role: Equatable, Sendable {
        case offerer
        case acceptor
    }

    /// What blocked a rekey trigger. The raw values are the numbers of the log line.
    public enum DeferKind: Int, Equatable, Sendable {
        case chain = 1
        case spacing = 2
        case undecided = 3
    }

    /// What the two round-1 bundles negotiated, fixed once after verification.
    public struct Features: Equatable {
        /// `capsBindV1` on both round-1 bundles.
        public let ext: Bool
        public let rekeyChainV1: Bool
        public let frameKeyV6: Bool
        /// The per-round inner audio seal.
        public let innerSealV2: Bool
        /// The outer relay layer keyed by its own exchange, IN EFFECT (both bundles carry a valid member).
        public let relayKemV1: Bool
        /// The outer relay layer rotates its keys at every rekey, IN EFFECT. Implies `relayKemV1`.
        public let relayRotV1: Bool
        /// OUR round-1 bundle's capabilities as sent: every later round of the call carries the same ones.
        public let ownCapabilities: AndroidHandshakeBundle.Capabilities
        public let ownTag: Bool
        public let peerTag: Bool
        public let selfIsCaller: Bool

        public var anyS8bTag: Bool { rekeyChainV1 || frameKeyV6 || innerSealV2 || relayKemV1 }

        public init(ext: Bool, rekeyChainV1: Bool, frameKeyV6: Bool, innerSealV2: Bool = false,
                    relayKemV1: Bool = false, relayRotV1: Bool = false,
                    ownCapabilities: AndroidHandshakeBundle.Capabilities, ownTag: Bool, peerTag: Bool, selfIsCaller: Bool) {
            self.ext = ext
            self.rekeyChainV1 = rekeyChainV1
            self.frameKeyV6 = frameKeyV6
            self.innerSealV2 = innerSealV2
            self.relayKemV1 = relayKemV1
            self.relayRotV1 = relayRotV1
            self.ownCapabilities = ownCapabilities
            self.ownTag = ownTag
            self.peerTag = peerTag
            self.selfIsCaller = selfIsCaller
        }

        /// From the analyses of the two round-1 bundles (the bytes this side sent and the bytes it received).
        public static func negotiate(
            own: BundleCapsBind, peer: BundleCapsBind, ownCapabilities: AndroidHandshakeBundle.Capabilities, selfIsCaller: Bool
        ) -> Features {
            let relay = RelayDecision.inEffect(own: own, peer: peer)
            return Features(
                ext: CapsBind.isActive(own: own, peer: peer),
                rekeyChainV1: CapsBind.negotiateS8b(own: own, peer: peer, tag: "rekeyChainV1"),
                frameKeyV6: CapsBind.negotiateS8b(own: own, peer: peer, tag: "frameKeyV6"),
                innerSealV2: CapsBind.negotiateS8b(own: own, peer: peer, tag: "innerSealV2"),
                relayKemV1: relay.kem, relayRotV1: relay.rot,
                ownCapabilities: ownCapabilities, ownTag: own.hasTag, peerTag: peer.hasTag, selfIsCaller: selfIsCaller)
        }

        /// The same features without the outer relay layer: the offerer's reading of a round-1 ACCEPT whose key exchange came out
        /// as an all-zero X25519 output. The bundles keep their tags (later rounds carry the ones of round 1).
        public func droppingRelay() -> Features {
            Features(
                ext: ext, rekeyChainV1: rekeyChainV1, frameKeyV6: frameKeyV6, innerSealV2: innerSealV2,
                relayKemV1: false, relayRotV1: false,
                ownCapabilities: ownCapabilities, ownTag: ownTag, peerTag: peerTag, selfIsCaller: selfIsCaller)
        }
    }

    /// The acceptor gate's answer.
    public enum GateResult {
        case admitted(AcceptReservation)
        /// The chain rule refused the OFFER: no key, no ACCEPT, the call goes on.
        case refused(RekeyChain.Refusal)
        /// Not above the highest admitted round: dropped before anything is written.
        case staleEpoch
        case pendingFull
        case closed
    }

    public enum StageResult: Equatable {
        case staged
        case alreadyStaged
        case staleEpoch
        case pendingFull
        case closed
        /// The per-round inner seal has a live slot with the same envelope byte and another round: nothing was written.
        case slotCollision
        /// The keys of the per-round inner seal could not be derived: nothing was written.
        case deriveFailed
    }

    public enum OwnReservation {
        case granted(ChainLease?)
        case refused
    }

    public enum OfferGate: Equatable {
        case go
        /// `timerMs` is set only when this answer made the deferral (one timer per deferral).
        case deferred(DeferKind, timerMs: Int?)
        case closed
    }

    public struct ConfirmResult: Equatable {
        public let alreadyConfirmed: Bool
        public let rearm: DeferKind?
        /// The send pointer of the per-round inner seal moved: returned, never called out under a lock.
        public let innerSendMoved: InnerSendMove?
        /// What the outer layer did at the confirmation (a send switch, an erase): returned, never called out under a lock.
        public let outerEvents: OuterEvents

        public init(alreadyConfirmed: Bool, rearm: DeferKind?, innerSendMoved: InnerSendMove? = nil, outerEvents: OuterEvents = OuterEvents()) {
            self.alreadyConfirmed = alreadyConfirmed
            self.rearm = rearm
            self.innerSendMoved = innerSendMoved
            self.outerEvents = outerEvents
        }
    }

    /// What staging a round did, the outer layer included.
    struct StageReport: Equatable {
        let result: StageResult
        /// The round's outer keys were installed.
        let outerInstalled: Bool
        /// This side installed no outer key for the round, and why.
        let outerHold: OuterHoldReason?
        let outerEvents: OuterEvents
    }

    /// What failing a round did.
    struct FailReport: Equatable {
        let rearm: DeferKind?
        let outerEvents: OuterEvents
    }

    /// What the tests read: the rounds, the reservations and the two watermarks.
    public struct Snapshot: Equatable {
        public let rounds: [Int32]
        public let confirmed: [Int32]
        public let retained: [Int32]
        public let reservations: Int
        public let maxAdmittedE: Int32
        public let maxStagedE: Int32
        public let closed: Bool
        /// The round the inner seal sends under (-1: none), and the rounds that hold a slot. Epochs only, never bytes.
        public let innerSend: Int32
        public let innerSlots: [Int32]
    }

    private struct RoundRecord {
        let epoch: Int32
        var confirmed: Bool
        var ck: ChainKeyBuffer?
    }

    private enum OwnPhase {
        case reserved
        case offered
        case staged
    }

    private struct OwnRound {
        var epoch: Int32
        var phase: OwnPhase
        var lease: ChainLease?
    }

    /// The number of OFFERs a handing-over is spaced by: no OFFER leaves less than this after the previous one was handed over.
    public static let offerSpacingMs = 5000
    private static let maxUndecided = KcMacRoundBook.maxPendingRounds

    private static let genLock = NSLock()
    private nonisolated(unsafe) static var lastGen: UInt64 = 0

    private static func nextGen() -> UInt64 {
        genLock.lock()
        defer { genLock.unlock() }
        lastGen += 1
        return lastGen
    }

    /// A label for logs and for the key-confirmation hand-off; the guard inside the engine is identity (`===`).
    public let gen: UInt64
    /// The exact channel id of the round-1 OFFER.
    public let callId: String
    /// `RekeyChain.asciiLower(callId)`: HKDF input only.
    public let callIdL: String
    public let role: Role
    public let features: Features

    private let lock = NSLock()
    private var rounds: [RoundRecord] = []
    private var maxAdmittedE: Int32 = -1
    private var maxStagedE: Int32 = -1
    private var own: OwnRound?
    private var reservations: [AcceptReservation] = []
    private var lastOfferHandedOverAtMs: Int?
    private var round1Confirmed = false
    private var chainRefusal: Int32?
    /// The round of the last refusal of any kind (a chained rekey refused, or a slot collision of the inner seal).
    private var lastRefusal: Int32?
    private var deferred: DeferKind?
    private var closed = false
    /// The state of the per-round inner seal; nil for a call that did not negotiate it. The reference never changes.
    private let inner: InnerSealV2Session?
    /// The outer relay layer; nil for a call whose exchange is not in effect or could not be set up. Set once, before the object is
    /// shared.
    private var outer: OuterSealerSet?
    private var outerPortObject: OuterSealPort?
    private var outerState: OuterStatus = .none
    /// The last round that gave up its outer keys and why, the sticky reason of round 1, the round the send pointer was put back
    /// from, and the highest round that authenticated a frame: the words of the protection line.
    private var outerHold: (epoch: Int32, reason: OuterHoldReason)?
    private var outerRound1Reason: OuterHoldReason?
    private var outerRevertFrom: Int32?
    private var outerRxEpoch: Int32 = -1

    private init(callId: String, role: Role, features: Features, nowMs: @escaping @Sendable () -> Int) {
        self.gen = Self.nextGen()
        self.callId = callId
        let lowered = RekeyChain.asciiLower(callId)
        self.callIdL = lowered
        self.role = role
        self.features = features
        self.inner = features.innerSealV2
            ? InnerSealV2Session(callIdL: lowered, role: role, withVideo: features.relayKemV1, nowMs: nowMs) : nil
    }

    /// Creates the object and stages round 0 with the round-1 session key. nil when a key of round 0 cannot be derived: every key
    /// derived so far is wiped and nothing is returned.
    static func adopt(callId: String, role: Role, features: Features, sessionKey: Data, outer outerInput: OuterRound1Input = .none,
                      nowMs: @escaping @Sendable () -> Int = { SasCommit.monotonicNowMs() }) -> LiveCallCrypto? {
        let object = LiveCallCrypto(callId: callId, role: role, features: features, nowMs: nowMs)
        var ck: ChainKeyBuffer?
        if features.rekeyChainV1 {
            guard let derived = RekeyChain.deriveChainKey(sessionKey: sessionKey, callIdL: object.callIdL, epoch: 0) else { return nil }
            ck = ChainKeyBuffer(copying: derived)
        }
        if let inner = object.inner, !inner.stageRound0(sessionKey: sessionKey) {
            ck?.wipe()
            return nil
        }
        // An outer failure never refuses the object: the layer is marked failed and the call goes on.
        object.setUpOuterRound1(input: outerInput, sessionKey: sessionKey, nowMs: nowMs)
        object.rounds = [RoundRecord(epoch: 0, confirmed: false, ck: ck)]
        object.maxStagedE = 0
        object.maxAdmittedE = 0
        return object
    }

    /// Round 1 of the outer layer: the four keys of round 0 and the set that holds them. Before the object is shared.
    private func setUpOuterRound1(input: OuterRound1Input, sessionKey: Data, nowMs: @escaping @Sendable () -> Int) {
        if case .zero = input { outerRound1Reason = .x25519Zero }
        guard features.relayKemV1 else { return }
        guard case .kem(let secrets, let binding) = input else {
            outerState = .failed
            return
        }
        guard let keys = RelayKem.deriveOuterKeys(secrets: secrets, sessionKey: sessionKey, acceptBinding: binding, callIdL: callIdL) else {
            outerState = .failed
            return
        }
        let created = OuterSealerSet(role: role, rot: features.relayRotV1, nowMs: nowMs)
        guard created.installRound0(keys).result == .ok else {
            outerState = .failed
            return
        }
        outer = created
        outerPortObject = created.makePort()
        outerState = .ok
    }

    // MARK: - Read-only

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// The id of the round-1 OFFER, compared exactly.
    public func matches(_ id: String) -> Bool {
        id == callId
    }

    /// For the receive-side rule that only the caller rekeys: a chained call, this device is the caller, the object is open.
    public func isChainedOfferer(exactCallId id: String) -> (chainedOfferer: Bool, exactIdMatches: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (!closed && role == .offerer && features.rekeyChainV1, id == callId)
    }

    /// The epoch of the last chain refusal (sticky), for the level line.
    public var chainRefusalEpoch: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return chainRefusal
    }

    /// The round of the last refusal of any kind, for the level line.
    public var lastRefusalEpoch: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return lastRefusal
    }

    /// The port the engine seals and opens through: nil for a call without the seal, and nil once this object is closed.
    public var innerPort: InnerSealPort? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let session = inner else { return nil }
        return session
    }

    /// The round the inner seal sends under; nil without the seal or once closed.
    public var innerSendEpoch: Int32? {
        inner?.sendEpoch
    }

    /// The number of round slots the inner seal holds.
    public var innerSlotCount: Int {
        inner?.slotCount ?? 0
    }

    /// The port the media paths seal and open through: nil unless the outer layer is up, and nil once this object is closed.
    public var outerSealPort: OuterSealPort? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, outerState == .ok else { return nil }
        return outerPortObject
    }

    var outerStatusValue: OuterStatus {
        lock.lock()
        defer { lock.unlock() }
        return outerState
    }

    /// The inner video port: only for a call that negotiated the exchange next to the inner seal, and only while open.
    public var innerVideoPort: InnerVideoPort? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, features.relayKemV1, let session = inner else { return nil }
        return session
    }

    /// How relay video is carried. `legacy` unless the exchange is in effect; then `none` when the outer layer is not up (the video
    /// never goes out without it), `double` with the inner seal and `outerOnly` without.
    public var relayVideoMode: RelayVideoMode {
        lock.lock()
        defer { lock.unlock() }
        guard features.relayKemV1 else { return .legacy }
        guard !closed, outerState == .ok else { return .none }
        return features.innerSealV2 ? .double : .outerOnly
    }

    /// What the words of the protection line read.
    func outerLevelInput() -> OuterLevelInput {
        lock.lock()
        defer { lock.unlock() }
        return OuterLevelInput(
            status: outerState, relayKemInEffect: features.relayKemV1, relayRotInEffect: features.relayRotV1,
            holdEpoch: outerHold?.epoch, holdReason: outerHold?.reason, round1Reason: outerRound1Reason,
            revertFrom: outerRevertFrom, rxEpoch: outerRxEpoch)
    }

    /// What would refuse a slot of `epoch` in the outer layer now (read-only); nil when none, or when the layer is not up.
    func outerRefusal(epoch: Int32) -> OuterInstallResult? {
        lock.lock()
        let set = outer
        lock.unlock()
        return set?.refusal(epoch: epoch)
    }

    /// Epochs and counters of the outer layer, never bytes; nil without the layer.
    func outerSnapshot() -> OuterSnapshot? {
        lock.lock()
        let set = outer
        lock.unlock()
        return set?.snapshot()
    }

    /// The round the outer layer seals under; nil without the layer or once closed.
    var outerSendEpoch: Int32? {
        lock.lock()
        let set = outer
        lock.unlock()
        guard let value = set?.sendEpoch(), value >= 0 else { return nil }
        return value
    }

    /// The acceptor's read-only check, before its ACCEPT, that a slot for `epoch` can be taken: nothing is written or erased.
    func precheckInnerStage(epoch: Int32) -> InnerStageRefusal? {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        return inner?.refusal(forEpoch: epoch)
    }

    /// A round refused for a slot collision: the only write of the refusal record that the check above does not make.
    func noteInnerRefusal(epoch: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        lastRefusal = epoch
    }

    public var stagedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return undecidedLocked()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            rounds: rounds.map { $0.epoch }.sorted(), confirmed: rounds.filter { $0.confirmed }.map { $0.epoch }.sorted(),
            retained: rounds.filter { $0.ck != nil }.map { $0.epoch }.sorted(), reservations: reservations.count,
            maxAdmittedE: maxAdmittedE, maxStagedE: maxStagedE, closed: closed,
            innerSend: inner?.sendEpoch ?? -1, innerSlots: inner?.snapshot().epochs ?? [])
    }

    /// The greatest CONFIRMED round whose chain key is still retained (never "the key now installed").
    public func selectBase() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return selectBaseLocked()
    }

    /// Whether a rekey OFFER could be built now. Read-only: it records nothing.
    public func mayOffer(nowMs: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && blockerLocked(nowMs: nowMs) == nil
    }

    // MARK: - Rounds

    /// The offerer's round: the base is chosen, a lease with a copy of its chain key is returned (none without the tag) and the
    /// round is recorded as undecided. Taken for every call that negotiated a tag of the rekey family (the spacing rule needs it).
    public func reserveOwn(epoch: Int32) -> OwnReservation {
        lock.lock()
        defer { lock.unlock() }
        guard features.anyS8bTag else { return closed ? .refused : .granted(nil) }
        guard !closed, own == nil else { return .refused }
        var lease: ChainLease?
        if features.rekeyChainV1 {
            guard let base = selectBaseLocked(), base < epoch,
                  let copy = rounds.first(where: { $0.epoch == base })?.ck?.duplicate() else { return .refused }
            lease = ChainLease(base: base, key: copy)
        }
        own = OwnRound(epoch: epoch, phase: .reserved, lease: lease)
        return .granted(lease)
    }

    /// The OFFER of `epoch` is being handed to the transport: the 5 s spacing starts now, whatever becomes of it.
    public func markOffered(epoch: Int32, nowMs: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, var current = own, current.epoch == epoch else { return }
        lastOfferHandedOverAtMs = nowMs
        current.phase = .offered
        own = current
    }

    /// The offerer's gate before a rekey: nothing is consumed by a deferral.
    public func checkOffer(nowMs: Int) -> OfferGate {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        guard let blocker = blockerLocked(nowMs: nowMs) else {
            // The gate is open: a spacing deferral still pending is released here, so its timer does not start a second round.
            if deferred == .spacing { deferred = nil }
            return .go
        }
        let isNew = deferred == nil
        if isNew { deferred = blocker.kind }
        let timer: Int? = (isNew && blocker.kind == .spacing) ? blocker.untilMs : nil
        return .deferred(deferred ?? blocker.kind, timerMs: timer)
    }

    /// The acceptor gate: decision and reservation in one critical section, whatever the signature verdict. `chainBaseTokens` are
    /// the raw tokens of the members named `chainBase` of the validated OFFER.
    public func gateAccept(epoch: Int32, offerSigOk: Bool, chainBaseTokens: [[UInt8]]) -> GateResult {
        lock.lock()
        defer { lock.unlock() }
        if closed { return .closed }
        if epoch <= maxAdmittedE { return .staleEpoch }
        if undecidedLocked() + reservations.count >= Self.maxUndecided { return .pendingFull }
        var lease: ChainLease?
        if features.rekeyChainV1 {
            let table = rounds
            let decision = RekeyChain.decideChainBase(
                tokens: chainBaseTokens, epoch: epoch, hasRecord: !table.isEmpty,
                holdsCk: { base in table.contains { $0.epoch == base && $0.ck != nil } },
                applies: true)
            switch decision {
            case .refuse(let why):
                if offerSigOk {
                    chainRefusal = epoch
                    lastRefusal = epoch
                }
                return .refused(why)
            case .ignored:
                break
            case .accept(let base):
                guard let copy = rounds.first(where: { $0.epoch == base })?.ck?.duplicate() else {
                    if offerSigOk {
                        chainRefusal = epoch
                        lastRefusal = epoch
                    }
                    return .refused(.noCk)
                }
                lease = ChainLease(base: base, key: copy)
            }
        }
        let handle = AcceptReservation(epoch: epoch, lease: lease)
        reservations.append(handle)
        if offerSigOk { maxAdmittedE = epoch }
        return .admitted(handle)
    }

    /// The first write that makes a round exist. The acceptor path (`ours: false`) takes any live reservation whatever the order
    /// of staging and refuses only a closed object; the offerer path (`ours: true`) is ordered by round. A call without a tag
    /// of the rekey family never refuses except when closed.
    public func stageRound(epoch: Int32, sessionKey: Data, ours: Bool, handle: AcceptReservation?) -> StageResult {
        stageRoundReport(epoch: epoch, sessionKey: sessionKey, ours: ours, handle: handle, outer: .none).result
    }

    /// The same, with the outer layer: after the chain key and the slot of the inner seal, and before the round is recorded, the
    /// outer keys of the round are derived and installed. An outer failure never changes the result of the round: the round is
    /// staged, the outer layer stays on its epoch and the report says why.
    func stageRoundReport(epoch: Int32, sessionKey: Data, ours: Bool, handle: AcceptReservation?,
                          outer input: OuterStageInput) -> StageReport {
        lock.lock()
        defer { lock.unlock() }
        func refused(_ result: StageResult) -> StageReport {
            if case .kem(let secrets, _) = input { secrets.wipe() }
            return StageReport(result: result, outerInstalled: false, outerHold: nil, outerEvents: OuterEvents())
        }
        if closed {
            return refused(.closed)
        }
        if rounds.contains(where: { $0.epoch == epoch }) {
            consumeLocked(handle)
            return refused(.alreadyStaged)
        }
        if ours, features.anyS8bTag {
            if epoch <= maxStagedE { return refused(.staleEpoch) }
            if undecidedLocked() >= Self.maxUndecided { return refused(.pendingFull) }
        }
        var ck: ChainKeyBuffer?
        if features.rekeyChainV1 {
            guard let derived = RekeyChain.deriveChainKey(sessionKey: sessionKey, callIdL: callIdL, epoch: epoch) else {
                consumeLocked(handle)
                return refused(.closed)
            }
            ck = ChainKeyBuffer(copying: derived)
        }
        // The slot of the inner seal is taken before the round is recorded, both under this lock, so the two tables never
        // disagree: derive first, then install; a refusal writes nothing and wipes what was derived.
        if let inner {
            guard let prepared = inner.prepare(sessionKey: sessionKey) else {
                ck?.wipe()
                consumeLocked(handle)
                return refused(.deriveFailed)
            }
            if let refusal = inner.install(epoch: epoch, prepared: prepared) {
                ck?.wipe()
                consumeLocked(handle)
                switch refusal {
                case .duplicate: return refused(.alreadyStaged)
                case .slotCollision: return refused(.slotCollision)
                case .pendingFull: return refused(.pendingFull)
                case .closed: return refused(.closed)
                }
            }
        }
        var outerInstalled = false
        var outerHoldReason: OuterHoldReason?
        var outerEvents = OuterEvents()
        if let outerSet = outer, features.relayRotV1, outerState == .ok {
            switch input {
            case .none:
                break
            case .hold(let reason):
                outerHoldReason = reason
            case .kem(let secrets, let binding):
                if let why = outerSet.refusal(epoch: epoch) {
                    // a collision derives nothing; any other refusal is a failure of the exchange
                    outerHoldReason = why == .slotCollision ? .slotCollision : .relayKem
                } else if let keys = RelayKem.deriveOuterKeys(
                    secrets: secrets, sessionKey: sessionKey, acceptBinding: binding, callIdL: callIdL) {
                    let report = outerSet.install(epoch: epoch, keys: keys)
                    outerEvents = report.events
                    if report.result == .ok {
                        outerInstalled = true
                    } else {
                        outerHoldReason = report.result == .slotCollision ? .slotCollision : .relayKem
                    }
                } else {
                    outerHoldReason = .relayKem
                }
            }
        }
        if case .kem(let secrets, _) = input { secrets.wipe() }
        if let reason = outerHoldReason { outerHold = (epoch: epoch, reason: reason) }
        noteOuterEventsLocked(outerEvents)
        rounds.append(RoundRecord(epoch: epoch, confirmed: false, ck: ck))
        maxStagedE = max(maxStagedE, epoch)
        if ours, var current = own, current.epoch == epoch {
            current.phase = .staged
            own = current
        }
        consumeLocked(handle)
        return StageReport(result: .staged, outerInstalled: outerInstalled, outerHold: outerHoldReason, outerEvents: outerEvents)
    }

    /// The peer's key confirmation of the round verified. Confirming a round twice does nothing.
    public func confirmRound(epoch: Int32) -> ConfirmResult {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let index = rounds.firstIndex(where: { $0.epoch == epoch }), !rounds[index].confirmed else {
            return ConfirmResult(alreadyConfirmed: true, rearm: nil)
        }
        rounds[index].confirmed = true
        if epoch == 0 { round1Confirmed = true }
        if let current = own, current.epoch == epoch {
            current.lease?.close()
            own = nil
        }
        // The only mover of the send pointer of the inner seal: the peer's confirmation of a later round.
        let moved = inner?.peerKcmac(epoch: epoch)
        // The same for the outer layer, whose policy may start the caller's trial or move the callee's pointer.
        let outerEvents = outer?.peerKcmac(epoch: epoch) ?? OuterEvents()
        noteOuterEventsLocked(outerEvents)
        retainLocked()
        return ConfirmResult(alreadyConfirmed: false, rearm: takeRearmLocked(), innerSendMoved: moved, outerEvents: outerEvents)
    }

    /// The key confirmation of the round failed or ended without a verdict: its chain key is wiped at once.
    public func failRound(epoch: Int32) -> DeferKind? {
        failRoundReport(epoch: epoch).rearm
    }

    /// The same, with what the outer layer did (its staged slot of the round is erased).
    func failRoundReport(epoch: Int32) -> FailReport {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return FailReport(rearm: nil, outerEvents: OuterEvents()) }
        var outerEvents = OuterEvents()
        if let index = rounds.firstIndex(where: { $0.epoch == epoch && !$0.confirmed }) {
            rounds[index].ck?.wipe()
            rounds.remove(at: index)
            inner?.abandon(epoch: epoch)
            outerEvents = outer?.abandon(epoch: epoch) ?? OuterEvents()
            noteOuterEventsLocked(outerEvents)
        }
        if let current = own, current.epoch == epoch {
            current.lease?.close()
            own = nil
        }
        return FailReport(rearm: takeRearmLocked(), outerEvents: outerEvents)
    }

    /// Ends an acceptor reservation without staging: its lease copy is wiped.
    public func abandon(handle: AcceptReservation) {
        lock.lock()
        defer { lock.unlock() }
        consumeLocked(handle)
    }

    /// Ends the offerer's own undecided round without staging it (a staged or confirmed round is not touched).
    public func abandonOwn(epoch: Int32) -> DeferKind? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let current = own, current.epoch == epoch, current.phase != .staged else { return nil }
        current.lease?.close()
        own = nil
        return takeRearmLocked()
    }

    /// The spacing timer fired. True once per deferral.
    public func spacingTimerFired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, deferred == .spacing else { return false }
        deferred = nil
        return true
    }

    /// Idempotent: every key and every issued handle is wiped, every later call is a refusal.
    public func close() {
        lock.lock()
        closed = true
        // The outer layer first: every key wiped, the sink dropped, every later seal and open refused.
        outer?.close()
        for index in rounds.indices {
            rounds[index].ck?.wipe()
            rounds[index].ck = nil
        }
        rounds.removeAll()
        inner?.close()
        own?.lease?.close()
        own = nil
        for handle in reservations {
            handle.lease?.close()
            handle.consumed = true
        }
        reservations.removeAll()
        deferred = nil
        lock.unlock()
    }

    // MARK: - The outer layer (reached only from the wrappers of the integration)

    /// Our own confirmation of `epoch` was handed to the transport.
    func markOuterKcmacSent(epoch: Int32) -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let set = outer else { return OuterEvents() }
        let events = set.markKcmacSent(epoch: epoch)
        noteOuterEventsLocked(events)
        return events
    }

    /// The peer's CALL_HOLD began or ended: only the caller's layer acts on it.
    func setOuterHold(_ on: Bool) -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let set = outer else { return OuterEvents() }
        let events = set.setHold(on)
        noteOuterEventsLocked(events)
        return events
    }

    /// Time passes for the outer layer (the lazy evaluation also runs inside every seal, open and mutator).
    func tickOuter() -> OuterEvents {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let set = outer else { return OuterEvents() }
        let events = set.tick()
        noteOuterEventsLocked(events)
        return events
    }

    /// The outer layer is gone for the rest of the call (a failed local install, or the peer's `outer-off-v1`): the set is closed,
    /// nothing is sealed or opened through it and no later round stages an outer slot. True when the state changed.
    @discardableResult
    func outerOff() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, outerState != .off else { return false }
        outerState = .off
        outer?.close()
        return true
    }

    /// The receiver of the events born inside a seal or an open of the set.
    func setOuterEventSink(_ sink: (@Sendable (OuterEvents) -> Void)?) {
        lock.lock()
        let set = outer
        lock.unlock()
        set?.setEventSink(sink)
    }

    /// Events that left the set by its sink: the bookkeeping of the protection line follows them.
    func noteOuterEvents(_ events: OuterEvents) {
        lock.lock()
        defer { lock.unlock() }
        noteOuterEventsLocked(events)
    }

    private func noteOuterEventsLocked(_ events: OuterEvents) {
        if let revert = events.reverted { outerRevertFrom = revert.from }
        if let rx = events.rxEpoch, rx > outerRxEpoch { outerRxEpoch = rx }
    }

    // MARK: - Under the lock

    private func undecidedLocked() -> Int {
        rounds.reduce(0) { $0 + ($1.confirmed ? 0 : 1) }
    }

    private func selectBaseLocked() -> Int32? {
        rounds.filter { $0.confirmed && $0.ck != nil }.map { $0.epoch }.max()
    }

    private func blockerLocked(nowMs: Int) -> (kind: DeferKind, untilMs: Int)? {
        if features.rekeyChainV1 && !round1Confirmed { return (.chain, 0) }
        guard features.anyS8bTag else { return nil }
        if own != nil { return (.undecided, 0) }
        if let last = lastOfferHandedOverAtMs, nowMs < last + Self.offerSpacingMs {
            return (.spacing, last + Self.offerSpacingMs - nowMs)
        }
        return nil
    }

    /// The coalesced deferral flag is released once, when the condition that set it is gone.
    private func takeRearmLocked() -> DeferKind? {
        guard let kind = deferred else { return nil }
        switch kind {
        case .chain:
            guard round1Confirmed else { return nil }
        case .undecided:
            guard own == nil else { return nil }
        case .spacing:
            return nil
        }
        deferred = nil
        return kind
    }

    /// Erases the chain key of every round that two later CONFIRMED rounds follow, and forgets the record of a confirmed round
    /// that has no key left.
    private func retainLocked() {
        let confirmed = rounds.filter { $0.confirmed }.map { $0.epoch }
        for index in rounds.indices where rounds[index].ck != nil {
            let epoch = rounds[index].epoch
            if confirmed.filter({ $0 > epoch }).count >= 2 {
                rounds[index].ck?.wipe()
                rounds[index].ck = nil
            }
        }
        rounds.removeAll { $0.confirmed && $0.ck == nil }
    }

    private func consumeLocked(_ handle: AcceptReservation?) {
        guard let handle = handle, !handle.consumed else { return }
        handle.consumed = true
        handle.lease?.close()
        reservations.removeAll { $0 === handle }
    }

    // MARK: - Test seams

    /// Erases the chain key of a round (a state the real mutators reach only through retention).
    func eraseChainKeyForTesting(epoch: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = rounds.firstIndex(where: { $0.epoch == epoch }) else { return }
        rounds[index].ck?.wipe()
        rounds[index].ck = nil
    }

    /// The key buffers of the inner seal, to check that a close wipes them.
    func innerKeyBuffersForTesting() -> [ChainKeyBuffer] {
        inner?.keyBuffersForTesting() ?? []
    }

    /// The key buffers of the outer layer, to check that a close wipes them.
    func outerKeyBuffersForTesting() -> [ChainKeyBuffer] {
        lock.lock()
        let set = outer
        lock.unlock()
        return set?.keyBuffersForTesting() ?? []
    }

    /// The set of the outer layer (nil without it).
    var outerSetForTesting: OuterSealerSet? {
        lock.lock()
        defer { lock.unlock() }
        return outer
    }

    /// The state of the inner seal without any byte of key material.
    func innerSnapshotForTesting() -> InnerSealV2Session.Snapshot? {
        inner?.snapshot()
    }

    /// Records a received counter in the replay window, as a frame would.
    func commitInnerReceivedCounterForTesting(_ ctr: UInt64) {
        inner?.commitReceivedCounterForTesting(ctr)
    }

    /// Whether the chain key of a round is held and wiped (nil: no such round).
    func chainKeyWipedForTesting(epoch: Int32) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = rounds.first(where: { $0.epoch == epoch }) else { return nil }
        return record.ck?.isWipedForTesting ?? true
    }
}

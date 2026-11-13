import Foundation

/// The key state of one call: the rounds that exist, the chain keys kept for them and the small decisions that depend on both.
/// One object per call, owned by `QAudionCallIntegration` (guarded by its lock), created when the round-1 session is installed
/// and closed when the call ends.
///
/// Rules of the file:
/// - one `NSLock` inside the object; every method is one critical section; nothing suspends and nothing is called out under it
///   (no closure parameter, no callback); a method returns a value and the caller reacts after every lock is released;
/// - lock order: integration `offerInstallLock` -> integration `lock` -> `LiveCallCrypto.lock` -> `ChainLease.lock`, never the
///   reverse;
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
        /// OUR round-1 bundle's capabilities as sent: every later round of the call carries the same ones.
        public let ownCapabilities: AndroidHandshakeBundle.Capabilities
        public let ownTag: Bool
        public let peerTag: Bool
        public let selfIsCaller: Bool

        public var anyS8bTag: Bool { rekeyChainV1 || frameKeyV6 }

        public init(ext: Bool, rekeyChainV1: Bool, frameKeyV6: Bool, ownCapabilities: AndroidHandshakeBundle.Capabilities,
                    ownTag: Bool, peerTag: Bool, selfIsCaller: Bool) {
            self.ext = ext
            self.rekeyChainV1 = rekeyChainV1
            self.frameKeyV6 = frameKeyV6
            self.ownCapabilities = ownCapabilities
            self.ownTag = ownTag
            self.peerTag = peerTag
            self.selfIsCaller = selfIsCaller
        }

        /// From the analyses of the two round-1 bundles (the bytes this side sent and the bytes it received).
        public static func negotiate(
            own: BundleCapsBind, peer: BundleCapsBind, ownCapabilities: AndroidHandshakeBundle.Capabilities, selfIsCaller: Bool
        ) -> Features {
            Features(
                ext: CapsBind.isActive(own: own, peer: peer),
                rekeyChainV1: CapsBind.negotiateS8b(own: own, peer: peer, tag: "rekeyChainV1"),
                frameKeyV6: CapsBind.negotiateS8b(own: own, peer: peer, tag: "frameKeyV6"),
                ownCapabilities: ownCapabilities, ownTag: own.hasTag, peerTag: peer.hasTag, selfIsCaller: selfIsCaller)
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
    private var deferred: DeferKind?
    private var closed = false

    private init(callId: String, role: Role, features: Features) {
        self.gen = Self.nextGen()
        self.callId = callId
        self.callIdL = RekeyChain.asciiLower(callId)
        self.role = role
        self.features = features
    }

    /// Creates the object and stages round 0 with the round-1 session key. nil when the chain key of round 0 cannot be derived.
    static func adopt(callId: String, role: Role, features: Features, sessionKey: Data) -> LiveCallCrypto? {
        let object = LiveCallCrypto(callId: callId, role: role, features: features)
        var ck: ChainKeyBuffer?
        if features.rekeyChainV1 {
            guard let derived = RekeyChain.deriveChainKey(sessionKey: sessionKey, callIdL: object.callIdL, epoch: 0) else { return nil }
            ck = ChainKeyBuffer(copying: derived)
        }
        object.rounds = [RoundRecord(epoch: 0, confirmed: false, ck: ck)]
        object.maxStagedE = 0
        object.maxAdmittedE = 0
        return object
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
            maxAdmittedE: maxAdmittedE, maxStagedE: maxStagedE, closed: closed)
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
                if offerSigOk { chainRefusal = epoch }
                return .refused(why)
            case .ignored:
                break
            case .accept(let base):
                guard let copy = rounds.first(where: { $0.epoch == base })?.ck?.duplicate() else {
                    if offerSigOk { chainRefusal = epoch }
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
        lock.lock()
        defer { lock.unlock() }
        if closed {
            return .closed
        }
        if rounds.contains(where: { $0.epoch == epoch }) {
            consumeLocked(handle)
            return .alreadyStaged
        }
        if ours, features.anyS8bTag {
            if epoch <= maxStagedE { return .staleEpoch }
            if undecidedLocked() >= Self.maxUndecided { return .pendingFull }
        }
        var ck: ChainKeyBuffer?
        if features.rekeyChainV1 {
            guard let derived = RekeyChain.deriveChainKey(sessionKey: sessionKey, callIdL: callIdL, epoch: epoch) else {
                consumeLocked(handle)
                return .closed
            }
            ck = ChainKeyBuffer(copying: derived)
        }
        rounds.append(RoundRecord(epoch: epoch, confirmed: false, ck: ck))
        maxStagedE = max(maxStagedE, epoch)
        if ours, var current = own, current.epoch == epoch {
            current.phase = .staged
            own = current
        }
        consumeLocked(handle)
        return .staged
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
        retainLocked()
        return ConfirmResult(alreadyConfirmed: false, rearm: takeRearmLocked())
    }

    /// The key confirmation of the round failed or ended without a verdict: its chain key is wiped at once.
    public func failRound(epoch: Int32) -> DeferKind? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        if let index = rounds.firstIndex(where: { $0.epoch == epoch && !$0.confirmed }) {
            rounds[index].ck?.wipe()
            rounds.remove(at: index)
        }
        if let current = own, current.epoch == epoch {
            current.lease?.close()
            own = nil
        }
        return takeRearmLocked()
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
        for index in rounds.indices {
            rounds[index].ck?.wipe()
            rounds[index].ck = nil
        }
        rounds.removeAll()
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

    /// Whether the chain key of a round is held and wiped (nil: no such round).
    func chainKeyWipedForTesting(epoch: Int32) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = rounds.first(where: { $0.epoch == epoch }) else { return nil }
        return record.ck?.isWipedForTesting ?? true
    }
}

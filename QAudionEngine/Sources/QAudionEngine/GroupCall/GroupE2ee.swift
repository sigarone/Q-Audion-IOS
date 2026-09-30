import Foundation

/// Group calls v2 (spec §5) — content E2EE bookkeeping. Every member M
/// generates a FRESH random 32-byte media key K[M,E] on every epoch E (no
/// derivation from earlier keys, no seed, no chain), hands it to every other
/// current member over the pairwise sealed control channel, and encrypts its
/// own frames with it. qjanus never sees a key. Frame crypto itself is the
/// native FrameCryptor (same frame format as 1:1); this file is everything
/// around it and is pure, so the protocol is pinned by `GroupE2eeTests`.
public enum GroupE2ee {
    /// Key ring size of the native key provider; keyIndex = epoch mod 16.
    public static let keyRingSize: UInt32 = 16
    public static let keyLength = 32

    public static func keyIndex(forEpoch epoch: UInt32) -> Int32 {
        Int32(epoch % keyRingSize)
    }

    /// True while `epoch` still has its ring slot: the ring holds the newest 16
    /// epochs, an older one has been overwritten. Overflow-safe.
    public static func withinRing(_ epoch: UInt32, newest: UInt32) -> Bool {
        newest < epoch || newest - epoch < keyRingSize
    }

    /// 32 bytes from the system CSPRNG.
    public static func randomKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: keyLength)
        for i in 0..<keyLength { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        let key = Data(bytes)
        // The intermediate array is a second copy of the key: scrub it (spec §12.11).
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { GroupKeyBuffer.zero(base, count: raw.count) }
        }
        return key
    }
}

/// Group calls v2 (spec §12.3) — which wire formats may carry a `qa_grpcall_ctrl`
/// envelope. Group control is SERVICE traffic on the pairwise CONTROL channel:
/// the only accepted frame is a v5 CONTROL frame (0xE6); the other accepted
/// route, the self-authenticating `qa_kms` pre-bootstrap envelope, is decoded
/// elsewhere and never reaches this check. The v4 / v3 / v2 / v1 message-crypto
/// formats and the PSK-candidate fallbacks of the pre-v2 channel are gone: a
/// frame in any of them is refused, never tried against a stored key.
public enum GroupControlChannelPolicy {

    /// True only for a v5 (0xE6) frame.
    public static func accepts(wire: Data) -> Bool {
        MessageWireFormat.detect(wire) == .v5
    }

    /// Telemetry reason of a refused frame (a closed set, never wire bytes).
    public static func rejectionReason(for wire: Data) -> String {
        switch MessageWireFormat.detect(wire) {
        case .v5: return "accepted"
        case .v4: return "v4_wire_refused"
        case .v3: return "v3_wire_refused"
        case .v2: return "v2_wire_refused"
        case .v1: return "legacy_wire_refused"
        }
    }
}

// MARK: - Envelopes (qa_grp:2)

/// `{"qa_grp":2,"t":"media_key","g":<call_id>,"e":<E>,"k":<E mod 16>,"p":"<sender pseudonym>","key":"<b64 32 bytes>"}`
/// `{"qa_grp":2,"t":"media_key_nack","g":<call_id>,"e":<E>}`   ("please resend", no key)
/// `{"qa_grp":2,"t":"media_key_ack","g":<call_id>,"e":<E>}`
///
/// `p` (spec §12.5) is the SENDER's own pseudonym: the receiver refuses the key
/// unless it equals the pseudonym the roster assigns to the authenticated
/// sender, so a member can never install a key under somebody else's pseudonym.
public enum GroupKeyEnvelope: Equatable, Sendable {
    case mediaKey(callId: String, epoch: UInt32, index: Int32, key: Data, pseudonym: String)
    case nack(callId: String, epoch: UInt32)
    case ack(callId: String, epoch: UInt32)

    public enum ParseResult: Equatable, Sendable {
        case envelope(GroupKeyEnvelope)
        /// Valid JSON that is not a `qa_grp:2` envelope (a removed v1 envelope
        /// lands here too, nothing tolerates it any more).
        case notV2
        case malformed(String)
    }

    public var callId: String {
        switch self {
        case .mediaKey(let callId, _, _, _, _), .nack(let callId, _), .ack(let callId, _): return callId
        }
    }

    public var epoch: UInt32 {
        switch self {
        case .mediaKey(_, let epoch, _, _, _), .nack(_, let epoch), .ack(_, let epoch): return epoch
        }
    }

    public static func parse(json: String) -> ParseResult {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return .malformed("not_json")
        }
        guard (object["qa_grp"] as? NSNumber)?.intValue == 2 else { return .notV2 }
        guard let type = object["t"] as? String else { return .malformed("no_type") }
        guard let callId = object["g"] as? String, !callId.isEmpty else { return .malformed("no_call_id") }
        guard let epochNumber = object["e"] as? NSNumber else { return .malformed("no_epoch") }
        let epochValue = epochNumber.int64Value
        guard epochValue >= 0, epochValue <= Int64(UInt32.max) else { return .malformed("bad_epoch") }
        let epoch = UInt32(epochValue)
        switch type {
        case "media_key":
            guard let indexNumber = object["k"] as? NSNumber,
                  indexNumber.int64Value == Int64(GroupE2ee.keyIndex(forEpoch: epoch)) else {
                return .malformed("bad_index")
            }
            guard let pseudonym = object["p"] as? String, GroupCallWire.isHex128(pseudonym) else {
                return .malformed("bad_pseudonym")
            }
            guard let encoded = object["key"] as? String,
                  let key = Data(base64Encoded: encoded), key.count == GroupE2ee.keyLength else {
                return .malformed("bad_key")
            }
            return .envelope(.mediaKey(callId: callId, epoch: epoch, index: GroupE2ee.keyIndex(forEpoch: epoch),
                                       key: key, pseudonym: pseudonym))
        case "media_key_nack":
            return .envelope(.nack(callId: callId, epoch: epoch))
        case "media_key_ack":
            return .envelope(.ack(callId: callId, epoch: epoch))
        default:
            return .malformed("unknown_type")
        }
    }

    public func encode() -> String? {
        var object: [String: Any] = ["qa_grp": 2, "g": callId, "e": Int(epoch)]
        switch self {
        case .mediaKey(_, _, let index, let key, let pseudonym):
            object["t"] = "media_key"
            object["k"] = Int(index)
            object["p"] = pseudonym
            object["key"] = key.base64EncodedString()
        case .nack:
            object["t"] = "media_key_nack"
        case .ack:
            object["t"] = "media_key_ack"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Coordinator

public protocol GroupE2eeTimer: AnyObject {
    func cancel()
}

/// Everything the coordinator needs from the outside. All calls, and the
/// `completion` of `sendControl`, happen on the owner's serial queue.
public protocol GroupE2eeEnvironment: AnyObject {
    func randomKey() -> Data
    /// Installs `key` at ring slot `index` for `participantId` (a pseudonym).
    /// Also how a slot is RETIRED: it is overwritten with a fresh random key.
    func installKey(_ key: Data, index: Int32, participantId: String)
    /// Points our own sender cryptors at ring slot `index`.
    func setSendKeyIndex(_ index: Int32)
    /// Forces a video key frame on the publisher.
    func requestKeyFrame()
    func sendControl(to userId: String, envelopeJson: String, completion: @escaping (Bool) -> Void)
    func nowMs() -> Int64
    func schedule(afterMs: Int64, _ block: @escaping () -> Void) -> GroupE2eeTimer
    func emit(_ event: GroupTelemetryEvent)
}

/// Epoch / key-distribution state machine (spec §5.1 - §5.4, §12.5 - §12.7).
///
///  * On every epoch bump (the server bumps on join, leave, drop, kick and every
///    30 minutes without a roster change) it generates K[self,E], installs it
///    for our own pseudonym, sends it to every OTHER current member and switches
///    our send index to E mod 16 once all members acked or after 1500 ms,
///    whichever comes first, then forces a key frame.
///  * Receivers install K[M,E] the moment it arrives at slot E mod 16 for M's
///    pseudonym and ack it. A key whose epoch is older than ours is refused, and
///    so is a key whose `p` is not the pseudonym the roster gives its sender.
///  * 10 s after a sender switched to a newer epoch, its older ring slots are
///    overwritten with random bytes (receivers), and the sender wipes its own
///    older keys: a key that leaks later opens nothing that is still in flight.
///  * A frame with a missing key triggers `media_key_nack` (at most 4, every
///    2 s per member); we answer at most 4 nacks per requester per epoch, and a
///    nack that is ahead of our roster is not answered until the roster update
///    arrives (which distributes our key of that epoch to every member).
///  * Every key held here lives in a `GroupKeyBuffer` that is zeroed when the key
///    is retired, replaced, dropped or the call ends.
///
/// Not thread-safe: the owner serialises every call.
public final class GroupE2eeCoordinator {

    public struct Config: Sendable {
        public var ackWaitMs: Int64 = 1_500
        public var nackMaxAttempts = 4
        public var nackIntervalMs: Int64 = 2_000
        /// Delays before re-sending a key whose control send failed.
        public var sendRetryDelaysMs: [Int64] = [1_000, 2_000, 4_000]
        public var pendingLimit = 32
        public var pendingTtlMs: Int64 = 10_000
        /// A member cannot make us re-send the same key more often than this.
        public var resendMinIntervalMs: Int64 = 500
        /// Spec §12.6: how long after a sender's switch to a newer epoch its older
        /// ring slots are overwritten (receivers) / our own older keys are wiped.
        public var retireDelayMs: Int64 = 10_000
        /// Spec §12.7: nacks answered per requester per epoch.
        public var nackAnswerMax = 4

        public init() {}
    }

    private struct PendingKey {
        let user: String
        let epoch: UInt32
        let key: GroupKeyBuffer
        /// The `p` the envelope claimed, checked against the roster once known.
        let claimedPseudonym: String
        let atMs: Int64
    }

    public let callId: String
    public let selfUserId: String
    public let config: Config
    private let env: GroupE2eeEnvironment

    /// Current epoch (0 until the first roster update).
    public private(set) var epoch: UInt32 = 0
    /// Epoch whose key our sender currently encrypts with (0 = none yet).
    public private(set) var sendingEpoch: UInt32 = 0

    private var members: [String] = []
    private var pseudonyms: [String: String] = [:]
    private var ownKeys: [UInt32: GroupKeyBuffer] = [:]
    private var installed: [String: [UInt32: GroupKeyBuffer]] = [:]
    private var awaitingAcks: Set<String> = []
    private var switchTimer: GroupE2eeTimer?
    private var ownRetireTimer: GroupE2eeTimer?
    private var retireTimers: [String: GroupE2eeTimer] = [:]
    private var pending: [PendingKey] = []
    private var nackState: [String: (attempts: Int, lastMs: Int64)] = [:]
    private var lastResendMs: [String: Int64] = [:]
    /// Nacks answered so far, per "requester|epoch" (spec §12.7).
    private var nackAnswers: [String: Int] = [:]
    private var stopped = false

    public init(callId: String, selfUserId: String, environment: GroupE2eeEnvironment, config: Config = Config()) {
        self.callId = callId
        self.selfUserId = selfUserId
        self.env = environment
        self.config = config
    }

    // MARK: Test seams

    /// The key buffers held right now (tests check that retired ones are wiped).
    var heldOwnKeys: [UInt32: GroupKeyBuffer] { ownKeys }
    func heldKeys(of user: String) -> [UInt32: GroupKeyBuffer] { installed[user] ?? [:] }
    var heldPendingKeys: [GroupKeyBuffer] { pending.map { $0.key } }

    // MARK: Server roster

    /// A `group_call_update`: the roster, the pseudonym map and the epoch.
    public func onRoster(epoch newEpoch: UInt32, members newMembers: [String], pseudonyms newPseudonyms: [String: String]) {
        guard !stopped else { return }
        guard newEpoch >= epoch else { return }
        members = newMembers
        pseudonyms = newPseudonyms
        let departed = Set(installed.keys).subtracting(newMembers)
        for user in departed {
            if let perUser = installed[user] { for key in perUser.values { key.wipe() } }
            installed[user] = nil
            retireTimers[user]?.cancel()
            retireTimers[user] = nil
            nackState[user] = nil
            lastResendMs = lastResendMs.filter { !$0.key.hasPrefix("\(user)|") }
            nackAnswers = nackAnswers.filter { !$0.key.hasPrefix("\(user)|") }
        }
        awaitingAcks.formIntersection(newMembers)
        if newEpoch > epoch {
            epoch = newEpoch
            switchTimer?.cancel()
            switchTimer = nil
            awaitingAcks = []
            // "max 4 nacks every 2 s" is per missing (member, epoch): the budget
            // spent on an older epoch must not silence the nack for this one.
            nackState.removeAll()
            nackAnswers.removeAll()
            lastResendMs.removeAll()
        }
        distributeOwnKeyIfNeeded()
        // Everyone still awaited left the call: nobody is left to wait for.
        if newEpoch == epoch, awaitingAcks.isEmpty, ownKeys[epoch] != nil { switchSendIndex() }
        flushPending()
    }

    // MARK: Control envelopes

    public func onEnvelope(_ envelope: GroupKeyEnvelope, from user: String) {
        guard !stopped, user != selfUserId, envelope.callId == callId else { return }
        switch envelope {
        case .mediaKey(_, let keyEpoch, let index, let key, let claimedPseudonym):
            // A key older than our epoch is stale (replay, or a slow member).
            guard keyEpoch >= epoch, let buffer = GroupKeyBuffer(key) else { return }
            receiveKey(from: user, epoch: keyEpoch, index: index, key: buffer, claimedPseudonym: claimedPseudonym)
        case .ack(_, let ackEpoch):
            guard ackEpoch == epoch else { return }
            awaitingAcks.remove(user)
            if awaitingAcks.isEmpty { switchSendIndex() }
        case .nack(_, let nackEpoch):
            // A nack for an epoch NEWER than ours means the requester's roster is
            // ahead of ours (spec §12.7): nothing is answered until our own update
            // arrives, and that update's distribution sends our key of the new epoch
            // to every member, the requester included. An older epoch is never
            // answered either (see `answerNack`).
            answerNack(from: user, epoch: nackEpoch)
        }
    }

    /// The native FrameCryptor of the receiver of `pseudonym` reported a
    /// missing key.
    public func onMissingKey(pseudonym: String) {
        guard !stopped, let user = pseudonyms.first(where: { $0.value == pseudonym })?.key, user != selfUserId else { return }
        env.emit(GroupTelemetry.e2ee(.missingKey, epoch: epoch))
        let now = env.nowMs()
        let state = nackState[user] ?? (attempts: 0, lastMs: Int64.min / 4)
        guard state.attempts < config.nackMaxAttempts, now - state.lastMs >= config.nackIntervalMs else { return }
        nackState[user] = (attempts: state.attempts + 1, lastMs: now)
        env.emit(GroupTelemetry.e2ee(.nack, epoch: epoch))
        send(.nack(callId: callId, epoch: epoch), to: user)
    }

    public func onDecryptFailure(pseudonym: String) {
        guard !stopped else { return }
        env.emit(GroupTelemetry.e2ee(.decryptFail, epoch: epoch))
    }

    public func stop() {
        stopped = true
        switchTimer?.cancel()
        switchTimer = nil
        ownRetireTimer?.cancel()
        ownRetireTimer = nil
        for timer in retireTimers.values { timer.cancel() }
        retireTimers.removeAll()
        for key in ownKeys.values { key.wipe() }
        ownKeys.removeAll()
        for perUser in installed.values { for key in perUser.values { key.wipe() } }
        installed.removeAll()
        for entry in pending { entry.key.wipe() }
        pending.removeAll()
        awaitingAcks.removeAll()
        nackState.removeAll()
        nackAnswers.removeAll()
    }

    // MARK: - Internals

    /// Generates, installs and sends our key of the current epoch, unless it
    /// exists.
    private func distributeOwnKeyIfNeeded() {
        guard epoch > 0, ownKeys[epoch] == nil, let selfPseudonym = pseudonyms[selfUserId] else { return }
        guard let key = GroupKeyBuffer(env.randomKey()) else { return }
        ownKeys[epoch] = key
        for (keyEpoch, stored) in ownKeys where !GroupE2ee.withinRing(keyEpoch, newest: epoch) { stored.wipe() }
        ownKeys = ownKeys.filter { GroupE2ee.withinRing($0.key, newest: epoch) }
        env.installKey(key.data, index: GroupE2ee.keyIndex(forEpoch: epoch), participantId: selfPseudonym)
        let recipients = members.filter { $0 != selfUserId }
        awaitingAcks = Set(recipients)
        for user in recipients { sendKey(to: user, epoch: epoch, attempt: 0) }
        env.emit(GroupTelemetry.e2ee(.keySent, epoch: epoch))
        if recipients.isEmpty {
            switchSendIndex()
        } else {
            let target = epoch
            switchTimer = env.schedule(afterMs: config.ackWaitMs) { [weak self] in
                guard let self = self, self.epoch == target else { return }
                self.switchSendIndex()
            }
        }
    }

    private func switchSendIndex() {
        guard sendingEpoch != epoch, ownKeys[epoch] != nil else { return }
        switchTimer?.cancel()
        switchTimer = nil
        sendingEpoch = epoch
        env.setSendKeyIndex(GroupE2ee.keyIndex(forEpoch: epoch))
        env.requestKeyFrame()
        scheduleOwnRetire()
    }

    // MARK: Retirement (spec §12.6)

    /// Our own older keys are wiped, and their ring slots overwritten, a while
    /// after we switched to the newer one.
    private func scheduleOwnRetire() {
        ownRetireTimer?.cancel()
        ownRetireTimer = env.schedule(afterMs: config.retireDelayMs) { [weak self] in
            self?.retireOwnOlderKeys()
        }
    }

    private func retireOwnOlderKeys() {
        ownRetireTimer = nil
        guard !stopped, let selfPseudonym = pseudonyms[selfUserId] else { return }
        for (keyEpoch, key) in ownKeys where keyEpoch < sendingEpoch {
            env.installKey(env.randomKey(), index: GroupE2ee.keyIndex(forEpoch: keyEpoch), participantId: selfPseudonym)
            key.wipe()
            ownKeys[keyEpoch] = nil
        }
    }

    /// A member's superseded ring slots are overwritten with random bytes a
    /// while after its newest key arrived (it switches to it within 1.5 s).
    private func scheduleRetire(of user: String) {
        retireTimers[user]?.cancel()
        retireTimers[user] = env.schedule(afterMs: config.retireDelayMs) { [weak self] in
            self?.retireOlderKeys(of: user)
        }
    }

    private func retireOlderKeys(of user: String) {
        retireTimers[user] = nil
        guard !stopped, let pseudonym = pseudonyms[user], var perUser = installed[user],
              let newest = perUser.keys.max() else { return }
        for (keyEpoch, key) in perUser where keyEpoch < newest {
            env.installKey(env.randomKey(), index: GroupE2ee.keyIndex(forEpoch: keyEpoch), participantId: pseudonym)
            key.wipe()
            perUser[keyEpoch] = nil
        }
        installed[user] = perUser
    }

    // MARK: Sending

    private func sendKey(to user: String, epoch keyEpoch: UInt32, attempt: Int) {
        guard let key = ownKeys[keyEpoch], let selfPseudonym = pseudonyms[selfUserId] else { return }
        let envelope = GroupKeyEnvelope.mediaKey(callId: callId, epoch: keyEpoch,
                                                 index: GroupE2ee.keyIndex(forEpoch: keyEpoch),
                                                 key: key.data, pseudonym: selfPseudonym)
        guard let json = envelope.encode() else { return }
        env.sendControl(to: user, envelopeJson: json) { [weak self] ok in
            guard let self = self, !ok, !self.stopped else { return }
            guard attempt < self.config.sendRetryDelaysMs.count,
                  keyEpoch == self.epoch, self.members.contains(user) else { return }
            _ = self.env.schedule(afterMs: self.config.sendRetryDelaysMs[attempt]) { [weak self] in
                guard let self = self, !self.stopped, keyEpoch == self.epoch, self.members.contains(user) else { return }
                self.sendKey(to: user, epoch: keyEpoch, attempt: attempt + 1)
            }
        }
    }

    private func send(_ envelope: GroupKeyEnvelope, to user: String) {
        guard let json = envelope.encode() else { return }
        env.sendControl(to: user, envelopeJson: json) { _ in }
    }

    // MARK: Nacks (spec §12.7)

    /// Re-sends our key of the current epoch to a member that asked for it, at
    /// most `nackAnswerMax` times per requester and epoch.
    private func answerNack(from user: String, epoch nackEpoch: UInt32) {
        // Only the CURRENT epoch's key is ever re-sent: an older one may predate
        // the requester's join, and a joiner must never get an epoch before its
        // own (backward secrecy, spec 5.2).
        guard nackEpoch == epoch, members.contains(user), ownKeys[nackEpoch] != nil else { return }
        let budgetKey = "\(user)|\(nackEpoch)"
        guard (nackAnswers[budgetKey] ?? 0) < config.nackAnswerMax else { return }
        let now = env.nowMs()
        if let last = lastResendMs[budgetKey], now - last < config.resendMinIntervalMs { return }
        lastResendMs[budgetKey] = now
        nackAnswers[budgetKey] = (nackAnswers[budgetKey] ?? 0) + 1
        env.emit(GroupTelemetry.e2ee(.nack, epoch: nackEpoch))
        sendKey(to: user, epoch: nackEpoch, attempt: 0)
    }

    // MARK: Receiving

    private func receiveKey(from user: String, epoch keyEpoch: UInt32, index: Int32, key: GroupKeyBuffer,
                            claimedPseudonym: String) {
        guard let pseudonym = pseudonyms[user], members.contains(user) else {
            // The roster update that introduces this member may still be on its
            // way (two independent channels): hold the key for a while.
            let now = env.nowMs()
            removePending { now - $0.atMs > config.pendingTtlMs || ($0.user == user && $0.epoch == keyEpoch) }
            if pending.count >= config.pendingLimit { pending.removeFirst().key.wipe() }
            pending.append(PendingKey(user: user, epoch: keyEpoch, key: key, claimedPseudonym: claimedPseudonym, atMs: now))
            return
        }
        // Spec §12.5: the envelope must name the pseudonym the roster assigns to
        // the authenticated sender, else it is refused (no install, no ack).
        guard claimedPseudonym == pseudonym else {
            key.wipe()
            return
        }
        if let existing = installed[user]?[keyEpoch] {
            // A retransmission of the very same key is acked again; a
            // different key for the same (member, epoch) is never accepted.
            if existing.matches(key) { send(.ack(callId: callId, epoch: keyEpoch), to: user) }
            key.wipe()
            return
        }
        env.installKey(key.data, index: index, participantId: pseudonym)
        var perUser = installed[user] ?? [:]
        perUser[keyEpoch] = key
        let newest = perUser.keys.max() ?? keyEpoch
        for (storedEpoch, stored) in perUser where !GroupE2ee.withinRing(storedEpoch, newest: newest) { stored.wipe() }
        perUser = perUser.filter { GroupE2ee.withinRing($0.key, newest: newest) }
        installed[user] = perUser
        nackState[user] = nil
        scheduleRetire(of: user)
        env.emit(GroupTelemetry.e2ee(.keyInstalled, epoch: keyEpoch))
        send(.ack(callId: callId, epoch: keyEpoch), to: user)
    }

    /// Drops the held keys `shouldRemove` selects, zeroing them.
    private func removePending(where shouldRemove: (PendingKey) -> Bool) {
        var kept: [PendingKey] = []
        for entry in pending {
            if shouldRemove(entry) { entry.key.wipe() } else { kept.append(entry) }
        }
        pending = kept
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let now = env.nowMs()
        let held = pending
        pending = []
        for entry in held {
            guard now - entry.atMs <= config.pendingTtlMs, entry.epoch >= epoch else {
                entry.key.wipe()
                continue
            }
            receiveKey(from: entry.user, epoch: entry.epoch,
                       index: GroupE2ee.keyIndex(forEpoch: entry.epoch), key: entry.key,
                       claimedPseudonym: entry.claimedPseudonym)
        }
    }
}

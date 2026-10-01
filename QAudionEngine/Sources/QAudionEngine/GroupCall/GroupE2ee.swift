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
///    whichever comes first, then forces a key frame. Every epoch has its own
///    pending switch and timer: a newer epoch never cancels an older, still valid
///    one (epochs that bump faster than the 1.5 s window would otherwise keep the
///    send slot where it was until the churn stops, and everyone who joined in
///    between would hear nothing). Only a LEAVE discards the older pending
///    switches: they would move the send slot to a key the leaver holds.
///  * Receivers install K[M,E] the moment it arrives at slot E mod 16 for M's
///    pseudonym and ack it. A key whose epoch is older than ours is refused, and
///    so is a key whose `p` is not the pseudonym the roster gives its sender. A
///    different key for a (member, epoch) already held REPLACES it (a member that
///    restarted inside the server's ghost grace re-joins without an epoch bump and
///    draws a new key for the same epoch), unless the epoch is older than the
///    newest one held for that member (its slot may already be retired).
///  * 10 s after a sender switched to a newer epoch, its older ring slots are
///    overwritten with random bytes (receivers), and the sender wipes its own
///    older keys: a key that leaks later opens nothing that is still in flight.
///  * A frame with a missing key triggers `media_key_nack` (at most 4, every
///    2 s per member). The native cryptor reports MISSING_KEY once per episode, so
///    the first nack goes out at once and a timer repeats it while the key is
///    still missing (a nack or its answer lost on the way is asked for again; a
///    report that came before the roster named the sender is acted on as soon as
///    it does). A run of DECRYPTION_FAILED that lasts longer than a second (a
///    stale key in the slot the sender switched to) asks the same way for the
///    CURRENT epoch, out of the same budget. We answer at most 4 nacks per
///    requester per epoch, and a nack that is ahead of our roster is not answered
///    until the roster update arrives (which distributes our key of that epoch to
///    every member).
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
        /// A run of DECRYPTION_FAILED of one sender must outlast this before it is nacked: one
        /// report proves little (the sender may still be on the previous epoch's slot).
        public var decryptNackAfterMs: Int64 = 1_000
        /// A missing-key watch that finds nothing to do (the sender is not nameable yet, or
        /// the key of the current epoch is already installed) gives up after this many ticks.
        public var missingWatchIdleTicks = 8

        public init() {}
    }

    private struct PendingSwitch {
        /// Members whose ack of this epoch's key is still awaited.
        var awaiting: Set<String>
        var timer: GroupE2eeTimer?
    }

    /// A run of DECRYPTION_FAILED of one sender, opened under `epoch`.
    private struct DecryptRun {
        var epoch: UInt32
        var sinceMs: Int64
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
    /// Epochs whose send-slot switch still waits for its acks or its timer.
    private var pendingSwitches: [UInt32: PendingSwitch] = [:]
    /// pseudonym -> the timer that keeps asking for its key while the cryptor lacks it.
    private var missingWatches: [String: GroupE2eeTimer] = [:]
    private var missingIdleTicks: [String: Int] = [:]
    /// user -> the failing run, and the timer that turns a long one into nacks.
    private var decryptRuns: [String: DecryptRun] = [:]
    private var decryptTimers: [String: GroupE2eeTimer] = [:]
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
        let someoneLeft = !Set(members).subtracting(newMembers).isEmpty
        members = newMembers
        pseudonyms = newPseudonyms
        let departed = Set(installed.keys).subtracting(newMembers)
        for user in departed {
            if let perUser = installed[user] { for key in perUser.values { key.wipe() } }
            installed[user] = nil
            retireTimers[user]?.cancel()
            retireTimers[user] = nil
            nackState[user] = nil
            endDecryptRun(of: user)
            lastResendMs = lastResendMs.filter { !$0.key.hasPrefix("\(user)|") }
            nackAnswers = nackAnswers.filter { !$0.key.hasPrefix("\(user)|") }
        }
        if someoneLeft {
            // The older keys went to the leaver too: a switch to one of them is pointless,
            // the roster that carries the departure starts a newer epoch. A join-only bump
            // never discards anything.
            for pendingEpoch in Array(pendingSwitches.keys) where pendingEpoch < newEpoch { dropPendingSwitch(pendingEpoch) }
        }
        for pendingEpoch in Array(pendingSwitches.keys) { pendingSwitches[pendingEpoch]?.awaiting.formIntersection(newMembers) }
        if newEpoch > epoch {
            epoch = newEpoch
            // "max 4 nacks every 2 s" is per missing (member, epoch): the budget
            // spent on an older epoch must not silence the nack for this one.
            nackState.removeAll()
            nackAnswers.removeAll()
            lastResendMs.removeAll()
        }
        distributeOwnKeyIfNeeded()
        // Everyone still awaited left the call: nobody is left to wait for.
        let settled = pendingSwitches.filter { $0.value.awaiting.isEmpty }.keys.max()
        if let target = settled { switchSendIndex(to: target) }
        flushPending()
    }

    private func dropPendingSwitch(_ target: UInt32) {
        pendingSwitches[target]?.timer?.cancel()
        pendingSwitches[target] = nil
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
            // Only an epoch whose switch is still pending counts (a stale, future or
            // already switched one changes nothing).
            guard var awaited = pendingSwitches[ackEpoch] else { return }
            awaited.awaiting.remove(user)
            pendingSwitches[ackEpoch] = awaited
            if awaited.awaiting.isEmpty { switchSendIndex(to: ackEpoch) }
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
        guard !stopped else { return }
        env.emit(GroupTelemetry.e2ee(.missingKey, epoch: epoch))
        missingKeyStep(pseudonym: pseudonym, fromTimer: false)
    }

    /// One look at a sender whose key the cryptor lacks: sends the nack the budget and the
    /// spacing allow, and keeps (or starts) the timer that looks again while it makes sense.
    private func missingKeyStep(pseudonym: String, fromTimer: Bool) {
        guard let user = pseudonyms.first(where: { $0.value == pseudonym })?.key else {
            // Not nameable yet (the roster has not arrived): nothing to ask for, look again.
            keepWatchingMissingKey(pseudonym: pseudonym, idle: true, fromTimer: fromTimer)
            return
        }
        guard user != selfUserId, members.contains(user), epoch > 0 else {
            if user == selfUserId || !members.contains(user) {
                stopWatchingMissingKey(pseudonym: pseudonym)
            } else {
                keepWatchingMissingKey(pseudonym: pseudonym, idle: true, fromTimer: fromTimer)
            }
            return
        }
        // The key of the current epoch is here: the sender is ahead of us (its frames use
        // a slot we hold no key for yet), nothing a nack for OUR epoch could fix.
        if (installed[user]?.keys.max() ?? 0) >= epoch {
            stopWatchingMissingKey(pseudonym: pseudonym)
            return
        }
        let now = env.nowMs()
        let state = nackState[user] ?? (attempts: 0, lastMs: Int64.min / 4)
        if state.attempts >= config.nackMaxAttempts {
            stopWatchingMissingKey(pseudonym: pseudonym)
            return
        }
        guard now - state.lastMs >= config.nackIntervalMs else {
            keepWatchingMissingKey(pseudonym: pseudonym, idle: false, fromTimer: fromTimer)
            return
        }
        nackState[user] = (attempts: state.attempts + 1, lastMs: now)
        env.emit(GroupTelemetry.e2ee(.nack, epoch: epoch))
        send(.nack(callId: callId, epoch: epoch), to: user)
        if state.attempts + 1 < config.nackMaxAttempts {
            keepWatchingMissingKey(pseudonym: pseudonym, idle: false, fromTimer: fromTimer)
        } else {
            stopWatchingMissingKey(pseudonym: pseudonym)
        }
    }

    private func keepWatchingMissingKey(pseudonym: String, idle: Bool, fromTimer: Bool) {
        if idle {
            let ticks = (missingIdleTicks[pseudonym] ?? 0) + (fromTimer ? 1 : 0)
            if ticks > config.missingWatchIdleTicks {
                stopWatchingMissingKey(pseudonym: pseudonym)
                return
            }
            missingIdleTicks[pseudonym] = ticks
        } else {
            missingIdleTicks[pseudonym] = 0
        }
        if fromTimer { missingWatches[pseudonym] = nil }
        guard missingWatches[pseudonym] == nil else { return }
        missingWatches[pseudonym] = env.schedule(afterMs: config.nackIntervalMs) { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.missingWatches[pseudonym] = nil
            self.missingKeyStep(pseudonym: pseudonym, fromTimer: true)
        }
    }

    private func stopWatchingMissingKey(pseudonym: String) {
        missingWatches[pseudonym]?.cancel()
        missingWatches[pseudonym] = nil
        missingIdleTicks[pseudonym] = nil
    }

    /// The native cryptor of `pseudonym` decrypts again: a missing-key watch and a failing
    /// run of that sender are over.
    public func onCryptorOk(pseudonym: String) {
        guard !stopped else { return }
        stopWatchingMissingKey(pseudonym: pseudonym)
        if let user = pseudonyms.first(where: { $0.value == pseudonym })?.key { endDecryptRun(of: user) }
    }

    /// The native cryptor of `pseudonym` reported DECRYPTION_FAILED. One report proves
    /// little, so it only opens a run: when the run is still open `decryptNackAfterMs`
    /// later (no OK from the cryptor, no key installed, no departure, the same epoch still
    /// current) that member is asked for the CURRENT epoch's key, out of the same budget as
    /// a missing key. A run that spans an epoch change starts over.
    public func onDecryptFailure(pseudonym: String) {
        guard !stopped else { return }
        env.emit(GroupTelemetry.e2ee(.decryptFail, epoch: epoch))
        guard let user = pseudonyms.first(where: { $0.value == pseudonym })?.key,
              user != selfUserId, members.contains(user), epoch > 0 else { return }
        if decryptRuns[user] == nil { decryptRuns[user] = DecryptRun(epoch: epoch, sinceMs: env.nowMs()) }
        if decryptTimers[user] == nil { scheduleDecryptCheck(of: user, afterMs: config.decryptNackAfterMs + 1) }
    }

    private func scheduleDecryptCheck(of user: String, afterMs: Int64) {
        decryptTimers[user] = env.schedule(afterMs: afterMs) { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.decryptTimers[user] = nil
            self.checkDecryptRun(of: user)
        }
    }

    private func endDecryptRun(of user: String) {
        decryptRuns[user] = nil
        decryptTimers[user]?.cancel()
        decryptTimers[user] = nil
    }

    private func checkDecryptRun(of user: String) {
        guard var run = decryptRuns[user], members.contains(user), epoch > 0 else {
            endDecryptRun(of: user)
            return
        }
        let now = env.nowMs()
        if run.epoch != epoch {
            // The roster moved on: the failures so far belong to the previous epoch.
            run = DecryptRun(epoch: epoch, sinceMs: now)
            decryptRuns[user] = run
            scheduleDecryptCheck(of: user, afterMs: config.decryptNackAfterMs + 1)
            return
        }
        if now - run.sinceMs <= config.decryptNackAfterMs {
            scheduleDecryptCheck(of: user, afterMs: config.decryptNackAfterMs - (now - run.sinceMs) + 1)
            return
        }
        let state = nackState[user] ?? (attempts: 0, lastMs: Int64.min / 4)
        if state.attempts >= config.nackMaxAttempts {
            endDecryptRun(of: user)
            return
        }
        if now - state.lastMs >= config.nackIntervalMs {
            nackState[user] = (attempts: state.attempts + 1, lastMs: now)
            env.emit(GroupTelemetry.e2ee(.nack, epoch: epoch))
            send(.nack(callId: callId, epoch: epoch), to: user)
            if state.attempts + 1 >= config.nackMaxAttempts {
                endDecryptRun(of: user)
                return
            }
            scheduleDecryptCheck(of: user, afterMs: config.nackIntervalMs)
        } else {
            scheduleDecryptCheck(of: user, afterMs: config.nackIntervalMs - (now - state.lastMs))
        }
    }

    public func stop() {
        stopped = true
        for pendingEpoch in Array(pendingSwitches.keys) { dropPendingSwitch(pendingEpoch) }
        for timer in missingWatches.values { timer.cancel() }
        missingWatches.removeAll()
        missingIdleTicks.removeAll()
        for timer in decryptTimers.values { timer.cancel() }
        decryptTimers.removeAll()
        decryptRuns.removeAll()
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
        let target = epoch
        // Its own pending switch, with its own timer: an earlier epoch's one is still valid.
        pendingSwitches[target] = PendingSwitch(awaiting: Set(recipients), timer: nil)
        for user in recipients { sendKey(to: user, epoch: target, attempt: 0) }
        env.emit(GroupTelemetry.e2ee(.keySent, epoch: target))
        if recipients.isEmpty {
            switchSendIndex(to: target)
        } else {
            let timer = env.schedule(afterMs: config.ackWaitMs) { [weak self] in
                self?.switchSendIndex(to: target)
            }
            pendingSwitches[target]?.timer = timer
        }
    }

    /// Moves our send slot to `target` (acked by everyone, or the wait is over). Switching
    /// makes every older pending switch moot: the send slot never moves backwards.
    private func switchSendIndex(to target: UInt32) {
        guard !stopped, pendingSwitches[target] != nil else { return }
        guard target > sendingEpoch, ownKeys[target] != nil else {
            dropPendingSwitch(target)
            return
        }
        for pendingEpoch in Array(pendingSwitches.keys) where pendingEpoch <= target { dropPendingSwitch(pendingEpoch) }
        sendingEpoch = target
        env.setSendKeyIndex(GroupE2ee.keyIndex(forEpoch: target))
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
        let newestHeld = installed[user]?.keys.max()
        if let existing = installed[user]?[keyEpoch] {
            // A retransmission of the very same key is acked again.
            if existing.matches(key) {
                send(.ack(callId: callId, epoch: keyEpoch), to: user)
                key.wipe()
                return
            }
            // A DIFFERENT key for a (member, epoch) we hold: that member restarted inside the
            // server's ghost grace, re-joined without an epoch bump and drew a new key for
            // the same epoch (Android and desktop replace it as well; refusing it would leave
            // this member's media undecryptable until the next epoch). The pseudonym binding
            // and the epoch check above already authenticated the sender. Never for an epoch
            // older than the newest one held for that member: its slot may be retired.
            guard keyEpoch >= (newestHeld ?? 0) else {
                key.wipe()
                return
            }
            existing.wipe()
        } else if let newest = newestHeld, keyEpoch < newest {
            // Older than what we hold for this sender: its slot may already be retired,
            // never reopen it.
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
        stopWatchingMissingKey(pseudonym: pseudonym)
        // New key material for this sender: whatever was failing to decrypt is judged afresh.
        endDecryptRun(of: user)
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

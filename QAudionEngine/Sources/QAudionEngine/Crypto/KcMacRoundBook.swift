import Foundation

/// The per-call KCMAC book of a 1:1 call: every key round this side armed and has not decided, the peer MACs it
/// already verified, and the inbound MACs that matched no pending round (WIRE_SPEC §3.7.1, R-KCMAC-ROUNDS).
///
/// The `KCMAC:` message carries no round, so a MAC is attributed to a round by CONTENT: it is compared with the
/// expected peer MAC `HMAC-SHA256(K_kc, peerRole || kc_transcript)` of EVERY pending round, whatever order they were
/// armed in. Rules, in the order an inbound MAC meets them (`receive`):
///
/// 1. format: not exactly the 44-character canonical base64 of 33 bytes (`role || MAC[32]`): `malformed`, dropped
///    silently, never judged, never ends the call by itself;
/// 2. duplicate: equal to a MAC already verified for a decided round (a retransmission, or a re-send after a socket
///    re-authentication): dropped silently, never judged;
/// 3. attribution: equal to the expected peer MAC of a pending round R: with R's peer role byte R is verified (it
///    leaves the pending set), with any other role byte the call ends (`mismatch`);
/// 4. unattributed: not a duplicate and equal to no pending round (the peer's MAC for a round this side has not armed
///    yet, or a MAC that will never verify): held while there is room (`maxHeldMacs`), otherwise dropped silently.
///    It is never judged wrong, never ends the call and never shortens or extends a window by itself.
///
/// Arming a round (`arm`) NEVER cancels, shortens, extends or decides another pending round: a round superseded by a
/// later one stays pending, with its own window, until it is decided or its window ends (the app owns the timers).
/// The new round is inserted FIRST, then every held MAC received less than `ConfirmTimeout.earlyKcMacHoldMs` (30 s)
/// ago is offered again from step 2 with its original receipt time; an older one is dropped silently.
///
/// Atomicity (R-KCMAC-ATOMIC): the book is changed by one step at a time, in one order. A step is the whole processing
/// of ONE inbound MAC (`receive`, steps 1 to 4, including the drop of stale held MACs and the insertion into the held
/// set), the whole arming of ONE round (`arm`: overflow check, insertion, re-offer of the held MACs) or the expiry of
/// ONE round's window (`expire`: the test "still pending" and the removal are one call). Every method is one such
/// step, a mutating method of a value type; the owner (the app, on the main actor) never interleaves two of them. When
/// a decision and an expiry concern the same round, whichever step runs first wins: a round decided first never
/// expires (`expire` returns false), a round that expired first is not decided afterwards (its MAC is held, never
/// judged).
///
/// Pure value type: no clock, no timers, no I/O. Every time is monotonic milliseconds supplied by the caller. Never
/// logs and never persists a MAC.
public struct KcMacRoundBook {

    /// Most rounds pending at once; arming one more ends the call with `kcmac_mismatch` (`ArmResult.overflow`).
    public static let maxPendingRounds = 16
    /// Most inbound MACs held at once that matched no pending round.
    public static let maxHeldMacs = 8
    /// Most decided peer MACs remembered for the duplicate test (the oldest is dropped first).
    public static let maxDecidedMacs = 256
    /// Exact length of a well-formed `KCMAC:` payload: the canonical base64 of 33 bytes has no padding.
    public static let payloadCharacters = 44
    /// A held MAC is offered again at arming only if it was received less than this long ago.
    public static let heldFreshMs = ConfirmTimeout.earlyKcMacHoldMs

    /// A round armed and not decided yet.
    public struct PendingRound: Equatable {
        public let round: Int
        /// The 32-byte MAC the peer must send for this round.
        public let expectedPeerMac: Data
        /// The role byte the peer must carry for this round: `0x02` when this side is the round's init, else `0x01`.
        public let peerRole: UInt8

        public init(round: Int, expectedPeerMac: Data, peerRole: UInt8) {
            self.round = round
            self.expectedPeerMac = expectedPeerMac
            self.peerRole = peerRole
        }

        /// The pending round for the key-confirmation context of `context`.
        public init(round: Int, context: KcMacRound) {
            self.round = round
            if context.isInitiator {
                self.expectedPeerMac = KeyConfirmation.macResp(kcKey: context.kcKey, transcript: context.transcript)
                self.peerRole = 0x02
            } else {
                self.expectedPeerMac = KeyConfirmation.macInit(kcKey: context.kcKey, transcript: context.transcript)
                self.peerRole = 0x01
            }
        }
    }

    /// The verdict of a MAC that is attributed to a round.
    public enum Verdict: Equatable {
        /// The expected peer MAC with the right role byte: the round is verified.
        case verified(round: Int)
        /// The expected peer MAC with the wrong role byte: the call ends with `kcmac_mismatch`.
        case mismatch(round: Int)
    }

    /// What `receive` did with an inbound MAC.
    public enum Disposition: Equatable {
        /// Step 1: not a well-formed payload; dropped silently.
        case malformed
        /// Step 2: a copy of a MAC already verified for a decided round; dropped silently.
        case duplicate
        /// Step 3: attributed to a pending round.
        case decided(Verdict)
        /// Step 4: held until a round is armed.
        case held
        /// Step 4: no room, or a copy is already held; dropped silently.
        case heldDropped
    }

    /// What `arm` did.
    public struct ArmResult: Equatable {
        /// True when the round could not be added because `maxPendingRounds` rounds are already pending: the call
        /// ends with `kcmac_mismatch`.
        public var overflow: Bool
        /// The rounds decided by held MACs that were offered again, in the order they were held.
        public var verdicts: [Verdict]
    }

    private struct HeldMac: Equatable {
        let mac: Data
        let role: UInt8
        let atMs: Int
    }

    /// Pending rounds in arming order.
    public private(set) var pending: [PendingRound] = []
    private var decided: [Data] = []
    /// The signed rounds decided by a verified peer MAC (the same bound as `decided`): the proof of arrival that
    /// R-ACCEPT-RESEND reads for a rekey ACCEPT.
    private var decidedRoundNumbers: [Int] = []
    private var held: [HeldMac] = []

    public init() {}

    public var pendingRounds: [Int] { pending.map { $0.round } }
    public var pendingCount: Int { pending.count }
    public var heldCount: Int { held.count }
    public var decidedCount: Int { decided.count }

    public func isPending(round: Int) -> Bool {
        pending.contains(where: { $0.round == round })
    }

    /// True when the peer's MAC of `round` was verified (the round is decided).
    public func isDecided(round: Int) -> Bool {
        decidedRoundNumbers.contains(round)
    }

    /// `(role, MAC)` of a well-formed `KCMAC:` payload, `nil` otherwise: exactly 44 characters, canonical base64,
    /// 33 bytes.
    public static func parse(payload raw: String) -> (role: UInt8, mac: Data)? {
        guard raw.utf8.count == payloadCharacters,
              let bytes = Data(base64Encoded: raw),
              bytes.count == KcMacRoundRules.payloadLength,
              bytes.base64EncodedString() == raw else { return nil }
        return (role: bytes[bytes.startIndex], mac: Data(bytes.dropFirst()))
    }

    // MARK: - Arming

    /// Arm a round. A round number that is already pending is replaced (a repeated event for the same round).
    /// Returns `overflow` when a 17th distinct round would be pending, with nothing changed.
    public mutating func arm(_ round: PendingRound, nowMs: Int) -> ArmResult {
        if let index = pending.firstIndex(where: { $0.round == round.round }) {
            pending[index] = round
        } else {
            guard pending.count < Self.maxPendingRounds else {
                return ArmResult(overflow: true, verdicts: [])
            }
            pending.append(round)
        }
        // The round is in the pending set; only now are the held MACs offered again.
        let offered = held
        held = []
        var verdicts: [Verdict] = []
        for entry in offered {
            guard nowMs - entry.atMs < Self.heldFreshMs else { continue }
            switch judge(mac: entry.mac, role: entry.role) {
            case .duplicate:
                continue
            case .decided(let verdict):
                verdicts.append(verdict)
            case .unattributed:
                held.append(entry)
            }
        }
        return ArmResult(overflow: false, verdicts: verdicts)
    }

    // MARK: - Receiving

    /// Process an inbound `KCMAC:` payload (the text after the tag), after the caller's sender-device rule and the
    /// peer-user check.
    public mutating func receive(payload raw: String, nowMs: Int) -> Disposition {
        guard let parsed = Self.parse(payload: raw) else { return .malformed }
        switch judge(mac: parsed.mac, role: parsed.role) {
        case .duplicate:
            return .duplicate
        case .decided(let verdict):
            return .decided(verdict)
        case .unattributed:
            // A held MAC that is too old can never be offered again: it does not take a slot.
            held.removeAll(where: { nowMs - $0.atMs >= Self.heldFreshMs })
            if held.contains(where: { CryptoConstants.constantTimeEquals($0.mac, parsed.mac) }) {
                return .heldDropped
            }
            guard held.count < Self.maxHeldMacs else { return .heldDropped }
            held.append(HeldMac(mac: parsed.mac, role: parsed.role, atMs: nowMs))
            return .held
        }
    }

    /// The window of `round` ended: it leaves the pending set. True when it was pending (the call ends with
    /// `kcmac_mismatch`), false when it was already decided.
    @discardableResult
    public mutating func expire(round: Int) -> Bool {
        guard let index = pending.firstIndex(where: { $0.round == round }) else { return false }
        pending.remove(at: index)
        return true
    }

    // MARK: - Judgment

    private enum Judged {
        case duplicate
        case decided(Verdict)
        case unattributed
    }

    /// Steps 2 to 4 for a well-formed MAC.
    private mutating func judge(mac: Data, role: UInt8) -> Judged {
        var isDuplicate = false
        for known in decided where CryptoConstants.constantTimeEquals(known, mac) {
            isDuplicate = true
        }
        if isDuplicate { return .duplicate }

        // Compared with EVERY pending round, whatever order they were armed in.
        var matched: Int?
        for (index, candidate) in pending.enumerated()
        where CryptoConstants.constantTimeEquals(candidate.expectedPeerMac, mac) && matched == nil {
            matched = index
        }
        guard let matchIndex = matched else { return .unattributed }
        let round = pending.remove(at: matchIndex)
        guard role == round.peerRole else { return .decided(.mismatch(round: round.round)) }
        decided.append(mac)
        if decided.count > Self.maxDecidedMacs {
            decided.removeFirst(decided.count - Self.maxDecidedMacs)
        }
        decidedRoundNumbers.append(round.round)
        if decidedRoundNumbers.count > Self.maxDecidedMacs {
            decidedRoundNumbers.removeFirst(decidedRoundNumbers.count - Self.maxDecidedMacs)
        }
        return .decided(.verified(round: round.round))
    }
}

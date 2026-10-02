import Foundation

/// The ONE confirmation timeout of the 1:1 handshake (WIRE_SPEC §3.7.1 Window rule, §3.7.4, §3.8.4; T3 of the v6
/// timer round, "no legitimate call may end 5 s after the answer").
///
/// Why 15 s. Every confirmation message (the callee's REVEAL, each round's KCMAC) and the DTLS certificate read of
/// check (b) can legitimately arrive late: a signalling socket that re-authenticates, a slow first `getStats()`, a
/// callee that is still deriving keys. Ending a call on the first such delay dropped legitimate calls 5 s after the
/// answer. A later answer only lets whoever delays it end the call, which the signalling server can already do;
/// every mismatch still ends the call fail-closed and media under a wrong key never decrypts (AEAD). All values
/// are MINIMUMS ("never shorter").
///
/// This is the only definition of the value: the REVEAL timer, every round's KCMAC window, the callee's wait after
/// its own REVEAL verified and the DTLS statistics check all read it. Nothing on those paths carries another
/// number (R-CONFIRM-TIMEOUT).
public enum ConfirmTimeout {

    /// The callee's REVEAL timer, every round's KCMAC window, the callee's round-1 wait after its own REVEAL
    /// verified, and the DTLS statistics check.
    public static let confirmTimeoutMs = 15_000

    /// The caller's round-1 wait for the callee's KCMAC, from the moment its REVEAL was handed to the transport:
    /// the callee sends that MAC only after ITS REVEAL verified (up to `confirmTimeoutMs`), and then its own
    /// window applies.
    public static let callerRound1KcMacWaitMs = 2 * confirmTimeoutMs

    /// A peer KCMAC that arrives before this side's confirmation is armed is held this long (never shorter).
    public static let earlyKcMacHoldMs = 2 * confirmTimeoutMs

    /// How often check (b) reads the transport statistics again while the certificate pair is incomplete.
    public static let dtlsStatsRetryMs = 250

    /// Re-send EVENTS per call and per device (R-KCMAC-RESEND): a duplicate ACCEPT received by the caller, or a
    /// re-authentication of the device's signalling socket. First sends are not events.
    public static let maxResendEvents = 4

    /// Check (b) of the DTLS binding: true once `elapsedMs` since `connected` reached the confirmation window with
    /// no verdict (`stats_timeout`: unverified, not proven benign, fail closed).
    public static func dtlsStatsWaitExpired(elapsedMs: Int) -> Bool {
        elapsedMs >= confirmTimeoutMs
    }
}

/// The confirmation timers of R-CONFIRM-TELEMETRY (T5), by the name the expiry event carries.
public enum ConfirmTimerName: String, Equatable, Sendable {
    /// The callee's REVEAL timer (`CONFIRM_TIMEOUT` after the first ACCEPT send).
    case reveal = "reveal"
    /// The caller's round-1 wait for the callee's KCMAC (30 s after its REVEAL was handed to the transport).
    case kcmacR1Caller = "kcmac_r1_caller"
    /// The callee's round-1 wait for the caller's KCMAC (`CONFIRM_TIMEOUT` after its own REVEAL verified).
    case kcmacR1Callee = "kcmac_r1_callee"
    /// The ordinary KCMAC window of a round, and any round >= 2.
    case kcmacRound = "kcmac_round"
    /// The DTLS statistics check (§3.8.4).
    case dtlsfpStats = "dtlsfp_stats"

    /// The timer of one KCMAC wait: round 1 has the two long exceptions, every other round the ordinary window.
    public static func kcMac(isRound1: Bool, isInitiator: Bool) -> ConfirmTimerName {
        guard isRound1 else { return .kcmacRound }
        return isInitiator ? .kcmacR1Caller : .kcmacR1Callee
    }
}

/// One confirmation expiry (R-CONFIRM-TELEMETRY): exactly one is emitted when a confirmation timer ends a call.
/// It carries the timer name, the time from the start of that wait to its expiry, the key round (`1` for the REVEAL
/// and the DTLS check), the number of signalling-socket re-authentications of this device during the wait, and the
/// call id cut to 8 characters. Never a key, MAC, nonce, SAS word, fingerprint, address or full identifier.
public struct ConfirmTimeoutEvent: Equatable, Sendable {
    public let timer: ConfirmTimerName
    public let elapsedMs: Int
    public let round: Int
    public let reauths: Int
    public let callId8: String

    public init(timer: ConfirmTimerName, elapsedMs: Int, round: Int, reauths: Int, callId: String) {
        self.timer = timer
        self.elapsedMs = max(0, elapsedMs)
        self.round = round
        self.reauths = max(0, reauths)
        self.callId8 = String(callId.prefix(8))
    }

    /// The one local log line (hsfatal style: `key=value` tokens only, numbers and the timer name).
    public var logLine: String {
        "confirm_timeout timer=\(timer.rawValue) ms=\(elapsedMs) round=\(round) reauths=\(reauths) id=\(callId8)"
    }
}

/// The signalling-socket re-authentications of one call, as monotonic timestamps: the telemetry of an expiry asks how
/// many fell inside the wait that expired. Bounded so a flapping socket cannot grow it.
public struct ReauthLog: Equatable, Sendable {
    public static let maxEntries = 64
    public private(set) var times: [Int] = []

    public init() {}

    public mutating func note(nowMs: Int) {
        times.append(nowMs)
        if times.count > Self.maxEntries { times.removeFirst(times.count - Self.maxEntries) }
    }

    /// Re-authentications at or after `sinceMs`.
    public func count(sinceMs: Int) -> Int {
        times.reduce(0) { $0 + ($1 >= sinceMs ? 1 : 0) }
    }
}

/// What a signalling-socket re-authentication has to re-send (R-KCMAC-RESEND), decided from the device's own state.
/// An EVENT takes one unit of the per-call budget and re-sends everything that is due; nothing due consumes none.
public enum ConfirmResend {

    public struct Due: Equatable, Sendable {
        /// The caller's byte-identical REVEAL.
        public let reveal: Bool
        /// This device's own KCMAC of the live round (byte-identical).
        public let ownKcMac: Bool
        /// True when anything is due: only then does the event consume a unit of the budget.
        public var any: Bool { reveal || ownKcMac }
    }

    /// - `isCaller`/`revealBound`: this device is the caller and bound a round-1 ACCEPT (a REVEAL exists).
    /// - `isRound1`: the live KCMAC round is round 1.
    /// - `ownKcMacSent`: this device already put its own MAC of the live round on the wire once (a callee whose REVEAL
    ///   has not verified holds it: it re-sends nothing and does not start sending it now, R-COMMIT-KCMAC-HOLD).
    /// - `peerKcMacVerified`: the peer's MAC of the live round is verified (a verified MAC proves the REVEAL and the
    ///   own MAC arrived).
    public static func due(isCaller: Bool, revealBound: Bool, isRound1: Bool,
                           ownKcMacSent: Bool, peerKcMacVerified: Bool) -> Due {
        // A verified peer MAC of the live round proves the REVEAL (round 1) and our own MAC arrived.
        guard !peerKcMacVerified else { return Due(reveal: false, ownKcMac: false) }
        return Due(reveal: isCaller && revealBound && isRound1, ownKcMac: ownKcMacSent)
    }
}

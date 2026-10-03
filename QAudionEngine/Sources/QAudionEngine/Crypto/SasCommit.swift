import Foundation
import CryptoKit
import Security

/// SAS commitment of the 1:1 handshake, transcript v6 (WIRE_SPEC §3.7.4).
///
/// The caller draws a secret 32-byte `sasNonce` per call and commits to it in the round-1 OFFER
/// (`sasCommit`, signed inside `OFFER_v6`). The callee answers with its ACCEPT. Only then does the
/// caller reveal the nonce (`REVEAL`), naming the ACCEPT it bound. The SAS words depend on the nonce, so
/// neither side can grind them: the callee is bound before the nonce is public, the caller is bound
/// before the callee's contribution exists.
///
/// This file holds the pure pieces (commitment, REVEAL wire format, the two per-call state machines)
/// and `SasCommitBook`, the per-call store the call integration drives. Nothing here logs: the nonce,
/// the commitment, the accept binding and the words never reach a log line (R-COMMIT-LOG).
public enum SasCommit {

    /// `"qaudion-sas-commit-v6"`, 21 bytes ASCII, NOT length-prefixed.
    public static let commitLabel = Data("qaudion-sas-commit-v6".utf8)
    public static let nonceLength = 32
    public static let commitLength = 32
    // The callee waits `ConfirmTimeout.confirmTimeoutMs` (15 s) after FIRST sending its ACCEPT for a verified
    // REVEAL, and a call has `ConfirmTimeout.maxResendEvents` (4) re-send events (a duplicate of the bound
    // ACCEPT, a signalling-socket re-authentication): one definition of each, in `ConfirmTimeout`.

    public static let reasonMismatch = "sas_commit_mismatch"
    public static let reasonTimeout = "sas_reveal_timeout"

    /// 32 bytes from the platform CSPRNG; `nil` only if the CSPRNG itself fails (the call must then not
    /// start: there is no fallback).
    public static func newNonce() -> Data? {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return Data(bytes)
    }

    /// `SHA-256("qaudion-sas-commit-v6" || LP(callId) || sasNonce)`, `LP(x) = u16_BE(len) || x`.
    /// `nil` for a nonce that is not 32 bytes or a callId too long to be length-prefixed.
    public static func commit(callId: String, nonce: Data) -> Data? {
        let id = Data(callId.utf8)
        guard nonce.count == nonceLength, id.count <= 0xFFFF else { return nil }
        var input = Data()
        input.append(commitLabel)
        input.append(UInt8((id.count >> 8) & 0xFF))
        input.append(UInt8(id.count & 0xFF))
        input.append(id)
        input.append(nonce)
        return Data(SHA256.hash(data: input))
    }

    /// Canonical standard base64 (with padding): `text` is valid iff it decodes to exactly
    /// `expectedLength` bytes AND re-encodes to the very same string. That rejects missing padding, the
    /// URL-safe alphabet, whitespace and non-zero trailing bits identically on every platform, whatever
    /// the platform decoder tolerates.
    public static func decodeCanonicalBase64(_ text: String, expectedLength: Int) -> Data? {
        guard let decoded = Data(base64Encoded: text), decoded.count == expectedLength else { return nil }
        guard decoded.base64EncodedString() == text else { return nil }
        return decoded
    }

    /// Constant-time equality of two byte strings (length is not secret here).
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }

    /// A server-stamped `sender_device_id` is an opaque string compared byte for byte; an absent or empty one
    /// means "no device" (`nil`) and never matches anything (R-COMMIT-KCMAC-DEVICE).
    public static func normalizedDeviceId(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// Monotonic milliseconds for the REVEAL timer (never wall-clock: a clock change must not fire it).
    public static func monotonicNowMs() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}

/// The `<callId>|SASREVEAL:<B>` message, `B = base64(acceptBinding[32] || sasNonce[32])` (88 characters,
/// canonical base64). Sent by the caller to the callee as an `opaque_message` string, like KCMAC.
public enum SasReveal {

    public static let tag = "SASREVEAL:"
    public static let payloadLength = 64
    public static let base64Length = 88
    /// The whole `data` string is at most this many characters.
    public static let maxDataLength = 200

    /// The wire string; `nil` when `acceptBinding` or `nonce` is not 32 bytes.
    public static func serialize(callId: String, acceptBinding: Data, nonce: Data) -> String? {
        guard acceptBinding.count == 32, nonce.count == SasCommit.nonceLength else { return nil }
        var payload = Data(capacity: payloadLength)
        payload.append(acceptBinding)
        payload.append(nonce)
        return callId + "|" + tag + payload.base64EncodedString()
    }

    public enum Parsed: Equatable {
        /// Not a REVEAL for `expectedCallId` (another tag, another call, wrong-case tag): not routed here.
        case notAReveal
        /// A REVEAL that is ill-formed: too long, not canonical base64, not 64 bytes.
        case malformed
        case payload(acceptBinding: Data, nonce: Data)
    }

    /// Parse the literal `opaque_message.data`. The text before the FIRST `|` is the callId (compared
    /// case-insensitively with `expectedCallId`); the remainder must start with the case-sensitive tag.
    public static func parse(data: String, expectedCallId: String) -> Parsed {
        guard let pipe = data.firstIndex(of: "|") else { return .notAReveal }
        let id = String(data[data.startIndex..<pipe])
        guard !id.isEmpty, id.lowercased() == expectedCallId.lowercased() else { return .notAReveal }
        let rest = String(data[data.index(after: pipe)...])
        guard rest.hasPrefix(tag) else { return .notAReveal }
        guard data.count <= maxDataLength else { return .malformed }
        let b64 = String(rest.dropFirst(tag.count))
        guard b64.count == base64Length,
              let bytes = SasCommit.decodeCanonicalBase64(b64, expectedLength: payloadLength) else {
            return .malformed
        }
        return .payload(acceptBinding: Data(bytes.prefix(32)), nonce: Data(bytes.suffix(32)))
    }
}

/// The callee device's side of round 1, as a pure state machine (the sequence vectors replay it).
public struct SasCommitCallee {

    public enum Outcome: Equatable {
        /// Nothing happened (a tick before the timer, an event with no effect).
        case none
        /// The message was dropped silently: no state created, nothing changed.
        case dropped
        /// A REVEAL opened the commitment: the SAS can be derived.
        case sasReady
        /// The call ends with this security reason and the peer is notified.
        case end(reason: String)
        /// A sibling device's ACCEPT was bound: leave locally, WITHOUT notifying the peer.
        case leaveLocally
    }

    /// The callId exactly as the OFFER transcript (and so the commitment) carries it.
    public let callId: String
    /// The `sasCommit` of the OFFER this device answered.
    public let storedCommit: Data
    public private(set) var acceptHash: Data?
    public private(set) var acceptSentAtMs: Int?
    public private(set) var verifiedNonce: Data?
    /// Monotonic time (ms) at which the REVEAL verified (R-COMMIT-CHECK step 7): the start of the callee's own
    /// round-1 KCMAC wait (A5, `KcMacWindow`).
    public private(set) var verifiedAtMs: Int?
    /// Ended with a security reason, or left locally (sibling): every later event is ignored.
    public private(set) var finished = false
    public private(set) var leftLocally = false

    public init(callId: String, storedCommit: Data) {
        self.callId = callId
        self.storedCommit = storedCommit
    }

    /// A2 (WIRE_SPEC 3.7.4, pending OFFER): while this device has NOT sent its round-1 ACCEPT, the newest valid
    /// round-1 OFFER replaces the one it holds. True while the ACCEPT is not out and the call is not over.
    public var canBeSuperseded: Bool { acceptSentAtMs == nil && !finished }

    /// The `SHA-256(ACCEPT_v6)` of the ACCEPT this device built for the commitment (at ring time on
    /// iOS). Ignored once the ACCEPT was sent: the answered OFFER is frozen.
    public mutating func setAcceptHash(_ hash: Data) {
        guard acceptSentAtMs == nil, hash.count == 32 else { return }
        acceptHash = hash
    }

    /// The ACCEPT is actually SENT now. Only the FIRST send freezes the commitment and starts the
    /// REVEAL timer (`ConfirmTimeout.confirmTimeoutMs`); later sends (retransmissions, cached replays) never restart it. Returns true on the
    /// first send.
    @discardableResult
    public mutating func acceptSent(nowMs: Int) -> Bool {
        guard !finished, acceptHash != nil, acceptSentAtMs == nil else { return false }
        acceptSentAtMs = nowMs
        return true
    }

    /// A REVEAL arrived from the call peer (the sender check is the caller's job). Steps 2 and 4-7 of
    /// WIRE_SPEC §3.7.4.
    public mutating func receiveReveal(data: String, nowMs: Int) -> Outcome {
        guard !finished else { return .dropped }
        // Step 2: only a device that sent its round-1 ACCEPT ever processes a REVEAL.
        guard let own = acceptHash, acceptSentAtMs != nil else { return .dropped }
        switch SasReveal.parse(data: data, expectedCallId: callId) {
        case .notAReveal:
            return .dropped
        case .malformed:
            return fail(SasCommit.reasonMismatch)
        case .payload(let binding, let nonce):
            // Step 5: it names another ACCEPT: this device lost the race.
            guard SasCommit.constantTimeEquals(binding, own) else {
                finished = true
                leftLocally = true
                return .leaveLocally
            }
            // Step 6: a REVEAL was already verified.
            if let verified = verifiedNonce {
                return SasCommit.constantTimeEquals(verified, nonce) ? .dropped : fail(SasCommit.reasonMismatch)
            }
            // Step 7: the nonce must open the stored commitment.
            guard let recomputed = SasCommit.commit(callId: callId, nonce: nonce),
                  SasCommit.constantTimeEquals(recomputed, storedCommit) else {
                return fail(SasCommit.reasonMismatch)
            }
            verifiedNonce = nonce
            verifiedAtMs = nowMs
            return .sasReady
        }
    }

    /// The REVEAL timer: no verified REVEAL `ConfirmTimeout.confirmTimeoutMs` (15 s) after the first ACCEPT send
    /// ends the call.
    public mutating func tick(nowMs: Int) -> Outcome {
        guard !finished, verifiedNonce == nil, let sentAt = acceptSentAtMs else { return .none }
        if nowMs - sentAt >= ConfirmTimeout.confirmTimeoutMs {
            return fail(SasCommit.reasonTimeout)
        }
        return .none
    }

    /// The timer task's own 15 s sleep elapsed: if the REVEAL has not verified, the call ends.
    public mutating func timerFired() -> Outcome {
        guard !finished, verifiedNonce == nil, acceptSentAtMs != nil else { return .none }
        return fail(SasCommit.reasonTimeout)
    }

    /// False once this device left as a sibling (or ended): its KCMAC handling must stop.
    public var acceptsKeyConfirmation: Bool { !finished }

    /// True while the ACCEPT is out and the REVEAL has not verified yet: the UI shows "waiting for the
    /// security code" and the SAS confirmation is disabled.
    public var isWaitingForReveal: Bool { acceptHash != nil && verifiedNonce == nil && !finished }

    private mutating func fail(_ reason: String) -> Outcome {
        finished = true
        return .end(reason: reason)
    }
}

/// The caller's side of round 1, as a pure state machine.
public struct SasCommitCaller {

    public enum AcceptDecision: Equatable {
        /// First valid ACCEPT: bind it, send the REVEAL (before the KCMAC).
        case bindAndReveal
        /// A byte-identical duplicate of the bound ACCEPT: re-send the identical REVEAL.
        case resendReveal
        /// A different round-1 ACCEPT after binding (sibling, forgery), an exhausted re-send budget,
        /// or an ended call: dropped, never used.
        case drop
    }

    public let callId: String
    public let commit: Data
    private var nonce: Data?
    public private(set) var boundAcceptHash: Data?
    /// The `sender_device_id` of the opaque envelope that carried the bound ACCEPT (R-COMMIT-KCMAC-DEVICE).
    /// `nil` when the envelope carried none: no KCMAC will ever pass the sender-device rule (fail closed).
    public private(set) var boundSenderDeviceId: String?
    /// Monotonic time (ms) at which the latest REVEAL was handed to the transport: the start of the caller's
    /// 30 s wait for the callee's round-1 KCMAC (A1/T3, `KcMacWindow`).
    public private(set) var revealHandedAtMs: Int?
    /// REVEALs produced for the transport (the first send and every re-send). Informational: the re-send
    /// BUDGET is per call and shared with the KCMAC re-sends, so it lives in `SasCommitBook`.
    public private(set) var revealsSent = 0
    public private(set) var ended = false

    /// `nil` when `nonce` is not 32 bytes or the commitment cannot be built.
    public init?(callId: String, nonce: Data) {
        guard let commit = SasCommit.commit(callId: callId, nonce: nonce) else { return nil }
        self.callId = callId
        self.commit = commit
        self.nonce = nonce
    }

    /// A round-1 ACCEPT that parsed and passed the malformed checks. Binding is atomic by construction:
    /// the book calls this under its lock.
    public mutating func onAccept(acceptHash: Data, senderDeviceId: String? = nil) -> AcceptDecision {
        guard !ended, acceptHash.count == 32, nonce != nil else { return .drop }
        guard let bound = boundAcceptHash else {
            boundAcceptHash = acceptHash
            boundSenderDeviceId = SasCommit.normalizedDeviceId(senderDeviceId)
            revealsSent = 1
            return .bindAndReveal
        }
        guard SasCommit.constantTimeEquals(bound, acceptHash) else { return .drop }
        // A byte-identical duplicate of the bound ACCEPT: its REVEAL goes again, within the per-call re-send
        // budget (`SasCommitBook.takeResendEvent`, shared with the re-authentication re-sends).
        revealsSent += 1
        return .resendReveal
    }

    /// A REVEAL was produced again by a re-authentication event (the budget was taken by the book).
    public mutating func countRevealResend() {
        guard !ended, boundAcceptHash != nil, nonce != nil else { return }
        revealsSent += 1
    }

    /// The REVEAL string for the bound ACCEPT; `nil` before binding or after the call ended.
    public func revealWire() -> String? {
        guard !ended, let bound = boundAcceptHash, let nonce = nonce else { return nil }
        return SasReveal.serialize(callId: callId, acceptBinding: bound, nonce: nonce)
    }

    /// The nonce, for the caller's own SAS derivation (only after binding).
    public var sasNonce: Data? { boundAcceptHash == nil ? nil : nonce }

    /// The REVEAL was handed to the transport (first send or a re-send): the caller's 30 s (2 x `CONFIRM_TIMEOUT`) wait
    /// for the callee's round-1 KCMAC runs from the latest one (a longer wait is allowed, never a shorter one).
    public mutating func revealHanded(nowMs: Int) {
        guard !ended, boundAcceptHash != nil else { return }
        revealHandedAtMs = max(revealHandedAtMs ?? nowMs, nowMs)
    }

    /// R-COMMIT-KCMAC-DEVICE: the sender-device rule. True only for an envelope whose `sender_device_id` equals
    /// the one recorded at binding; an absent id on either side never matches.
    public func admitsKcMac(fromDeviceId deviceId: String?) -> Bool {
        guard !ended, let bound = boundSenderDeviceId,
              let device = SasCommit.normalizedDeviceId(deviceId) else { return false }
        return device == bound
    }

    /// A caller never receives a REVEAL honestly: always dropped.
    public func onReveal() -> AcceptDecision { .drop }

    /// Hangup, cancel, glare, or any end: the nonce is zeroised and never leaves the device again.
    public mutating func end() {
        ended = true
        nonce = nil
    }
}

/// The KCMAC wait of one key round (WIRE_SPEC 3.7.1 Window rule, 3.7.4 KCMAC hold). Every key round waits
/// `CONFIRM_TIMEOUT` (15 s, `ConfirmTimeout`) from the moment its context is armed. Round 1 has two extensions, both
/// because the callee's round-1 KCMAC follows the REVEAL round trip:
/// - the CALLER (round-1 `init`) waits for the callee's MAC no earlier than 2 x `CONFIRM_TIMEOUT` = 30 s after it
///   handed its REVEAL to the transport (A1, T3): the REVEAL may need a socket re-authentication and a re-send to
///   reach the callee, and the callee's MAC then needs one more window to come back;
/// - the CALLEE (round-1 `resp`) waits for the caller's MAC no earlier than `CONFIRM_TIMEOUT` after its OWN REVEAL
///   verified (A5, T3), because the REVEAL may arrive near the end of the REVEAL timer and the caller's MAC follows it
///   on the same ordered path.
/// A wait may be longer, never shorter. Expiry without a verified MAC is `kcmac_mismatch`.
public enum KcMacWindow {
    public static let baseMs = ConfirmTimeout.confirmTimeoutMs
    public static let callerRound1AfterRevealMs = ConfirmTimeout.callerRound1KcMacWaitMs
    public static let calleeRound1AfterRevealVerifiedMs = ConfirmTimeout.confirmTimeoutMs
    /// Callee, round 1, REVEAL not verified yet: the wait is held open this long from arming. The REVEAL timer
    /// (`CONFIRM_TIMEOUT` after the first ACCEPT send) ends such a call with `sas_reveal_timeout` first; this only
    /// keeps the KCMAC wait from pre-empting it with a different reason.
    public static let calleeRound1PreRevealBackstopMs = 2 * ConfirmTimeout.confirmTimeoutMs

    /// Milliseconds left, `0` when expired. Pure: every time is monotonic milliseconds.
    public static func remainingMs(isRound1: Bool, isInitiator: Bool, armedAtMs: Int, nowMs: Int,
                                   revealHandedAtMs: Int?, revealVerifiedAtMs: Int?) -> Int {
        var end = armedAtMs + baseMs
        if isRound1 {
            if isInitiator {
                if let handed = revealHandedAtMs { end = max(end, handed + callerRound1AfterRevealMs) }
            } else if let verified = revealVerifiedAtMs {
                end = max(end, verified + calleeRound1AfterRevealVerifiedMs)
            } else {
                end = max(end, armedAtMs + calleeRound1PreRevealBackstopMs)
            }
        }
        return max(0, end - nowMs)
    }

    /// The wait when no SAS book is reachable (the integration that carried the call is gone while its
    /// key-confirmation state is still alive): there is no REVEAL time to read, so a round-1 wait keeps the
    /// LONGEST value of its role instead of falling back to the base window (a wait may be longer, never
    /// shorter): the initiator's 30 s from arming, the callee's pre-REVEAL backstop. A later round is the base
    /// window as always.
    public static func remainingMsWithoutBook(isRound1: Bool, isInitiator: Bool, armedAtMs: Int, nowMs: Int) -> Int {
        remainingMs(isRound1: false, isInitiator: isInitiator, armedAtMs: armedAtMs, nowMs: nowMs,
                    revealHandedAtMs: nil, revealVerifiedAtMs: nil)
    }
}

/// Per-call store of the SAS commitment state, driven by `QAudionCallIntegration` (round 1 only).
///
/// It also keeps the round-1 session key and accept hash, because the words of a call are ALWAYS the
/// round-1 words (held or not, before and after any rekey): the caller's once it sent its REVEAL, the
/// callee's once a REVEAL verified. Keyed by lowercased callId; in memory only; cleared when the call
/// ends.
public final class SasCommitBook: @unchecked Sendable {

    private struct Round1 {
        let sessionKey: Data
        let acceptHash: Data
    }

    private let lock = NSLock()
    private var callers: [String: SasCommitCaller] = [:]
    private var callees: [String: SasCommitCallee] = [:]
    private var round1: [String: Round1] = [:]
    private var wordsByCall: [String: [String]] = [:]
    /// A2: the serial of each callee context (`beginCalleeOwned`). Serials only grow, so the context of a replaced
    /// OFFER and the one that replaced it never share one, and a step of the replaced OFFER can tell it is stale.
    private var calleeSerials: [String: UInt64] = [:]
    private var lastCalleeSerial: UInt64 = 0

    public init() {}

    // MARK: - Caller

    /// Draw the call's nonce and return its commitment (round-1 OFFER field). Never regenerated for the
    /// same call: a second call for the same id returns the existing commitment. `nil` if the CSPRNG
    /// fails.
    public func beginCaller(callId: String) -> Data? {
        let id = callId.lowercased()
        guard !id.isEmpty else { return nil }
        return lock.withLock { () -> Data? in
            if let existing = callers[id] { return existing.commit }
            guard let nonce = SasCommit.newNonce(),
                  let caller = SasCommitCaller(callId: callId, nonce: nonce) else { return nil }
            callers[id] = caller
            return caller.commit
        }
    }

    /// Test seam: the same with a fixed nonce (the KAT vectors and sequences need a known one).
    func beginCaller(callId: String, nonce: Data) -> Data? {
        let id = callId.lowercased()
        guard !id.isEmpty, let caller = SasCommitCaller(callId: callId, nonce: nonce) else { return nil }
        return lock.withLock { () -> Data? in
            if let existing = callers[id] { return existing.commit }
            callers[id] = caller
            return caller.commit
        }
    }

    /// The commitment the caller put in its round-1 OFFER.
    public func callerCommit(callId: String) -> Data? {
        lock.withLock { callers[callId.lowercased()]?.commit }
    }

    /// A round-1 ACCEPT was parsed and passed the malformed checks: bind it (atomically) or classify it.
    /// Returns the decision and, for bind / re-send, the REVEAL wire string to send.
    ///
    /// `senderDeviceId` is the `sender_device_id` of the opaque envelope that carried the ACCEPT. It is recorded
    /// at the binding (R-COMMIT-KCMAC-DEVICE) and nowhere else: a duplicate or a different ACCEPT never changes it.
    public func callerOnAccept(callId: String, acceptHash: Data,
                               senderDeviceId: String? = nil) -> (SasCommitCaller.AcceptDecision, String?) {
        let id = callId.lowercased()
        return lock.withLock { () -> (SasCommitCaller.AcceptDecision, String?) in
            guard var caller = callers[id] else { return (.drop, nil) }
            let decision = caller.onAccept(acceptHash: acceptHash, senderDeviceId: senderDeviceId)
            switch decision {
            case .bindAndReveal:
                callers[id] = caller
                return (decision, caller.revealWire())
            case .resendReveal:
                // R-KCMAC-RESEND: a duplicate ACCEPT is ONE event of the per-call budget shared with the
                // re-authentication re-sends. A spent budget drops it: nothing is re-sent.
                guard takeResendEventLocked(id: id) else { return (.drop, nil) }
                callers[id] = caller
                return (decision, caller.revealWire())
            case .drop:
                return (.drop, nil)
            }
        }
    }

    /// The byte-identical REVEAL for a re-send, `nil` before binding or after the call ended. It does NOT take a
    /// budget unit: the event that asks for it (a socket re-authentication) has taken ONE unit for everything it
    /// re-sends (`takeResendEvent`). A duplicate ACCEPT goes through `callerOnAccept`, which takes its own unit.
    public func callerRevealForResend(callId: String) -> String? {
        let id = callId.lowercased()
        return lock.withLock { () -> String? in
            guard var caller = callers[id], let wire = caller.revealWire() else { return nil }
            caller.countRevealResend()
            callers[id] = caller
            return wire
        }
    }

    /// A byte-identical duplicate of the bound round-1 ACCEPT was seen (the integration's pre-verification
    /// short-circuit): ONE event of the budget, and the REVEAL to send again. `nil` when the budget is spent or
    /// nothing is bound (nothing is re-sent).
    public func callerRevealForDuplicateAccept(callId: String) -> String? {
        let id = callId.lowercased()
        return lock.withLock { () -> String? in
            guard var caller = callers[id], let wire = caller.revealWire() else { return nil }
            guard takeResendEventLocked(id: id) else { return nil }
            caller.countRevealResend()
            callers[id] = caller
            return wire
        }
    }

    // MARK: - Re-send budget (R-KCMAC-RESEND)

    private var resendEvents: [String: Int] = [:]
    private var reauthLogs: [String: ReauthLog] = [:]

    private func takeResendEventLocked(id: String) -> Bool {
        let used = resendEvents[id] ?? 0
        guard used < ConfirmTimeout.maxResendEvents else { return false }
        resendEvents[id] = used + 1
        return true
    }

    /// ONE re-send EVENT of the call: a duplicate ACCEPT received by the caller, or a re-authentication of this
    /// device's signalling socket. The budget is one counter per call and per device, shared by every re-send of the
    /// call (the REVEAL and the KCMACs); an event re-sends in that event everything that is due and takes one unit,
    /// not one per message. Returns false once the `ConfirmTimeout.maxResendEvents` (4) units are spent: a fifth
    /// event re-sends nothing. First sends are not events.
    public func takeResendEvent(callId: String) -> Bool {
        let id = callId.lowercased()
        return lock.withLock { takeResendEventLocked(id: id) }
    }

    /// Units of the budget already spent (tests and telemetry).
    public func resendEventsUsed(callId: String) -> Int {
        lock.withLock { resendEvents[callId.lowercased()] ?? 0 }
    }

    // MARK: - Signalling-socket re-authentications (T5 telemetry)

    /// The signalling socket of this device re-authenticated while `callId` is a call of this book.
    public func noteReauth(callId: String, nowMs: Int) {
        let id = callId.lowercased()
        lock.withLock {
            guard callers[id] != nil || callees[id] != nil else { return }
            var log = reauthLogs[id] ?? ReauthLog()
            log.note(nowMs: nowMs)
            reauthLogs[id] = log
        }
    }

    /// Re-authentications of this call at or after `sinceMs` (the start of the wait that expired).
    public func reauths(callId: String, sinceMs: Int) -> Int {
        lock.withLock { reauthLogs[callId.lowercased()]?.count(sinceMs: sinceMs) ?? 0 }
    }

    /// The REVEAL was handed to the transport (first send or re-send): starts the caller's round-1 KCMAC wait.
    public func callerRevealHanded(callId: String, nowMs: Int) {
        let id = callId.lowercased()
        lock.withLock {
            guard var caller = callers[id] else { return }
            caller.revealHanded(nowMs: nowMs)
            callers[id] = caller
        }
    }

    /// What the caller's sender-device rule says about one inbound KCMAC (R-COMMIT-KCMAC-DEVICE).
    public enum KcMacSenderVerdict: Equatable {
        /// This device is not the caller of `callId`: the rule does not apply (the callee judges by its own rules).
        case notApplicable
        /// The envelope's `sender_device_id` is the bound ACCEPT's: duplicate test, hold and judgment may run.
        case admit
        /// Another device, no device id, or no bound ACCEPT: dropped silently. No judgment, no `kcmac_mismatch`,
        /// no hold, no effect on any window.
        case dropSilently
    }

    /// R-COMMIT-KCMAC-DEVICE, caller side, every KCMAC of the call and every round (A6). Comes BEFORE the
    /// duplicate test and the judgment.
    public func callerKcMacSenderVerdict(callId: String, envelopeSenderDeviceId: String?) -> KcMacSenderVerdict {
        lock.withLock { () -> KcMacSenderVerdict in
            guard let caller = callers[callId.lowercased()] else { return .notApplicable }
            return caller.admitsKcMac(fromDeviceId: envelopeSenderDeviceId) ? .admit : .dropSilently
        }
    }

    /// R-COMMIT-KCMAC-DEVICE when no SAS book is reachable. A round-1 initiator's key-confirmation state that is still
    /// alive means this device IS the caller of the call but the integration holding the bound ACCEPT's device is
    /// gone: nothing can vouch for the sender, so the KCMAC is dropped silently (fail closed, as for a missing
    /// device id). Without such a state the rule does not apply (a callee has no caller book by design).
    public static func callerKcMacSenderVerdictWithoutBook(roundOneInitiatorStateAlive: Bool) -> KcMacSenderVerdict {
        .notApplicable
    }

    /// True when `callId` has a caller context that bound an ACCEPT.
    public func callerHasBound(callId: String) -> Bool {
        lock.withLock { callers[callId.lowercased()]?.boundAcceptHash != nil }
    }

    /// True when this device is the caller of `callId` (it never processes a REVEAL).
    public func isCaller(callId: String) -> Bool {
        lock.withLock { callers[callId.lowercased()] != nil }
    }

    // MARK: - Callee

    /// The OFFER this device answers carried this commitment. The first one stored wins: a later
    /// different OFFER of the same call never replaces it.
    @discardableResult
    public func beginCallee(callId: String, commit: Data) -> Bool {
        let id = callId.lowercased()
        guard !id.isEmpty, commit.count == SasCommit.commitLength else { return false }
        return lock.withLock { () -> Bool in
            installCalleeLocked(id: id, callId: callId, commit: commit, acceptHash: nil) != nil
        }
    }

    /// A2: begin the callee context of the round-1 OFFER being answered AND store the hash of the ACCEPT built for
    /// it, in one step, and return the context's serial (`nil` when a context already exists for the call, or an
    /// argument is malformed: this OFFER does not own the call's commitment). The processing of that OFFER hands the
    /// serial back to `calleeIsCurrent` / `calleeMarkAcceptSent`, so nothing it still has to do can land on the
    /// context of a different OFFER.
    public func beginCalleeOwned(callId: String, commit: Data, acceptHash: Data) -> UInt64? {
        let id = callId.lowercased()
        guard !id.isEmpty, commit.count == SasCommit.commitLength, acceptHash.count == 32 else { return nil }
        return lock.withLock { () -> UInt64? in
            installCalleeLocked(id: id, callId: callId, commit: commit, acceptHash: acceptHash)
        }
    }

    private func installCalleeLocked(id: String, callId: String, commit: Data, acceptHash: Data?) -> UInt64? {
        if callees[id] != nil { return nil }
        var callee = SasCommitCallee(callId: callId, storedCommit: commit)
        if let acceptHash { callee.setAcceptHash(acceptHash) }
        callees[id] = callee
        lastCalleeSerial &+= 1
        calleeSerials[id] = lastCalleeSerial
        return lastCalleeSerial
    }

    /// A2: true while `token` (from `beginCalleeOwned`) still names the call's callee context: it was neither
    /// replaced nor cleared.
    public func calleeIsCurrent(callId: String, token: UInt64) -> Bool {
        let id = callId.lowercased()
        return lock.withLock { callees[id] != nil && calleeSerials[id] == token }
    }

    /// A2: the serial of the call's current callee context (a replay of a cached ACCEPT belongs to it), or `nil`
    /// when the call has none.
    public func calleeCurrentToken(callId: String) -> UInt64? {
        let id = callId.lowercased()
        return lock.withLock { callees[id] != nil ? calleeSerials[id] : nil }
    }

    /// A2 compare-and-remove: wipe the callee context (and the round-1 material and counters recorded for it) of a
    /// call whose ACCEPT was NOT sent, in ONE step under the book's lock. `false` (nothing touched) when no callee
    /// context exists or its ACCEPT is already out: the answered commitment is frozen then. A concurrent
    /// `calleeMarkAcceptSent` and this call cannot both win: whichever takes the lock first decides.
    public func calleeSupersedeIfUnsent(callId: String) -> Bool {
        let id = callId.lowercased()
        return lock.withLock { () -> Bool in
            guard callers[id] == nil, callees[id] != nil else { return false }
            callees.removeValue(forKey: id)
            calleeSerials.removeValue(forKey: id)
            round1.removeValue(forKey: id)
            wordsByCall.removeValue(forKey: id)
            resendEvents.removeValue(forKey: id)
            reauthLogs.removeValue(forKey: id)
            return true
        }
    }

    /// What `calleeMarkAcceptSent` decided.
    public enum CalleeAcceptSend: Equatable {
        /// First send of the ACCEPT of this context: the commitment is frozen now and the caller arms the REVEAL timer.
        case first
        /// The ACCEPT of this context was sent before (a retransmission or a cached replay): send it, arm nothing.
        case notFirst
        /// The context named by the token is gone (replaced or cleared): the ACCEPT must NOT be sent.
        case stale
    }

    /// A2: mark the ACCEPT of the context `token` names as SENT, atomically with the check that the context is still
    /// the call's current one. Every send of a round-1 ACCEPT goes through here BEFORE the hand-over to the transport,
    /// so an ACCEPT can never leave for a context a newer OFFER already replaced.
    public func calleeMarkAcceptSent(callId: String, token: UInt64, nowMs: Int) -> CalleeAcceptSend {
        let id = callId.lowercased()
        return lock.withLock { () -> CalleeAcceptSend in
            guard var callee = callees[id] else { return .stale }
            let first = callee.acceptSent(nowMs: nowMs)
            callees[id] = callee
            if first { return .first }
            // Not the first send: only a context whose ACCEPT really went out before may send it again. One that
            // refused to mark (no ACCEPT hash stored, or already ended) has nothing to re-send.
            return .notFirst
        }
    }

    public func calleeSetAccept(callId: String, acceptHash: Data) {
        let id = callId.lowercased()
        lock.withLock {
            guard var callee = callees[id] else { return }
            callee.setAcceptHash(acceptHash)
            callees[id] = callee
        }
    }

    /// The ACCEPT is sent now; true only on the FIRST send (the caller then arms the REVEAL timer).
    @discardableResult
    public func calleeAcceptSent(callId: String, nowMs: Int) -> Bool {
        let id = callId.lowercased()
        return lock.withLock { () -> Bool in
            guard var callee = callees[id] else { return false }
            let first = callee.acceptSent(nowMs: nowMs)
            callees[id] = callee
            return first
        }
    }

    /// A REVEAL arrived. Returns `.dropped` (and creates no state) for a call this device is not a
    /// callee of, or one it has not sent its ACCEPT for.
    public func calleeOnReveal(callId: String, data: String, nowMs: Int) -> SasCommitCallee.Outcome {
        let id = callId.lowercased()
        return lock.withLock { () -> SasCommitCallee.Outcome in
            guard var callee = callees[id] else { return .dropped }
            let outcome = callee.receiveReveal(data: data, nowMs: nowMs)
            callees[id] = callee
            if outcome == .sasReady, let nonce = callee.verifiedNonce {
                deriveWordsLocked(id: id, nonce: nonce)
            }
            return outcome
        }
    }

    /// The REVEAL timer task fired (its own sleep IS the elapsed window, so no clock is consulted).
    public func calleeTimerFired(callId: String) -> SasCommitCallee.Outcome {
        let id = callId.lowercased()
        return lock.withLock { () -> SasCommitCallee.Outcome in
            guard var callee = callees[id] else { return .none }
            let outcome = callee.timerFired()
            callees[id] = callee
            return outcome
        }
    }

    /// Clock-driven variant of `calleeTimerFired` (tests and sequence replays).
    public func calleeTick(callId: String, nowMs: Int) -> SasCommitCallee.Outcome {
        let id = callId.lowercased()
        return lock.withLock { () -> SasCommitCallee.Outcome in
            guard var callee = callees[id] else { return .none }
            let outcome = callee.tick(nowMs: nowMs)
            callees[id] = callee
            return outcome
        }
    }

    /// False once this device left the call as a sibling or ended it on a SAS-commit failure: its
    /// key-confirmation handling stops (the loser must not judge the real call's MAC).
    public func calleeAcceptsKeyConfirmation(callId: String) -> Bool {
        lock.withLock { callees[callId.lowercased()]?.acceptsKeyConfirmation ?? true }
    }

    /// A2: true while this device is a callee of `callId` that has NOT sent its round-1 ACCEPT (and has not ended):
    /// the newest valid round-1 OFFER then replaces the one it holds. False once the ACCEPT is out (the
    /// answered commitment is frozen and a different round-1 OFFER is dropped) and for a device that is no callee.
    public func calleeCanBeSuperseded(callId: String) -> Bool {
        lock.withLock { callees[callId.lowercased()]?.canBeSuperseded ?? false }
    }

    public func isCallee(callId: String) -> Bool {
        lock.withLock { callees[callId.lowercased()] != nil }
    }

    /// True when this device is a callee that sent its ACCEPT and still waits for a verified REVEAL.
    public func isWaitingForReveal(callId: String) -> Bool {
        let id = callId.lowercased()
        return lock.withLock { (callees[id]?.isWaitingForReveal ?? false) && wordsByCall[id] == nil }
    }

    // MARK: - Round-1 KCMAC wait (A1 caller, A5 callee)

    /// Milliseconds left on the KCMAC wait of one key round, `0` once it has expired (`KcMacWindow`). The round-1
    /// extensions read this call's own REVEAL times: the caller's from the REVEAL it handed to the transport, the
    /// callee's from its own REVEAL verifying. `nowMs` is `SasCommit.monotonicNowMs()`.
    public func kcWaitRemainingMs(callId: String, isRound1: Bool, isInitiator: Bool,
                                  armedAtMs: Int, nowMs: Int) -> Int {
        let id = callId.lowercased()
        let (handed, verified) = lock.withLock { () -> (Int?, Int?) in
            (callers[id]?.revealHandedAtMs, callees[id]?.verifiedAtMs)
        }
        return KcMacWindow.remainingMs(
            isRound1: isRound1, isInitiator: isInitiator, armedAtMs: armedAtMs, nowMs: nowMs,
            revealHandedAtMs: handed, revealVerifiedAtMs: verified)
    }

    // MARK: - Round 1 material and words

    /// Record the round-1 session key and ACCEPT hash the moment the round-1 session is installed
    /// (either role). Only the first write per call counts: later rounds never change the words.
    public func recordRound1(callId: String, sessionKey: Data, acceptHash: Data) {
        let id = callId.lowercased()
        guard !id.isEmpty, !sessionKey.isEmpty, acceptHash.count == 32 else { return }
        lock.withLock {
            guard round1[id] == nil else { return }
            round1[id] = Round1(sessionKey: sessionKey, acceptHash: acceptHash)
            if let nonce = callers[id]?.sasNonce {
                deriveWordsLocked(id: id, nonce: nonce)
            } else if let nonce = callees[id]?.verifiedNonce {
                deriveWordsLocked(id: id, nonce: nonce)
            }
        }
    }

    /// The round-1 SAS words, or `nil` while they are not available (caller: before it bound and sent
    /// its REVEAL; callee: before a REVEAL verified).
    public func words(callId: String) -> [String]? {
        lock.withLock { wordsByCall[callId.lowercased()] }
    }

    /// The round-1 session key of the call (what the SAS words derive from), when recorded.
    public func round1SessionKey(callId: String) -> Data? {
        lock.withLock { round1[callId.lowercased()]?.sessionKey }
    }

    private func deriveWordsLocked(id: String, nonce: Data) {
        guard wordsByCall[id] == nil, let material = round1[id] else { return }
        if let sas = try? ComputeSasUseCase.invoke(
            sessionKey: material.sessionKey, transcriptHash: material.acceptHash, sasNonce: nonce) {
            wordsByCall[id] = sas.words
        }
    }

    // MARK: - Lifetime

    /// Forget one call: the nonce is zeroised (dropped) and nothing of it survives.
    public func clear(callId: String) {
        let id = callId.lowercased()
        lock.withLock {
            callers[id]?.end()
            callers.removeValue(forKey: id)
            callees.removeValue(forKey: id)
            calleeSerials.removeValue(forKey: id)
            round1.removeValue(forKey: id)
            wordsByCall.removeValue(forKey: id)
            resendEvents.removeValue(forKey: id)
            reauthLogs.removeValue(forKey: id)
        }
    }

    public func clearAll() {
        lock.withLock {
            for key in Array(callers.keys) { callers[key]?.end() }
            callers.removeAll()
            callees.removeAll()
            calleeSerials.removeAll()
            round1.removeAll()
            wordsByCall.removeAll()
            resendEvents.removeAll()
            reauthLogs.removeAll()
        }
    }
}

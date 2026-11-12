import Foundation

/// What the second-signature layer says about the peer's round-1 bundle, handed to `CapsBindCallState.judgeRound1`.
struct PqVerification: Equatable {
    let result: PqSigResult
    /// Lowercase hex of the key id the check ran under, or nil.
    let keyId: String?
    /// The bundle advertises `sigHybridV1`.
    let sigHybridV1: Bool
}

/// What the integration keeps per call for `capsBindV1`: the analysis of the bundle this side sent (per round, the last one) and the
/// pin decision of round 1. The pin records themselves live in `CapsPinBook` and are never touched by this class going away: the
/// end of a call, a teardown or a restart clears this per-call state and nothing else.
final class CapsBindCallState: @unchecked Sendable {

    /// What the pin policy needs again when the round's key confirmation verifies and when the user confirms the safety code from the
    /// warning. Present only when the second-signature layer judged the round.
    struct PqRound1: Equatable {
        /// The policy input as judged (record as read, the bundle's tags, the signature result).
        var input: HybridSigPolicy.Round1Input
        /// `H` or `C`.
        var auth: String
        /// Log value of `pq_sig=`.
        var result: String
        /// Both bundles of the round carry `capsBindV1` (known when the key confirmation verified).
        var ext: Bool
        var kcmacVerified: Bool
        /// The user confirmed the safety code from the warning.
        var sas: Bool
    }

    /// The pin decision of one call's round 1.
    struct PinCall: Equatable {
        let callId: String
        let peerUserId: String
        let signerKey: Data
        let pin: CapsPinPolicy.Pin
        let hold: Bool
        let reason: CapsPinReason?
        /// A `capsWithdrawn` marker named the tag and was ignored.
        let withdrawIgnored: Bool
        /// The user confirmed the safety code from this call's warning (exit 1 taken).
        var confirmed: Bool
        /// Every warning of this call, the signature reason first, then the call-settings reason; empty without an anomaly.
        var warns: [PqWarnReason] = []
        /// A signed marker was honoured (the record lost the pinned second key).
        var withdrawHonoured: Bool = false
        var pq: PqRound1?
    }

    private let lock = NSLock()
    private var sentByCall: [String: BundleCapsBind] = [:]
    private var pinByCall: [String: PinCall] = [:]
    private var pinOrder: [String] = []
    private var registered: Set<String> = []
    private var epochValue = 0
    private static let capacity = 16

    /// Changes every time `reset()` runs (the call ended). A step that started before and finishes after it sees a different value.
    var epoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return epochValue
    }

    /// Round 1 of a call: its facts go to the registry, pinned for as long as this call lives. `epoch` is the value read when the
    /// step began: if the call has ended since (`reset()` ran), nothing is registered. The registry insert happens under the same
    /// lock as `reset()`, so an entry can never be pinned after the release of its call. True when it was registered.
    @discardableResult
    func noteRound1(callId: String, ownTag: Bool, peerTag: Bool, selfIsCaller: Bool, epoch: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == epochValue else { return false }
        registered.insert(callId.lowercased())
        CapsBindCallRegistry.noteRound1(callId: callId, ownTag: ownTag, peerTag: peerTag, selfIsCaller: selfIsCaller)
        return true
    }

    func noteSent(callId: String, info: BundleCapsBind) {
        lock.lock()
        sentByCall[callId.lowercased()] = info
        lock.unlock()
    }

    func sent(callId: String) -> BundleCapsBind? {
        lock.lock()
        defer { lock.unlock() }
        return sentByCall[callId.lowercased()]
    }

    func pinCall(callId: String) -> PinCall? {
        lock.lock()
        defer { lock.unlock() }
        return pinByCall[callId.lowercased()]
    }

    /// Per-call state only. The pin records of `CapsPinBook` are not touched.
    func reset() {
        lock.lock()
        sentByCall.removeAll()
        pinByCall.removeAll()
        pinOrder.removeAll()
        epochValue += 1
        for id in registered { CapsBindCallRegistry.release(callId: id) }
        registered.removeAll()
        lock.unlock()
    }

    private func store(_ call: PinCall) {
        let key = call.callId.lowercased()
        lock.lock()
        if pinByCall[key] == nil { pinOrder.append(key) }
        pinByCall[key] = call
        while pinOrder.count > Self.capacity {
            let old = pinOrder.removeFirst()
            pinByCall.removeValue(forKey: old)
        }
        lock.unlock()
    }

    /// Judge the peer's round-1 bundle against the sticky pin of its signer key.
    ///
    /// Only a verified signer key is judged: with `verifiedSignerKey` nil (a signature that did not verify, an unknown key) no record is
    /// read or written. A second call has its own entry (keyed by call id) and never overwrites another call's. An anomaly never ends
    /// or refuses the call: the visible warning is shown and, with the hold compiled off, nothing is held.
    ///
    /// With `pq` the second-signature layer judged the round too: the shared table (`HybridSigPolicy`) then decides the warning, the
    /// authentication and (once the round's key confirmation verified, and again after the safety code) the record. `armedForHold`
    /// changes nothing either way.
    func judgeRound1(callId: String, peerUserId: String, peer: BundleCapsBind, verifiedSignerKey: Data?,
                     book: CapsPinBook, armedForHold: Bool, pq: PqVerification? = nil) -> PinCall? {
        let withdrawIgnored = peer.withdrawn.contains(CapsBind.tag)
        guard let signerKey = verifiedSignerKey else {
            CapsBindLog.line("pin judged=0 reason=1")
            return nil
        }
        let record = book.record(peerUserId: peerUserId, signerKey: signerKey)
        let decision = CapsPinPolicy.decideRound1(record: record, peerHasCapsBind: peer.hasTag, armed: armedForHold)
        var pin = decision.pin
        var hold = decision.hold
        var warns: [PqWarnReason] = decision.reason == nil ? [] : [.capsBindV1Missing]
        var ignored = withdrawIgnored
        var honoured = false
        var pqCtx: PqRound1?
        if let pq {
            let input = HybridSigPolicy.Round1Input(
                record: record, capsBindV1: peer.hasTag, sigHybridV1: pq.sigHybridV1, withdrawn: peer.withdrawn, ext: false,
                sigHybrid: pq.result, sigKeyId: pq.keyId, kcmacValid: true, armed: armedForHold, sasConfirmed: false)
            let policy = HybridSigPolicy.decideRound1(input)
            if policy.pin == "anomaly" { pin = .anomaly }
            hold = false
            warns = policy.warn
            if policy.withdraw == "ignored" { ignored = true }
            if policy.withdraw == "honoured" { honoured = true }
            pqCtx = PqRound1(input: input, auth: policy.auth == "H" ? "H" : "C", result: policy.pqSig, ext: false,
                             kcmacVerified: false, sas: false)
        }
        let call = PinCall(callId: callId.lowercased(), peerUserId: peerUserId, signerKey: signerKey, pin: pin,
                           hold: hold, reason: decision.reason, withdrawIgnored: ignored, confirmed: false,
                           warns: warns, withdrawHonoured: honoured, pq: pqCtx)
        store(call)
        switch pin {
        case .anomaly:
            CapsBindLog.line("pin anomaly=1 hold=\(hold ? 1 : 0) withdraw=\(ignored ? 1 : 0)")
        case .ok:
            CapsBindLog.line("pin ok=1")
        case .unpinned:
            CapsBindLog.line("pin unpinned=1")
        }
        if let ctx = pqCtx {
            CapsBindLog.line("pq round=1 pin=\(pin == .unpinned ? "-" : pin.rawValue) hold=0 auth=\(ctx.auth) pq_sig=\(ctx.result) "
                + "pqstate=\(record?.pqState ?? "-") withdraw=\(ignored ? "ignored" : (honoured ? "honoured" : "-"))")
        }
        return call
    }

    /// Exit 1: the user confirmed the safety code of a call whose round 1 was an anomaly. The record drops the tag (or, when the
    /// second-signature layer judged the round, takes the state the shared table gives). Returns true once.
    @discardableResult
    func confirmAnomaly(callId: String, book: CapsPinBook) -> Bool {
        let key = callId.lowercased()
        lock.lock()
        guard var call = pinByCall[key], call.pin == .anomaly, !call.confirmed else {
            lock.unlock()
            return false
        }
        call.confirmed = true
        if call.pq != nil { call.pq?.sas = true }
        pinByCall[key] = call
        lock.unlock()
        if call.pq != nil {
            // written now when the round's key confirmation already verified, else when it does
            applyPqRecord(call, book: book)
        } else {
            book.dropCapsBind(peerUserId: call.peerUserId, signerKey: call.signerKey)
        }
        CapsBindLog.line("pin exit=1 sas=1")
        return true
    }

    /// The round-1 key confirmation of the call verified. `ext` is whether both bundles carried `capsBindV1`. When the
    /// second-signature layer judged the round the record is written here (once) and true is returned; otherwise false and the
    /// caller keeps the call-settings rule.
    @discardableResult
    func round1KeyConfirmed(callId: String, ext: Bool, book: CapsPinBook) -> Bool {
        let key = callId.lowercased()
        lock.lock()
        guard var call = pinByCall[key], call.pq != nil else {
            lock.unlock()
            return false
        }
        if call.pq?.kcmacVerified == true {
            lock.unlock()
            return true
        }
        call.pq?.kcmacVerified = true
        call.pq?.ext = ext
        pinByCall[key] = call
        lock.unlock()
        applyPqRecord(call, book: book)
        return true
    }

    /// Writes the record the table gives for this call, from the judged input, once the key confirmation verified.
    private func applyPqRecord(_ call: PinCall, book: CapsPinBook) {
        guard let pq = call.pq, pq.kcmacVerified else { return }
        var input = pq.input
        input.ext = pq.ext
        input.kcmacValid = true
        input.sasConfirmed = pq.sas
        let result = HybridSigPolicy.decideRound1(input)
        book.putRecord(peerUserId: call.peerUserId, signerKey: call.signerKey, record: result.record)
        CapsBindLog.line("pq round=1 pin=set pqstate=\(result.record?.pqState ?? "-") pq_sig=\(result.pqSig) "
            + "withdraw=\(result.withdraw) auth=\(result.auth) hold=0")
        // a safety code confirmed from a pinned invalid or other-key anomaly writes a second line
        if result.pqSig2 == "anomaly_confirmed" {
            CapsBindLog.line("pq round=1 pin=anomaly pq_sig=anomaly_confirmed hold=0")
        }
    }

    /// The words of the protection line: `pin=`, `withdraw=`, `caps=` (empty means no word).
    func lineWords(callId: String) -> (pin: String, withdraw: String, caps: String) {
        let call = pinCall(callId: callId)
        let round = CapsBindCallRegistry.round1(callId: callId)
        let pin = call.map { CapsPinPolicy.lineWord(for: $0.pin) } ?? ""
        let withdraw = (call?.withdrawIgnored ?? false) ? "ignored" : ((call?.withdrawHonoured ?? false) ? "honoured" : "")
        let caps = (round?.ownTag == true && round?.peerTag == true) ? CapsBind.tag : ""
        return (pin, withdraw, caps)
    }

    /// The record state shown on the protection line (`pqstate=`), as it was when round 1 was judged.
    func pqStateWord(callId: String) -> String {
        pinCall(callId: callId)?.pq?.input.record?.pqState ?? ""
    }
}

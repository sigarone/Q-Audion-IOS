import Foundation

/// What the integration keeps per call for `capsBindV1`: the analysis of the bundle this side sent (per round, the last one) and the
/// pin decision of round 1. The pin records themselves live in `CapsPinBook` and are never touched by this class going away: the
/// end of a call, a teardown or a restart clears this per-call state and nothing else.
final class CapsBindCallState: @unchecked Sendable {

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
    func judgeRound1(callId: String, peerUserId: String, peer: BundleCapsBind, verifiedSignerKey: Data?,
                     book: CapsPinBook, armedForHold: Bool) -> PinCall? {
        let withdrawIgnored = peer.withdrawn.contains(CapsBind.tag)
        guard let signerKey = verifiedSignerKey else {
            CapsBindLog.line("pin judged=0 reason=1")
            return nil
        }
        let decision = CapsPinPolicy.decideRound1(
            record: book.record(peerUserId: peerUserId, signerKey: signerKey),
            peerHasCapsBind: peer.hasTag, armed: armedForHold)
        let call = PinCall(callId: callId.lowercased(), peerUserId: peerUserId, signerKey: signerKey, pin: decision.pin,
                           hold: decision.hold, reason: decision.reason, withdrawIgnored: withdrawIgnored, confirmed: false)
        store(call)
        switch decision.pin {
        case .anomaly:
            CapsBindLog.line("pin anomaly=1 hold=\(decision.hold ? 1 : 0) withdraw=\(withdrawIgnored ? 1 : 0)")
        case .ok:
            CapsBindLog.line("pin ok=1")
        case .unpinned:
            CapsBindLog.line("pin unpinned=1")
        }
        return call
    }

    /// Exit 1: the user confirmed the safety code of a call whose round 1 was an anomaly. The record drops the tag. Returns true once.
    @discardableResult
    func confirmAnomaly(callId: String, book: CapsPinBook) -> Bool {
        let key = callId.lowercased()
        lock.lock()
        guard var call = pinByCall[key], call.pin == .anomaly, !call.confirmed else {
            lock.unlock()
            return false
        }
        call.confirmed = true
        pinByCall[key] = call
        lock.unlock()
        book.dropCapsBind(peerUserId: call.peerUserId, signerKey: call.signerKey)
        CapsBindLog.line("pin exit=1 sas=1")
        return true
    }

    /// The words of the protection line: `pin=`, `withdraw=`, `caps=` (empty means no word).
    func lineWords(callId: String) -> (pin: String, withdraw: String, caps: String) {
        let call = pinCall(callId: callId)
        let round = CapsBindCallRegistry.round1(callId: callId)
        let pin = call.map { CapsPinPolicy.lineWord(for: $0.pin) } ?? ""
        let withdraw = (call?.withdrawIgnored ?? false) ? "ignored" : ""
        let caps = (round?.ownTag == true && round?.peerTag == true) ? CapsBind.tag : ""
        return (pin, withdraw, caps)
    }
}

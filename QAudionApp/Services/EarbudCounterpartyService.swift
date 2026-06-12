import Foundation
import QAudionEngine

/// Orchestrates the earbud-relay-v1 counterparty handshake on iOS —
/// the app-layer twin of Android `CallController.earbudCounterpartyOutcome`.
///
/// Flow (iOS is ALWAYS the SW counterparty — no iOS earbud transport):
///   1. Peer caps advertise `earbud-relay-v1` (call_incoming on the
///      callee, call_answer on the caller) → `start(callId:peerId:)`:
///      allocate the FW-H7 monotonic HSINIT counter, build the
///      responder, ship HSINIT over the `EARBUDPDU:` opaque piggy-back.
///   2. The earbud-side phone relays the firmware's HSRESP fragments
///      back on the same channel → `handleInbound` feeds the responder.
///   3. On `.done`: ship the HSFIN fragments, then hand K_counter to
///      `QAudionCallIntegration.completeEarbudCounterparty`, which
///      installs the AdaptivePadding audio session and fires the
///      standard key-established callbacks (SAS words, broker, sealers
///      — all downstream wiring is the existing one).
///
/// One handshake per call; `reset()` on call teardown. Main-thread
/// confined (driven by AppState's @MainActor handlers).
@MainActor
final class EarbudCounterpartyService {

    /// Wire sender — AppState injects a closure that ships the literal
    /// `"<callId>|EARBUDPDU:<b64>"` string via
    /// `callingApi.sendOpaqueMessageString(recipientId:payload:)`.
    var sendOpaque: ((_ peerId: String, _ payload: String) async throws -> Void)?

    /// Fired with (callId, K_counter) when the handshake completes.
    var onSessionKey: ((String, Data) -> Void)?
    /// Fired with (callId, reason) on terminal failure (diagnostic only —
    /// the call continues without audio key, mirroring a PQC timeout).
    var onFailed: ((String, String) -> Void)?

    private var responder: EarbudHandshakeResponder?
    private var activeCallId: String?
    private var activePeerId: String?

    /// True when an earbud counterparty handshake is active (or done)
    /// for the given call — used by AppState to suppress conflicting SW
    /// handshake reactions if any ever arrive.
    func isActive(forCall callId: String) -> Bool {
        return activeCallId?.lowercased() == callId.lowercased()
    }

    /// Begin the counterparty handshake. Idempotent per call: a second
    /// start for the same callId is a no-op (caps can arrive on both
    /// call_incoming and later envelopes).
    func start(callId: String, peerId: String) {
        if isActive(forCall: callId) {
            print("[EarbudCounterparty] start ignored — already active for callId=\(callId.prefix(8))…")
            return
        }
        guard let counter = EarbudHsinitCounterAllocator.allocate(peerId: peerId) else {
            let reason = "HSINIT counter exhausted for peer — re-pair earbud to reset"
            print("[EarbudCounterparty] \(reason)")
            onFailed?(callId, reason)
            return
        }
        let r = EarbudHandshakeResponder(crypto: EarbudHandshakeCrypto(psk: nil), counter: counter)
        responder = r
        activeCallId = callId
        activePeerId = peerId
        print("[EarbudCounterparty] START callId=\(callId.prefix(8))… counter=\(counter)")
        switch r.start() {
        case .send(let pdus):
            ship(pdus, callId: callId, peerId: peerId)
        case .fail(let reason):
            terminate(callId: callId, reason: "start: \(reason)")
        case .done, .needMore:
            terminate(callId: callId, reason: "start: unexpected responder step")
        }
    }

    /// Feed an inbound `EARBUDPDU:` payload (already base64-decoded by
    /// `CallPiggyBack.parse`). PDUs for a non-active callId are dropped
    /// (stale relay from a previous call).
    func handleInbound(callId: String, pdu: Data) {
        guard isActive(forCall: callId), let r = responder else {
            print("[EarbudCounterparty] inbound PDU for inactive callId=\(callId.prefix(8))… — dropped")
            return
        }
        guard let peerId = activePeerId else { return }
        switch r.onInbound(pdu) {
        case .needMore:
            break
        case .send(let pdus):
            ship(pdus, callId: callId, peerId: peerId)
        case .done(let send, let sessionKey):
            print("[EarbudCounterparty] DONE callId=\(callId.prefix(8))… — shipping \(send.count) HSFIN fragment(s)")
            ship(send, callId: callId, peerId: peerId)
            onSessionKey?(callId, sessionKey)
        case .fail(let reason):
            terminate(callId: callId, reason: reason)
        }
    }

    /// Clear per-call state (call teardown). The responder is one-shot;
    /// the next call builds a fresh one with a fresh FW-H7 counter.
    func reset() {
        responder = nil
        activeCallId = nil
        activePeerId = nil
    }

    private func ship(_ pdus: [Data], callId: String, peerId: String) {
        guard let send = sendOpaque else {
            terminate(callId: callId, reason: "no opaque sender wired")
            return
        }
        // ONE sequential task for the whole batch: HSFIN fragments MUST
        // arrive in order — the firmware's FW-H7 gate requires a strictly
        // increasing counter per GATT write and the reassembler is
        // index-ordered. Parallel sends would race. Fail-closed: stop on
        // the first send failure (the handshake cannot survive a gap).
        Task {
            for pdu in pdus {
                let wire = CallPiggyBack.serializeEarbudPdu(callId: callId, pdu: pdu)
                do {
                    try await send(peerId, wire)
                } catch {
                    print("[EarbudCounterparty] PDU send failed (\(pdu.count)B): \(error.localizedDescription) — aborting batch")
                    return
                }
            }
        }
    }

    private func terminate(callId: String, reason: String) {
        print("[EarbudCounterparty] FAIL callId=\(callId.prefix(8))…: \(reason)")
        responder = nil
        onFailed?(callId, reason)
    }
}

import CryptoKit
import Foundation

/// CL-5.9 — iOS mirror of Android EarbudPairingRelay.kt.
///
/// Orchestrates the 3-message GATT pairing exchange (PAIR_BEGIN → PAIR_RESP → PAIR_FIN)
/// via an EarbudPairingGattProxy.
///
/// ## Parameter semantics (identical to Android Kotlin relay)
///
///   ownPkSe / ownMaterial / ownEid   = the OTHER earbud's data (relayed from the other phone).
///                                       Sent in PAIR_BEGIN; firmware sees it as peer_pk_se ||
///                                       peer_mat || peer_eid.
///   peerPkSe / peerMaterial / peerEid = the CONNECTED earbud's data (currently unused in body;
///                                        kept for documentation and future use).
///
/// ## Two-call pairing sequence (full pair)
///
///   Call 1 — connect to RESPONDER (larger eid), pass INITIATOR's pk_pq as ownMaterial.
///             RESPONDER generates ct_ee; both earbuds receive pair_id + confirm.
///   Call 2 — connect to INITIATOR (smaller eid), pass RESPONDER's ct_ee as ownMaterial.
///             INITIATOR decapsulates; both earbuds seal ss_ee to NVS after PAIR_FIN.
///
/// ## Timeouts
///   PAIR_BEGIN write + PAIR_RESP read : 60 s
///   SAS confirmation by the person    : 120 s (`sasConfirmTimeout`)
///   PAIR_FIN                          : 10 s (`finTimeout`) to get through the GATT client's operation gate
///                                       behind any other operation. When it runs out the call is cancelled: a
///                                       write still queued is withdrawn (`EarbudSerialGate` honours
///                                       cancellation), never sent late and reported as failed; a write that has
///                                       already left the gate is NOT abandoned, its own result decides (the
///                                       client bounds it with its 45 s per-operation timeout)
public final class EarbudPairingRelay {

    // MARK: - Result

    public enum PairResult {
        /// Pairing complete. `pairId` is the canonical 32-byte pair identifier.
        /// `ctEe` is non-nil when the connected earbud acted as RESPONDER —
        /// caller should publish it so the INITIATOR phone can complete Stage-2.
        case success(pairId: Data, ctEe: Data? = nil)
        /// Transient failure — retry after reconnection or fresh attestation.
        ///
        /// `pairRespCached` is true for a failure that came once the earbud may hold the PAIR_RESP of this
        /// attempt (see `needsFreshLink`); a failure of PAIR_BEGIN itself, such as the initiator-side
        /// rejection of pk_pq that the server-relay flow expects before its stage 2, leaves it false:
        /// nothing is cached and the same link is reused.
        case `defer`(reason: String, pairRespCached: Bool = false)
        /// The person did not confirm the pairing words for `pairId` (declined, did not answer in time,
        /// or the confirmation could not be shown). PAIR_FIN was NOT written, so the earbud never sealed
        /// ss_ee. A deliberate abort, not a transient failure: callers must STOP the flow (no stage-2
        /// retry, no republish) and let the person start over on a fresh link (`needsFreshLink`).
        case sasRejected(pairId: Data)

        /// True when the connected earbud may still hold the PAIR_RESP of the attempt that just ended, so
        /// the caller must drop the link (`disconnect`) before the next attempt.
        ///
        /// Why: the firmware (qaudion_gatt.c, 38fad83) copies the SE's PAIR_RESP into its own buffer on the
        /// FIRST chunk-index write (`pair_resp_write`) and releases it only after a successful PAIR_FIN,
        /// after an out-of-range PAIR_BEGIN fragment (`pair_begin_reset`) or on disconnect. A new PAIR_BEGIN
        /// makes the SE create a fresh ct_ee but does not refresh that buffer, so a retry on the same link
        /// reads the OLD PAIR_RESP, the PAIR_FIN confirm is built from a stale ct_ee, `ee_pair_fin` rejects
        /// it, and every further retry fails the same way. That fails closed (nothing wrong is sealed), but
        /// the earbud is not clean again until it disconnects.
        public var needsFreshLink: Bool {
            switch self {
            case .success:
                return false
            case .defer(_, let pairRespCached):
                return pairRespCached
            case .sasRejected:
                return true
            }
        }
    }

    // MARK: - Private constants

    private static let pairingTimeoutNS: UInt64 = 60 * 1_000_000_000

    /// How long the person has to compare the words and answer before the pairing is aborted.
    public static let sasConfirmTimeoutDefault: TimeInterval = 120

    /// How long PAIR_FIN may wait for the GATT client's operation gate before it is withdrawn. A write that
    /// has left the gate by then is not bounded by this: its own result decides.
    public static let finTimeoutDefault: TimeInterval = 10

    // MARK: - Init

    private let gatt: EarbudPairingGattProxy
    private let sasConfirmTimeoutNS: UInt64
    private let finTimeoutNS: UInt64

    /// - Parameters:
    ///   - sasConfirmTimeout: how long `isConfirmed` may take; a parameter only so a unit test
    ///     need not wait 2 minutes.
    ///   - finTimeout: how long the PAIR_FIN write may wait for the GATT client's operation gate; a
    ///     parameter only so a unit test need not wait 10 s.
    public init(gatt: EarbudPairingGattProxy,
                sasConfirmTimeout: TimeInterval = EarbudPairingRelay.sasConfirmTimeoutDefault,
                finTimeout: TimeInterval = EarbudPairingRelay.finTimeoutDefault) {
        self.gatt = gatt
        self.sasConfirmTimeoutNS = UInt64(max(0, sasConfirmTimeout) * 1_000_000_000)
        self.finTimeoutNS = UInt64(max(0, finTimeout) * 1_000_000_000)
    }

    // MARK: - Public API

    /// Execute one full pairing exchange against the currently-connected earbud.
    ///
    /// - Parameters:
    ///   - peerPkSe:    Connected earbud's SE pk (32 B) from attestation  (unused in body)
    ///   - peerMaterial: Connected earbud's material (1568 B)              (unused in body)
    ///   - peerEid:     Connected earbud's eid SHA-256(pkSe) (32 B)       (unused in body)
    ///   - ownPkSe:    OTHER earbud's SE pk (32 B) relayed by other phone
    ///   - ownMaterial: OTHER earbud's material (1568 B): pk_pq on first call; ct_ee on second
    ///   - ownEid:     SHA-256(ownPkSe) (32 B)
    ///   - isConfirmed: CL-2.2 SAS gate. Suspends until a person has compared the words derived from the
    ///                  32-byte `pair_id` (`EarbudPairTranscript.sasWords`) with the other phone and
    ///                  answered; `EarbudSasPrompter.ask` is the usual implementation. It runs after
    ///                  PAIR_RESP has been parsed and BEFORE PAIR_FIN is written. `false`, or no answer
    ///                  within `sasConfirmTimeout`, aborts with `.sasRejected` and PAIR_FIN is never sent.
    ///                  The closure must return when its task is cancelled (the timeout cancels it).
    ///                  There is no default on purpose: a silent `{ _ in true }` is the bypass this gate
    ///                  exists to remove.
    public func pairWithPeer(
        peerPkSe: Data, peerMaterial: Data, peerEid: Data,
        ownPkSe: Data, ownMaterial: Data, ownEid: Data,
        isConfirmed: @escaping @Sendable (Data) async -> Bool
    ) async -> PairResult {
        guard gatt.isConnected else { return .defer(reason: "earbud_not_connected") }

        // PAIR_BEGIN payload = ownPkSe || ownMaterial || ownEid (other earbud's data)
        let beginPayload = EarbudPairGatt.buildPairBegin(
            ownPkSe: ownPkSe, ownMaterial: ownMaterial, ownEid: ownEid)

        // c5: write PAIR_BEGIN (1632 B fragmented)
        do {
            try await withThrowingTimeout(nanoseconds: Self.pairingTimeoutNS) { [gatt] in
                try await gatt.writePairBegin(beginPayload)
            }
        } catch {
            return .defer(reason: "pair_begin_failed:\(error)")
        }

        // c6: read PAIR_RESP (4 × 408 B). The earbud copies the PAIR_RESP on the first chunk-index
        // write, so from here on a failure leaves it holding this attempt's PAIR_RESP.
        let pairRespData: Data
        do {
            pairRespData = try await withThrowingTimeout(nanoseconds: Self.pairingTimeoutNS) { [gatt] in
                try await gatt.readPairResp()
            }
        } catch {
            return .defer(reason: "pair_resp_error:\(error)", pairRespCached: true)
        }

        guard let resp = EarbudPairGatt.parsePairResp(pairRespData) else {
            return .defer(reason: "pair_resp_parse_failed", pairRespCached: true)
        }

        // Role: INITIATOR = lex-lesser eid (unsigned byte comparison, Swift UInt8)
        let selfIsInitiator = EarbudPairTranscript.isInitiator(selfEid: ownEid, peerEid: resp.eid)
        let eidI = selfIsInitiator ? ownEid  : resp.eid
        let eidR = selfIsInitiator ? resp.eid : ownEid

        let computedPairId = EarbudPairTranscript.pairId(eidA: ownEid, eidB: resp.eid)

        // ct_ee is always in the RESPONDER's material field
        let ctEe = selfIsInitiator ? resp.material : ownMaterial

        let sha256CtEe = Data(SHA256.hash(data: ctEe))
        let confirm = EarbudPairGatt.buildPairFin(
            pairId: computedPairId, eidI: eidI, eidR: eidR, sha256CtEe: sha256CtEe)

        // CL-2.2 — SAS gate: nothing is written to PAIR_FIN until a person has confirmed the words derived
        // from computedPairId. pair_id binds both earbud identities, so a relay that swapped an identity
        // on the way gives the two people two different word lists. Fail closed: a "no", no answer within
        // the timeout, or a cancelled task all end the pairing here.
        let confirmed = await waitForConfirmation(pairId: computedPairId, isConfirmed: isConfirmed)
        guard confirmed else {
            return .sasRejected(pairId: computedPairId)
        }

        // c7: write PAIR_FIN (32 B confirm hash). The write waits in the GATT client's operation gate behind
        // any other operation of the shared client (a DIAG poll, a key import). `finTimeout` bounds only that
        // wait: when it runs out the call is cancelled. A PAIR_FIN still queued in the gate then leaves the queue
        // and is NOT sent later: it is withdrawn and reported as failed, with nothing written. A PAIR_FIN that has
        // already left the gate is not abandoned, because the earbud may hold the frame and seal the pairing: its
        // own answer decides (the client bounds it with its 45 s per-operation timeout). If that answer is lost
        // (link drop, the operation timeout), the earbud may still have sealed the pairing and it is reported as
        // failed.
        do {
            try await withCancellationAtDeadline(nanoseconds: finTimeoutNS) { [gatt] in
                try await gatt.writePairFin(confirm)
            }
        } catch {
            return .defer(reason: "pair_fin_failed:\(error)", pairRespCached: true)
        }

        // Pass ctEe only when connected earbud was RESPONDER (selfIsInitiator=true →
        // ctEe came from resp.material, i.e. earbud generated ct_ee).
        let ctEeOut: Data? = selfIsInitiator ? ctEe : nil
        return .success(pairId: computedPairId, ctEe: ctEeOut)
    }

    // MARK: - SAS gate

    /// Races the person's answer against the timeout. The loser is cancelled; a gate that ignores
    /// cancellation would hold this call open past the timeout, which is why `isConfirmed` must return
    /// when cancelled.
    private func waitForConfirmation(
        pairId: Data,
        isConfirmed: @escaping @Sendable (Data) async -> Bool
    ) async -> Bool {
        let timeoutNS = sasConfirmTimeoutNS
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await isConfirmed(pairId) }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNS)
                } catch {
                    return false   // cancelled because the answer came first: ignored
                }
                return false       // timed out: not confirmed
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Timeout helpers

private enum DeadlineOutcome<T: Sendable>: Sendable {
    case finished(T)
    case deadline
}

/// Runs `operation` and cancels it when `nanoseconds` have passed, but keeps waiting for it: the result is
/// the operation's own, never the deadline's. An operation that is still waiting and honours cancellation (a
/// queued `EarbudSerialGate.run`) ends with `CancellationError` without having started; one that has already
/// started and does not react to cancellation (a write waiting for the earbud's answer) runs to its end and
/// reports what really happened. `withThrowingTimeout` abandons the operation at the deadline instead, which
/// is wrong for a write that may already have reached the earbud.
private func withCancellationAtDeadline<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: DeadlineOutcome<T>.self) { group in
        group.addTask {
            let value = try await operation()
            return .finished(value)
        }
        group.addTask {
            // A cancelled sleep (the operation finished first, or the caller was cancelled) ends this child too.
            try? await Task.sleep(nanoseconds: nanoseconds)
            return .deadline
        }
        while let outcome = try await group.next() {
            switch outcome {
            case .finished(let value):
                group.cancelAll()
                return value
            case .deadline:
                group.cancelAll()   // withdraws the operation if it still waits; one that has started goes on
            }
        }
        throw CancellationError()
    }
}

private func withThrowingTimeout<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

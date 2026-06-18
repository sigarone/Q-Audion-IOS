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
///   PAIR_FIN write                    : 10 s
public final class EarbudPairingRelay {

    // MARK: - Result

    public enum PairResult {
        /// Pairing complete. `pairId` is the canonical 32-byte pair identifier.
        case success(pairId: Data)
        /// Transient failure — retry after reconnection or fresh attestation.
        case `defer`(reason: String)
    }

    // MARK: - Private constants

    private static let pairingTimeoutNS: UInt64 = 60 * 1_000_000_000
    private static let finTimeoutNS:     UInt64 = 10 * 1_000_000_000

    // MARK: - Init

    private let gatt: EarbudPairingGattProxy

    public init(gatt: EarbudPairingGattProxy) { self.gatt = gatt }

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
    ///   - isConfirmed: CL-5.3 SAS gate — called with `computedPairId` before PAIR_FIN is
    ///                  sent. Must return true for the ceremony to complete. The default
    ///                  `{ _ in true }` skips the gate (use for dev/diag only). Production
    ///                  callers pass `{ SasVerificationStore.shared.isEarbudPairConfirmed(pairId: $0) }`.
    ///                  EarbudPairingRelay lives in QAudionEngine (no app-layer imports), so
    ///                  the store dependency is injected via this closure rather than directly.
    public func pairWithPeer(
        peerPkSe: Data,  peerMaterial: Data,  peerEid: Data,
        ownPkSe: Data,   ownMaterial: Data,   ownEid: Data,
        isConfirmed: @escaping (Data) -> Bool = { _ in true }
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

        // c6: read PAIR_RESP (4 × 408 B)
        let pairRespData: Data
        do {
            pairRespData = try await withThrowingTimeout(nanoseconds: Self.pairingTimeoutNS) { [gatt] in
                try await gatt.readPairResp()
            }
        } catch {
            return .defer(reason: "pair_resp_error:\(error)")
        }

        guard let resp = EarbudPairGatt.parsePairResp(pairRespData) else {
            return .defer(reason: "pair_resp_parse_failed")
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

        // CL-5.3 — SAS gate: require out-of-band user confirmation before PAIR_FIN.
        // pair_id binds both earbud identities + ct_ee; a relay-MITM who swaps ct_ee
        // would produce a different pair_id and therefore fail this check.
        // The `isConfirmed` closure is injected by the caller; production callers pass
        // SasVerificationStore.isEarbudPairConfirmed; dev/diag passes `{ _ in true }`.
        guard isConfirmed(computedPairId) else {
            return .defer(reason: "sas_not_confirmed_for_pair_id:\(computedPairId.prefix(4).map { String(format: "%02x", $0) }.joined())…")
        }

        // c7: write PAIR_FIN (32 B confirm hash)
        do {
            try await withThrowingTimeout(nanoseconds: Self.finTimeoutNS) { [gatt] in
                try await gatt.writePairFin(confirm)
            }
        } catch {
            return .defer(reason: "pair_fin_failed:\(error)")
        }

        return .success(pairId: computedPairId)
    }
}

// MARK: - Timeout helper

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

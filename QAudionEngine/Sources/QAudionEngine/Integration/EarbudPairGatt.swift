import CryptoKit
import Foundation

/// Wire builders for the qa-earbud-excl-v2 GATT pairing protocol (FE-5 / CL-5.5).
///
/// Mirror of Android EarbudPairGatt.kt. All sizes FROZEN cross-platform.
///
/// PAIR_BEGIN (c5, 1632B): pk_se(32) || material(1568) || eid(32)
///   material = pk_pq when own role is INITIATOR, or ct_ee after RESPONDER encap.
///
/// PAIR_FIN (c7, 32B): SHA-256("qa-earbud-excl-sas-confirm-v2" ||
///                               pair_id(32) || eid_I(32) || eid_R(32) || sha256_ct_ee(32))
///   Takes sha256(ct_ee) ALREADY HASHED (32B) — the phone computes this from the
///   PAIR_RESP material. EarbudPairTranscript.confirmHash takes raw ct_ee instead.
public enum EarbudPairGatt {

    // MARK: - PAIR_BEGIN

    /// Build the 1632B PAIR_BEGIN payload.
    ///
    /// - Parameters:
    ///   - ownPkSe:    Own SE identity key, 32 B
    ///   - ownMaterial: ML-KEM ek (1568B) when INITIATOR; ct_ee (1568B) when RESPONDER
    ///   - ownEid:     SHA-256(ownPkSe), 32 B
    public static func buildPairBegin(ownPkSe: Data, ownMaterial: Data, ownEid: Data) -> Data {
        precondition(ownPkSe.count == 32, "pk_se must be 32 B")
        precondition(ownMaterial.count == 1568, "material must be 1568 B")
        precondition(ownEid.count == 32, "eid must be 32 B")
        var buf = Data(capacity: EarbudGattConstants.EE_PAIR_MSG_LEN)
        buf.append(ownPkSe)
        buf.append(ownMaterial)
        buf.append(ownEid)
        return buf
    }

    // MARK: - PAIR_FIN

    /// Build the 32B PAIR_FIN confirm hash.
    ///
    /// confirm = SHA-256("qa-earbud-excl-sas-confirm-v2" ||
    ///                    pair_id(32) || eid_I(32) || eid_R(32) || sha256_ct_ee(32))
    ///
    /// - Parameters:
    ///   - pairId:     32B from EarbudPairTranscript.pairId
    ///   - eidI:       INITIATOR eid (lex-lesser), 32 B
    ///   - eidR:       RESPONDER eid (lex-greater), 32 B
    ///   - sha256CtEe: SHA-256(ct_ee) — already hashed, 32 B
    public static func buildPairFin(pairId: Data, eidI: Data, eidR: Data, sha256CtEe: Data) -> Data {
        precondition(pairId.count == 32 && eidI.count == 32 &&
                     eidR.count == 32 && sha256CtEe.count == 32)
        let label = Data("qa-earbud-excl-sas-confirm-v2".utf8)
        var h = SHA256()
        h.update(data: label)
        h.update(data: pairId)
        h.update(data: eidI)
        h.update(data: eidR)
        h.update(data: sha256CtEe)
        return Data(h.finalize())
    }

    // MARK: - PAIR_RESP

    public struct ParsedPairResp {
        public let pkSe: Data      // 32 B — peer SE identity key
        public let material: Data  // 1568 B — ct_ee (RESPONDER) or pk_pq (INITIATOR)
        public let eid: Data       // 32 B — peer eid
    }

    /// Parse a 1632B PAIR_RESP payload into its components.
    /// Returns nil if payload size != EE_PAIR_MSG_LEN.
    public static func parsePairResp(_ payload: Data) -> ParsedPairResp? {
        guard payload.count == EarbudGattConstants.EE_PAIR_MSG_LEN else { return nil }
        return ParsedPairResp(
            pkSe: Data(payload[0..<32]),
            material: Data(payload[32..<1600]),
            eid: Data(payload[1600..<1632])
        )
    }
}

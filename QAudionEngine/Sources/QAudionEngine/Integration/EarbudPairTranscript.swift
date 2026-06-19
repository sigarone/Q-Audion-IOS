import CryptoKit
import Foundation

/// Public-transcript helpers for qa-earbud-excl-v2 pairing (FE-5 / CL-5.4).
///
/// Mirror of Android EarbudPairTranscript.kt. Frozen contract — any label or
/// ordering change requires cross-platform KAT update (firmware, Android, iOS).
///
///   pair_id  = SHA-256("qa-earbud-excl-pair-v2" || eid_min || eid_max)
///   confirm  = SHA-256("qa-earbud-excl-sas-confirm-v2" ||
///                       pair_id(32) || eid_I(32) || eid_R(32) || sha256_ct_ee(32))
///
/// Role: eid_I = unsigned-lex-lesser (INITIATOR sends first PAIR_BEGIN).
///       eid_R = unsigned-lex-greater (RESPONDER replies with ct_ee).
/// Swift Data bytes are UInt8 — `<` is already unsigned, no masking needed.
public enum EarbudPairTranscript {

    /// pair_id = SHA-256("qa-earbud-excl-pair-v2" || eid_min || eid_max).
    /// eid_min is the unsigned-lex-lesser of the two 32-B eids.
    /// Symmetric: pairId(a, b) == pairId(b, a).
    public static func pairId(eidA: Data, eidB: Data) -> Data {
        precondition(eidA.count == 32 && eidB.count == 32, "eids must be 32 B")
        let label = Data("qa-earbud-excl-pair-v2".utf8)
        let (mn, mx) = lexLess(eidA, eidB) ? (eidA, eidB) : (eidB, eidA)
        var h = SHA256()
        h.update(data: label)
        h.update(data: mn)
        h.update(data: mx)
        return Data(h.finalize())
    }

    /// confirm = SHA-256("qa-earbud-excl-sas-confirm-v2" ||
    ///                    pair_id(32) || eid_I(32) || eid_R(32) || sha256_ct_ee(32)).
    ///
    /// - Parameters:
    ///   - pairId: 32 B from `pairId(eidA:eidB:)`
    ///   - eidI:   INITIATOR eid (lexicographically lesser)
    ///   - eidR:   RESPONDER eid (lexicographically greater)
    ///   - ctEe:   Raw 1568-B ciphertext from PAIR_RESP material (SHA-256 is computed here)
    public static func confirmHash(pairId: Data, eidI: Data, eidR: Data, ctEe: Data) -> Data {
        precondition(pairId.count == 32 && eidI.count == 32 && eidR.count == 32)
        let label = Data("qa-earbud-excl-sas-confirm-v2".utf8)
        let sha256CtEe = Data(SHA256.hash(data: ctEe))
        var h = SHA256()
        h.update(data: label)
        h.update(data: pairId)
        h.update(data: eidI)
        h.update(data: eidR)
        h.update(data: sha256CtEe)
        return Data(h.finalize())
    }

    /// True when selfEid is the INITIATOR (unsigned-lex-lesser eid).
    public static func isInitiator(selfEid: Data, peerEid: Data) -> Bool {
        lexLess(selfEid, peerEid)
    }

    /// Unsigned-lexicographic less-than for two Data values (byte-by-byte, first difference decides).
    private static func lexLess(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) {
            if x != y { return x < y }
        }
        return false
    }
}

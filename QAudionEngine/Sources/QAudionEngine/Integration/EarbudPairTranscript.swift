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

    // MARK: - SAS words of a pairing (CL-2.2)

    /// Bytes of `pair_id` the words are drawn from: 3 bytes per word, `SasConstants.wordCount` words.
    public static let sasEntropyBytes = 3 * SasConstants.wordCount

    /// The words a person compares between the two phones before PAIR_FIN is written.
    ///
    /// The earbud firmware has no word-form SAS for pairing (`ee_pair.c` only checks the
    /// public-transcript hash of `confirmHash`), so the words are a pure view of the 32-byte
    /// `pair_id` both phones derive from the two eids they actually sent to / received from their own
    /// earbud: when a relay substituted an earbud identity on the way the two pair_ids differ, and so
    /// do the two word lists. Nothing on the wire changes and no new KDF, label or hash is involved
    /// (`pair_id` is already a SHA-256 output).
    ///
    /// Byte-for-byte the Android `EarbudPairTranscript.sasWords` (qaudion-engine, earbuddiag): the
    /// first 18 bytes of `pair_id` through `PgpSasWords.wordsFromEntropy`, which reads each 3-byte group
    /// as a big-endian 24-bit integer and takes it modulo the 256-word list (`idx = uint24_be % 256`).
    /// 256 divides 2^24, so the index is the last byte of each group. The vectors of
    /// `earbud-pair-sas-v1-kat.json` pin it on both platforms.
    ///
    /// - Returns: nil when `pairId` is not exactly 32 bytes.
    public static func sasWords(pairId: Data) -> [String]? {
        guard pairId.count == 32 else { return nil }
        let b = [UInt8](pairId)
        let size = PgpSasWordList.words.count
        var words: [String] = []
        words.reserveCapacity(SasConstants.wordCount)
        for i in 0..<SasConstants.wordCount {
            let hi = Int(b[3 * i])
            let mid = Int(b[3 * i + 1])
            let lo = Int(b[3 * i + 2])
            let idx = ((hi << 16) | (mid << 8) | lo) % size
            words.append(PgpSasWordList.words[idx])
        }
        return words
    }

    /// The 16 lower-case hex characters (the first 8 bytes of `pair_id`) shown under the words as a
    /// second, independent thing to compare. Same as Android `pairIdHex.take(16)`.
    ///
    /// - Returns: nil when `pairId` is not exactly 32 bytes.
    public static func sasFingerprint(pairId: Data) -> String? {
        guard pairId.count == 32 else { return nil }
        let hex = [UInt8](pairId.prefix(8)).map { String(format: "%02x", $0) }.joined()
        return hex
    }

    /// `sasFingerprint` in groups of four, as the dialog shows it ("0a1b 2c3d 4e5f 6071"), the same
    /// layout as Android (`take(16).chunked(4).joinToString(" ")`).
    public static func sasFingerprintDisplay(pairId: Data) -> String? {
        guard let hex = sasFingerprint(pairId: pairId) else { return nil }
        var groups: [String] = []
        var start = hex.startIndex
        while start < hex.endIndex {
            let end = hex.index(start, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[start..<end]))
            start = end
        }
        return groups.joined(separator: " ")
    }

    /// Unsigned-lexicographic less-than for two Data values (byte-by-byte, first difference decides).
    private static func lexLess(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) {
            if x != y { return x < y }
        }
        return false
    }
}

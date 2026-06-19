import Foundation

/// CL-5.3 — EarbudPairingGattProxy
///
/// Extends EarbudKeyGattProxy (c1 + c3) with the three GATT operations for
/// FE-5 earbud-exclusive pairing (c5 / c6 / c7).
///
/// Wire contract (FROZEN — ee_pair.h):
///   c5 PAIR_BEGIN : phone writes 1632B fragmented; each fragment =
///                   [offset_lo][offset_hi][data…] (LE u16 byte offset)
///   c6 PAIR_RESP  : phone writes 1-byte chunk_idx (0–3), then reads 408 B × 4
///   c7 PAIR_FIN   : phone writes 32B confirm hash (single un-fragmented write)
///   c8 FP_ADV_REQUEST : phone writes ct_bind[32], reads fp_adv[32]||key_epoch_le[8]
public protocol EarbudPairingGattProxy: EarbudKeyGattProxy {

    /// c5: Write the 1632-byte PAIR_BEGIN payload in 2-byte-header fragments.
    func writePairBegin(_ payload: Data) async throws

    /// c6: Read the 1632-byte PAIR_RESP as 4 × 408-byte chunks.
    /// Writes a 1-byte chunk index (0–3) before each read.
    func readPairResp() async throws -> Data

    /// c7: Write the 32-byte PAIR_FIN confirm hash.
    func writePairFin(_ confirm: Data) async throws

    // MARK: - Phase B (c8 FP_ADV_REQUEST)

    /// c8 WRITE: Phone writes 32-byte ct_bind so the earbud computes fp_adv in-SE.
    /// ct_bind = HMAC-SHA256("q-audion-ct-bind-v1", pqcCiphertext).
    func writeFpAdvSeed(_ ctBind: Data) async throws

    /// c8 READ: Returns (fp_adv[32], key_epoch). Sequence: writeFpAdvSeed first.
    /// Earbud response = fp_adv[32] || key_epoch_le[8] (little-endian UInt64).
    func readFpAdv() async throws -> (fpAdv: Data, epoch: UInt64)
}

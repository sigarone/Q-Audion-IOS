import Foundation

/// Frozen wire sizes for the qa-earbud-excl-v2 GATT protocol (no UUIDs, see below).
/// Mirror of Android EarbudGattConstants / EarbudDiag.kt.
/// Any change requires cross-platform KAT update (firmware, Android, iOS).
// UPPER_SNAKE_CASE is deliberate: mirrors Android/firmware constant names
// byte-for-byte so cross-platform review is a direct visual diff.
// swiftlint:disable identifier_name
public enum EarbudGattConstants {

    // ── GATT UUIDs ────────────────────────────────────────────────────────────
    // Not here. The earbud GATT UUIDs live in the app target, next to the only code that
    // uses them (QAudionApp/Services/IOSEarbudGattProxy.swift, compiled only with
    // QAUDION_EARBUD), so a build without the earbud stack carries none of them. This
    // enum keeps only the frozen sizes and status codes that the hardware-independent
    // relay logic (EarbudAckPopRelay, EarbudPairGatt) and its known-answer tests use.

    // ── KEY_IMPORT sizes (FROZEN) ─────────────────────────────────────────────
    /// Total package size expected by firmware KEY_IMPORT
    public static let KEYIMPORT_PKG_LEN       = 1668
    /// Fragment header = [frag_offset: u16 BE]
    public static let KEYIMPORT_FRAG_HEADER   = 2
    /// Sentinel value written as the "frag_offset" of the PoP-INPUTS frame.
    /// 0xFFFF can never be a real fragment offset (max offset = PKG_LEN − 1 = 1667).
    public static let KEYIMPORT_POP_SENTINEL  = 0xFFFF
    /// Body of PoP-INPUTS frame (txn16+txn16+server_id32+nonce16 = 80 B)
    public static let KEYIMPORT_POP_INPUTS_LEN = 80
    /// Full PoP-INPUTS frame = header(2) + body(80) = 82 B
    public static let KEYIMPORT_POP_FRAME_LEN  = KEYIMPORT_FRAG_HEADER + KEYIMPORT_POP_INPUTS_LEN
    /// PoP returned by ATTEST_POP characteristic (32 B)
    public static let KEYIMPORT_POP_LEN        = 32

    /// KEY_IMPORT status codes (status byte of the earbud GATT response)
    public static let KEYIMPORT_ST_OK     = UInt8(0x00)
    public static let KEYIMPORT_ST_REPLAY = UInt8(0x03)

    // ── Pairing (FE-5) sizes (FROZEN) ─────────────────────────────────────────
    /// PAIR_BEGIN / PAIR_RESP payload = pk_se(32) + material(1568) + eid(32)
    public static let EE_PAIR_MSG_LEN      = 1632
    /// PAIR_FIN payload = confirm hash
    public static let EE_PAIR_FIN_LEN      = 32
    /// Each PAIR_RESP chunk returned by the earbud (4 × 408 = 1632)
    public static let EE_PAIR_RESP_CHUNK   = 408
    public static let EE_PAIR_RESP_NCHUNKS = 4
    /// Fragment header for pair messages = [chunk_idx: u8]
    public static let EE_PAIR_FRAG_HDR     = 2
}
// swiftlint:enable identifier_name

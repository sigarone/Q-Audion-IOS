import Foundation

/// Frozen wire constants for the qa-earbud-excl-v2 GATT protocol.
/// Mirror of Android EarbudGattConstants / EarbudDiag.kt.
/// Any change requires cross-platform KAT update (firmware, Android, iOS).
public enum EarbudGattConstants {

    // ── GATT UUIDs ────────────────────────────────────────────────────────────
    /// Primary earbud service
    public static let SERVICE_UUID      = "f2c0aaaa-bcc0-4001-8000-000000000001"
    /// KEY_IMPORT characteristic (c3) — sovereign + hw_only relay
    public static let KEY_IMPORT_UUID   = "f2c0aaaa-bcc0-4001-8000-0000000000c3"
    /// ATTEST_POP characteristic (c1) — 32-byte SE PoP after import
    public static let ATTEST_POP_UUID   = "f2c0aaaa-bcc0-4001-8000-0000000000c1"
    /// ATTEST characteristic (c2)
    public static let ATTEST_UUID       = "f2c0aaaa-bcc0-4001-8000-0000000000c2"
    /// PAIR_BEGIN (c5) — initiator writes 1632B fragmented
    public static let PAIR_BEGIN_UUID   = "f2c0aaaa-bcc0-4001-8000-0000000000c5"
    /// PAIR_RESP (c6) — reads 4 × 408B chunks
    public static let PAIR_RESP_UUID    = "f2c0aaaa-bcc0-4001-8000-0000000000c6"
    /// PAIR_FIN (c7) — writes 32B confirm hash
    public static let PAIR_FIN_UUID     = "f2c0aaaa-bcc0-4001-8000-0000000000c7"

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

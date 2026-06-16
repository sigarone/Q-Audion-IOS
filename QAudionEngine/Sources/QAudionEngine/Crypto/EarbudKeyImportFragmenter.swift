import Foundation

/// Splits the 1668-byte sovereign KEY_IMPORT package (§3.3) into GATT
/// write frames of `[frag_offset: u16 BE][payload]`. The firmware
/// reassembler is offset-indexed and requires each fragment to EXTEND a
/// contiguous prefix (firmware/nspe/src/transport/qaudion_gatt.c
/// key_import_write: `foff > received` is rejected as a forward gap), so
/// offsets are the absolute byte position in the package, big-endian, and
/// the chunks cover the package contiguously with no gaps/overlaps. The
/// firmware also requires `len >= 3` ([off:2][>=1 data]) — `mtuPayload`
/// is the per-fragment payload size and MUST be >= 1.
///
/// It also builds the §3.4 qa-kms-pop-v1 PoP-INPUTS frame, which the relay
/// MUST write to KEY_IMPORT (0xc3) BEFORE the package fragments so the SE
/// computes the PoP over its in-SE wrap secret during the final-fragment
/// import. (Firmware `KEYIMPORT_POP_SENTINEL=0xFFFF`,
/// `KEYIMPORT_POP_INPUTS_LEN=80`, layout
/// `txn_id(16)||key_id(16)||server_id(32)||server_nonce(16)`.)
public enum EarbudKeyImportFragmenter {
    /// firmware KEYIMPORT_POP_SENTINEL — the frag-offset value that flags a
    /// PoP-INPUTS write instead of a package fragment (0xFFFF can never be a
    /// real fragment: the max valid offset is KEYIMPORT_PKG_LEN = 1668).
    public static let popSentinel: UInt16 = 0xFFFF
    /// firmware KEYIMPORT_POP_INPUTS_LEN — the body length (16+16+32+16).
    public static let popInputsBodyLen = 80

    public static func fragment(_ pkg: Data, mtuPayload: Int) -> [Data] {
        precondition(mtuPayload > 0, "mtuPayload must be positive")
        var frames: [Data] = []
        var offset = 0
        let bytes = [UInt8](pkg)
        while offset < bytes.count {
            let end = min(offset + mtuPayload, bytes.count)
            var frame = Data(capacity: 2 + (end - offset))
            frame.append(UInt8((offset >> 8) & 0xFF))
            frame.append(UInt8(offset & 0xFF))
            frame.append(contentsOf: bytes[offset..<end])
            frames.append(frame)
            offset = end
        }
        return frames
    }

    /// Build the 82-byte §3.4 PoP-INPUTS frame the relay writes to
    /// KEY_IMPORT (0xc3) before the package fragments:
    ///
    ///   [0xFF,0xFF] (popSentinel, u16 BE)
    ///   || txn_id(16) || key_id(16) || server_id(32) || server_nonce(16)
    ///   = 2 + 80 = 82 bytes.
    ///
    /// Byte order is FROZEN by the firmware staging at
    /// qaudion_gatt.c key_import_write (`memcpy s_keyimport_pop_in`) and
    /// the SE consumption at sovkey_import.c (offsets +0/+16/+32/+64). The
    /// SE binds the PoP to `device_id = earbud_id[:16]` (G2) INTERNALLY —
    /// it is NOT carried in this frame. `server_id` is the provisioned
    /// constant SHA-256("qa-kms-server-id-v1|" || KMS.ServerIdentity), the
    /// SAME 32 bytes used for the phone-held PoP (CryptoConstants.kmsServerId()).
    public static func popInputsFrame(
        txnId: UUID, keyId: UUID, serverId: Data, serverNonce: Data
    ) -> Data {
        precondition(serverId.count == 32, "server_id must be 32B SHA-256")
        precondition(serverNonce.count == 16, "server_nonce must be 16B")
        var frame = Data(capacity: 2 + popInputsBodyLen)
        frame.append(UInt8((popSentinel >> 8) & 0xFF))   // 0xFF
        frame.append(UInt8(popSentinel & 0xFF))          // 0xFF
        frame.append(KmsTransport.uuidBytes(txnId))      // +0  txn_id(16)
        frame.append(KmsTransport.uuidBytes(keyId))      // +16 key_id(16)
        frame.append(serverId)                           // +32 server_id(32)
        frame.append(serverNonce)                        // +64 server_nonce(16)
        return frame
    }
}

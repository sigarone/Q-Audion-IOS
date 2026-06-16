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
public enum EarbudKeyImportFragmenter {
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
}

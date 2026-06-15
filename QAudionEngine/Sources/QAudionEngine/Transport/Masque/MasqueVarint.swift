import Foundation

/// QUIC variable-length integer codec (RFC 9000 §16).
///
/// The two most-significant bits of the first byte encode the total length:
///   00 → 1 byte  (6-bit value, 0…63)
///   01 → 2 bytes (14-bit value)
///   10 → 4 bytes (30-bit value)
///   11 → 8 bytes (62-bit value)
///
/// Used by the MASQUE CONNECT-UDP data plane: HTTP Datagram payloads carry a
/// varint Context ID (RFC 9298 §5) and HTTP/3 datagrams a varint Quarter
/// Stream ID (RFC 9297 §2.1). Pure value logic — no platform dependency, so
/// it compiles and unit-tests on every target without WebRTC / QUIC.
public enum MasqueVarint {

    /// Largest value representable in a 62-bit QUIC varint.
    public static let maxValue: UInt64 = (1 << 62) - 1

    /// Encode `value` (must be ≤ `maxValue`) to its minimal QUIC varint form.
    public static func encode(_ value: UInt64) -> [UInt8] {
        if value <= 63 {
            return [UInt8(value)]                                    // prefix 00
        } else if value <= 16383 {
            let v = UInt16(value) | 0x4000                           // prefix 01
            return [UInt8(v >> 8), UInt8(v & 0xFF)]
        } else if value <= 1_073_741_823 {
            let v = UInt32(value) | 0x8000_0000                      // prefix 10
            return [
                UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
            ]
        } else {
            let v = (value & maxValue) | 0xC000_0000_0000_0000       // prefix 11
            var out = [UInt8]()
            out.reserveCapacity(8)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((v >> UInt64(shift)) & 0xFF))
            }
            return out
        }
    }

    /// Decode a varint from the front of `bytes`.
    /// Returns the decoded value plus how many bytes it consumed, or `nil`
    /// when the slice is too short to hold the announced length.
    public static func decode(_ bytes: ArraySlice<UInt8>) -> (value: UInt64, length: Int)? {
        guard let first = bytes.first else { return nil }
        let prefix = Int(first >> 6)
        let length = 1 << prefix                                     // 1, 2, 4 or 8
        guard bytes.count >= length else { return nil }
        let start = bytes.startIndex
        var value = UInt64(first & 0x3F)
        var i = 1
        while i < length {
            value = (value << 8) | UInt64(bytes[start + i])
            i += 1
        }
        return (value, length)
    }
}

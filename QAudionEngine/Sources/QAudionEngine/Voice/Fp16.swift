import Foundation

/// The one shared float32 <-> binary16 converter of the template record: written on the bit patterns with integer
/// arithmetic only, so a record does not depend on the half-float support of a device. A pattern is an Int in 0...0xFFFF.
///
/// Float32 to binary16 rounds to nearest, ties to even; 65520 and above is infinity; 2^-25 and below is zero with the sign;
/// infinity keeps its sign and every NaN becomes 0x7E00 (sign kept, payload dropped). Binary16 to float32 is exact for every
/// finite pattern.
enum Fp16 {
    static let inf = 0x7C00
    static let nan = 0x7E00

    static func fromFloat(_ x: Float) -> Int {
        fromBits(x.bitPattern)
    }

    static func fromBits(_ rawBits: UInt32) -> Int {
        let bits = Int(rawBits)
        let sign = (bits >> 16) & 0x8000
        let a = bits & 0x7FFF_FFFF
        if a >= 0x7F80_0000 { return sign | (a == 0x7F80_0000 ? inf : nan) }
        if a >= 0x477F_F000 { return sign | inf } // 65520 and above
        if a >= 0x3880_0000 { // 2^-14 and above: normal binary16
            let m = a - 0x3800_0000
            return sign | ((m + 0x0FFF + ((m >> 13) & 1)) >> 13)
        }
        if a <= 0x3300_0000 { return sign } // 2^-25 and below (the tie at 2^-25 goes to the even neighbour, zero)
        let e = a >> 23
        let mant = (a & 0x7F_FFFF) | 0x80_0000
        let shift = 126 - e // 14...24
        var h = mant >> shift
        let rem = mant & ((1 << shift) - 1)
        let half = 1 << (shift - 1)
        if rem > half || (rem == half && (h & 1) == 1) { h += 1 } // may become 0x400, the smallest normal: correct
        return sign | h
    }

    static func toFloat(_ h: Int) -> Float {
        Float(bitPattern: toBits(h))
    }

    static func toBits(_ h: Int) -> UInt32 {
        let sign = (h & 0x8000) << 16
        let e = (h >> 10) & 0x1F
        let m = h & 0x3FF
        if e == 31 { return UInt32(sign | 0x7F80_0000 | (m << 13)) }
        if e == 0 {
            if m == 0 { return UInt32(sign) }
            let sh = 11 - (Int.bitWidth - m.leadingZeroBitCount)
            return UInt32(sign | ((127 - 14 - sh) << 23) | (((m << sh) & 0x3FF) << 13))
        }
        return UInt32(sign | ((e + 112) << 23) | (m << 13))
    }

    /// False for infinity and NaN (all five exponent bits set).
    static func isFinite(_ h: Int) -> Bool {
        ((h >> 10) & 0x1F) != 31
    }
}

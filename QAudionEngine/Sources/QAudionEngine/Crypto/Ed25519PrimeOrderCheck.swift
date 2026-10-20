import Foundation

/// Subgroup test for a peer's Ed25519 identity key (docs/security/NFC_PAIRING_V2.md section 3).
///
/// `Ed25519IdentityKeyPolicy` refuses the 8 small-order encodings and the non-canonical ones by table. That is not
/// enough on its own: a mixed-order point `A + T` (T a torsion point) has a canonical encoding, is not in the table
/// and still decodes. This type decodes the point strictly (RFC 8032 section 5.1.3: y < p, a point that is on the
/// curve, no negative zero) and checks `[l]A = O`, which holds exactly for the points of the prime-order subgroup.
///
/// The keys it looks at are public, so nothing here is constant time. The arithmetic is a plain 256-bit field
/// implementation over 32-bit limbs (p = 2^255 - 19) and complete extended-coordinate addition; it needs no
/// inversion and no library support, so the answer does not depend on what CryptoKit happens to accept.
public enum Ed25519PrimeOrderCheck {

    /// True when `key` is a canonical encoding of a point with `[l]A = O` (the prime-order subgroup, neutral element included).
    public static func isPrimeOrderSubgroupPoint(_ key: Data) -> Bool {
        guard key.count == 32 else { return false }
        guard let point = Curve.decode([UInt8](key)) else { return false }
        let multiple = Curve.scalarMultiply(point, by: Curve.groupOrderLimbs)
        // [l]A = O in extended coordinates: X = 0 and Y = Z. The neutral element passes this test (it lies in every
        // subgroup); `isAcceptableIdentityKey` refuses it through the small-order table.
        return multiple.x.isZero && multiple.y == multiple.z
    }

    /// The whole rule for a peer identity key: `Ed25519IdentityKeyPolicy.isAcceptable` (32 bytes, not in the
    /// small-order table, canonical) and the subgroup test above.
    public static func isAcceptableIdentityKey(_ key: Data) -> Bool {
        Ed25519IdentityKeyPolicy.isAcceptable(key) && isPrimeOrderSubgroupPoint(key)
    }

    // MARK: - Field elements modulo p = 2^255 - 19

    /// A field element: 8 little-endian 32-bit limbs, always fully reduced (value < p).
    struct Fe: Equatable {
        var limbs: [UInt32]

        static let p: [UInt32] = [0xFFFF_FFED, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF,
                                  0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0x7FFF_FFFF]
        static let zero = Fe(limbs: [UInt32](repeating: 0, count: 8))
        static let one = Fe(small: 1)

        init(limbs: [UInt32]) {
            self.limbs = limbs
        }

        init(small value: UInt32) {
            var l = [UInt32](repeating: 0, count: 8)
            l[0] = value
            self.limbs = l
        }

        var isZero: Bool {
            limbs.allSatisfy { $0 == 0 }
        }

        /// True when the value is odd (bit 0 of the canonical value).
        var isOdd: Bool {
            limbs[0] & 1 == 1
        }

        /// The 32 little-endian bytes with the top bit forced to zero by the caller's mask; no reduction.
        static func fromBytes(_ bytes: [UInt8]) -> Fe {
            var l = [UInt32](repeating: 0, count: 8)
            for i in 0..<8 {
                let b = i * 4
                l[i] = UInt32(bytes[b]) | (UInt32(bytes[b + 1]) << 8) | (UInt32(bytes[b + 2]) << 16) | (UInt32(bytes[b + 3]) << 24)
            }
            return Fe(limbs: l)
        }

        static func greaterOrEqual(_ a: [UInt32], _ b: [UInt32]) -> Bool {
            var i = 7
            while i >= 0 {
                if a[i] > b[i] { return true }
                if a[i] < b[i] { return false }
                i -= 1
            }
            return true
        }

        static func subtractRaw(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
            var r = [UInt32](repeating: 0, count: 8)
            var borrow: Int64 = 0
            for i in 0..<8 {
                var d = Int64(a[i]) - Int64(b[i]) - borrow
                if d < 0 {
                    d += 4_294_967_296
                    borrow = 1
                } else {
                    borrow = 0
                }
                r[i] = UInt32(truncatingIfNeeded: d)
            }
            return r
        }

        /// Reduces `t + carry * 2^256` (carry small) to the canonical value below p.
        static func normalize(_ value: [UInt32], carry: UInt64) -> Fe {
            var t = value
            var c = carry
            while c != 0 {
                var acc = c * 38
                for i in 0..<8 {
                    acc += UInt64(t[i])
                    t[i] = UInt32(truncatingIfNeeded: acc)
                    acc >>= 32
                }
                c = acc
            }
            // 2^256 = 2p + 38, so at most two subtractions bring the value below p.
            for _ in 0..<2 where greaterOrEqual(t, p) {
                t = subtractRaw(t, p)
            }
            return Fe(limbs: t)
        }

        static func add(_ a: Fe, _ b: Fe) -> Fe {
            var r = [UInt32](repeating: 0, count: 8)
            var acc: UInt64 = 0
            for i in 0..<8 {
                acc += UInt64(a.limbs[i]) + UInt64(b.limbs[i])
                r[i] = UInt32(truncatingIfNeeded: acc)
                acc >>= 32
            }
            return normalize(r, carry: acc)
        }

        static func sub(_ a: Fe, _ b: Fe) -> Fe {
            var r = [UInt32](repeating: 0, count: 8)
            var borrow: Int64 = 0
            for i in 0..<8 {
                var d = Int64(a.limbs[i]) - Int64(b.limbs[i]) - borrow
                if d < 0 {
                    d += 4_294_967_296
                    borrow = 1
                } else {
                    borrow = 0
                }
                r[i] = UInt32(truncatingIfNeeded: d)
            }
            if borrow == 1 {
                // a - b + 2^256 as 256 bits; adding p and dropping the carry out gives a - b + p.
                var acc: UInt64 = 0
                for i in 0..<8 {
                    acc += UInt64(r[i]) + UInt64(p[i])
                    r[i] = UInt32(truncatingIfNeeded: acc)
                    acc >>= 32
                }
            }
            return Fe(limbs: r)
        }

        static func negate(_ a: Fe) -> Fe {
            sub(zero, a)
        }

        static func mul(_ a: Fe, _ b: Fe) -> Fe {
            var t = [UInt64](repeating: 0, count: 16)
            for i in 0..<8 {
                var carry: UInt64 = 0
                let ai = UInt64(a.limbs[i])
                for j in 0..<8 {
                    let cur = t[i + j] &+ ai &* UInt64(b.limbs[j]) &+ carry
                    t[i + j] = cur & 0xFFFF_FFFF
                    carry = cur >> 32
                }
                t[i + 8] = carry
            }
            // value = lo + hi * 2^256 and 2^256 = 38 (mod p).
            var r = [UInt32](repeating: 0, count: 8)
            var acc: UInt64 = 0
            for i in 0..<8 {
                acc += t[i] + 38 * t[i + 8]
                r[i] = UInt32(truncatingIfNeeded: acc)
                acc >>= 32
            }
            return normalize(r, carry: acc)
        }

        static func square(_ a: Fe) -> Fe {
            mul(a, a)
        }

        /// `base ^ exponent` for an exponent given as 8 little-endian limbs (square and multiply, high bit first).
        static func power(_ base: Fe, exponent: [UInt32]) -> Fe {
            var result = one
            var bit = 255
            while bit >= 0 {
                result = square(result)
                if (exponent[bit / 32] >> UInt32(bit % 32)) & 1 == 1 {
                    result = mul(result, base)
                }
                bit -= 1
            }
            return result
        }

        // p - 2, (p - 5) / 8 and (p - 1) / 4 as limbs.
        static let exponentInverse: [UInt32] = [0xFFFF_FFEB, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF,
                                                0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0x7FFF_FFFF]
        static let exponentSqrtCandidate: [UInt32] = [0xFFFF_FFFD, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF,
                                                      0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0x0FFF_FFFF]
        static let exponentSqrtMinusOne: [UInt32] = [0xFFFF_FFFB, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF,
                                                     0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0x1FFF_FFFF]

        static func inverse(_ a: Fe) -> Fe {
            power(a, exponent: exponentInverse)
        }
    }

    // MARK: - The curve

    /// A point in extended coordinates (X : Y : Z : T) with x = X/Z, y = Y/Z, T = XY/Z.
    struct Point {
        var x: Fe
        var y: Fe
        var z: Fe
        var t: Fe
    }

    enum Curve {
        /// d = -121665 / 121666
        static let d: Fe = {
            let numerator = Fe.negate(Fe(small: 121665))
            return Fe.mul(numerator, Fe.inverse(Fe(small: 121666)))
        }()

        static let twoD: Fe = Fe.add(d, d)

        /// sqrt(-1) = 2 ^ ((p - 1) / 4)
        static let sqrtMinusOne: Fe = Fe.power(Fe(small: 2), exponent: Fe.exponentSqrtMinusOne)

        /// l = 2^252 + 27742317777372353535851937790883648493, the order of the prime-order subgroup.
        static let groupOrderLimbs: [UInt32] = [0x5CF5_D3ED, 0x5812_631A, 0xA2F7_9CD6, 0x14DE_F9DE,
                                                0, 0, 0, 0x1000_0000]

        static let identity = Point(x: .zero, y: .one, z: .one, t: .zero)

        /// Strict RFC 8032 section 5.1.3 decoding. Nil for y >= p, a y with no x on the curve, or x = 0 with the
        /// sign bit set.
        static func decode(_ bytes: [UInt8]) -> Point? {
            guard bytes.count == 32 else { return nil }
            let sign = (bytes[31] >> 7) & 1
            var masked = bytes
            masked[31] &= 0x7F
            let y = Fe.fromBytes(masked)
            guard !Fe.greaterOrEqual(y.limbs, Fe.p) else { return nil }
            let ySquared = Fe.square(y)
            let u = Fe.sub(ySquared, .one)
            let v = Fe.add(Fe.mul(d, ySquared), .one)
            // x = u v^3 (u v^7)^((p-5)/8)
            let v3 = Fe.mul(Fe.square(v), v)
            let v7 = Fe.mul(Fe.square(v3), v)
            let candidate = Fe.mul(Fe.mul(u, v3), Fe.power(Fe.mul(u, v7), exponent: Fe.exponentSqrtCandidate))
            var x = candidate
            let check = Fe.mul(v, Fe.square(x))
            if check != u {
                if check == Fe.negate(u) {
                    x = Fe.mul(x, sqrtMinusOne)
                } else {
                    return nil
                }
            }
            if x.isZero && sign == 1 { return nil }
            if (x.isOdd ? 1 : 0) != sign {
                x = Fe.negate(x)
            }
            return Point(x: x, y: y, z: .one, t: Fe.mul(x, y))
        }

        /// Complete addition for a = -1 (add-2008-hwcd-3); also correct for doubling and for the neutral element.
        static func add(_ p: Point, _ q: Point) -> Point {
            let a = Fe.mul(Fe.sub(p.y, p.x), Fe.sub(q.y, q.x))
            let b = Fe.mul(Fe.add(p.y, p.x), Fe.add(q.y, q.x))
            let c = Fe.mul(Fe.mul(p.t, twoD), q.t)
            let dd = Fe.mul(Fe.add(p.z, p.z), q.z)
            let e = Fe.sub(b, a)
            let f = Fe.sub(dd, c)
            let g = Fe.add(dd, c)
            let h = Fe.add(b, a)
            return Point(x: Fe.mul(e, f), y: Fe.mul(g, h), z: Fe.mul(f, g), t: Fe.mul(e, h))
        }

        /// `scalar * point`, scalar as 8 little-endian limbs, high bit first.
        static func scalarMultiply(_ point: Point, by scalar: [UInt32]) -> Point {
            var result = identity
            var bit = 255
            while bit >= 0 {
                result = add(result, result)
                if (scalar[bit / 32] >> UInt32(bit % 32)) & 1 == 1 {
                    result = add(result, point)
                }
                bit -= 1
            }
            return result
        }
    }
}

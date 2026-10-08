import Foundation

/// Acceptance rule for a 32-byte Ed25519 public key that a peer hands us as its IDENTITY.
///
/// Why it exists: a permissive (ZIP-215 style) verifier accepts the signature `01 || 0^63` made
/// under any small-order public key (for example the neutral element `01 00..00`) on EVERY message,
/// so such a "signature" proves possession of nothing. Whether CryptoKit rejects these keys is not
/// documented, so the check is explicit and independent of the library:
///   - the length must be exactly 32 bytes;
///   - the 8 canonical small-order points are refused (the table below, shared with
///     `NfcSasComputation`);
///   - NON-canonical encodings are refused: y (the low 255 bits, little-endian) must be < p = 2^255-19,
///     and a set sign bit on an x = 0 point (`01 00..00 80`, `ec ff..ff ff`) is not decodable under
///     RFC 8032 section 5.1.3.
///
/// Why those three rules cover every small-order point a permissive decoder can produce: such a decoder
/// reduces y modulo p, and the small-order points have y' in {0, 1, p-1} or one of two order-8 values.
/// A different 255-bit encoding of the same y' needs y' + p < 2^255, i.e. y' <= 18, so only y' = 0 and
/// y' = 1 have one (y = p and y = p+1, with either sign bit). All of them have y >= p, which is refused
/// outright. The remaining aliases are the x = 0 points with the sign bit set, listed explicitly. No field
/// arithmetic is needed. An honest key (CryptoKit, BouncyCastle, noble all emit the canonical encoding)
/// hits none of these cases except with probability around 2^-250.
///
/// This is NOT an on-curve test and does not replace the library's own key parsing: callers still build
/// the CryptoKit key afterwards. It only adds what the library may not check.
public enum Ed25519IdentityKeyPolicy {

    /// Length of a raw Ed25519 public key.
    public static let encodedLength = 32

    /// The 8 small-order points of the Ed25519 curve, canonical 32-byte RFC 8032 section 5.1.2
    /// little-endian encoding (byte-identical to Android's `SMALL_ORDER_POINTS`).
    private static let smallOrderHex: [String] = [
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000080",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac0374",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03f4",
    ]

    /// x = 0 points (y = 1 and y = p-1) with the sign bit set: permissive decoders accept them, RFC 8032
    /// does not (there is no negative zero).
    private static let signedZeroXHex: [String] = [
        "0100000000000000000000000000000000000000000000000000000000000080",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    ]

    /// The 8 canonical small-order points as raw bytes.
    public static let smallOrderPoints: [Data] = smallOrderHex.map { Data(Ed25519IdentityKeyPolicy.decodeHexLiteral($0)) }

    private static let smallOrderBytes: [[UInt8]] = smallOrderHex.map { Ed25519IdentityKeyPolicy.decodeHexLiteral($0) }
    private static let signedZeroXBytes: [[UInt8]] = signedZeroXHex.map { Ed25519IdentityKeyPolicy.decodeHexLiteral($0) }

    /// True when `key` is exactly one of the 8 canonical small-order encodings. This is the table check
    /// `NfcSasComputation` has always done; it does not look at non-canonical encodings.
    public static func isCanonicalSmallOrderPoint(_ key: Data) -> Bool {
        guard key.count == encodedLength else { return false }
        return smallOrderBytes.contains([UInt8](key))
    }

    /// True when the 255-bit y of `key` is >= p = 2^255-19, or when `key` is an x = 0 point with the sign
    /// bit set. Both are encodings RFC 8032 does not allow. Requires 32 bytes (false otherwise).
    public static func isNonCanonicalEncoding(_ key: Data) -> Bool {
        guard key.count == encodedLength else { return false }
        let b = [UInt8](key)
        if yIsNotReduced(b) { return true }
        return signedZeroXBytes.contains(b)
    }

    /// True when `key` may be used as a peer's Ed25519 identity key: 32 bytes, not a small-order point,
    /// not a non-canonical encoding. The rule is the same for every platform; see the type comment.
    public static func isAcceptable(_ key: Data) -> Bool {
        guard key.count == encodedLength else { return false }
        if isCanonicalSmallOrderPoint(key) { return false }
        if isNonCanonicalEncoding(key) { return false }
        return true
    }

    /// y >= p for p = 2^255-19 = 7f ff..ff ed (big-endian), so in little-endian bytes: byte 31 with the
    /// sign bit masked is 0x7f, bytes 1...30 are 0xff and byte 0 is >= 0xed.
    private static func yIsNotReduced(_ b: [UInt8]) -> Bool {
        guard b[31] & 0x7f == 0x7f, b[0] >= 0xed else { return false }
        return b[1..<31].allSatisfy { $0 == 0xff }
    }

    /// Only ever called with the literals above (even length, valid hex), never with peer input.
    private static func decodeHexLiteral(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        return out
    }
}

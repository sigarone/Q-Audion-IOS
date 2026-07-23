import Foundation
import CryptoKit

/// Phase 14c — SAS-over-NFC ceremony, computation primitive. Direct port of Android's
/// `app/.../nfc/SasComputation.kt`, byte-for-byte. Deliberately NOT `ComputeSasUseCase`
/// (the in-call, session-key-derived, 6-PGP-word ceremony) — this is a SEPARATE
/// construction, over the two peers' Ed25519 IDENTITY keys, producing 6 decimal digits,
/// used only at NFC tap-pairing time before any session/PSK exists.
///
/// ## Spec (frozen v1, must match Android exactly)
/// ```
///   pair      = sort_lex([IK_ed_self, IK_ed_peer])      // 32-byte byte arrays
///   ikm       = pair[0] || pair[1]                      // 64-byte concatenation
///   prk       = HMAC-SHA256(key: salt, msg: ikm)         // RFC 5869 HKDF-Extract
///   sas_uint  = uint32_be(prk[0..4]) mod 1_000_000
///   sas_str   = zero-pad-left(sas_uint, width=6)        // "000000" .. "999999"
/// ```
/// `salt = SasConstants.saltBytes` ("qaudion-sas-v1"). Sorting makes the function
/// commutative (`sas(a,b) == sas(b,a)`) so both devices derive the same string
/// regardless of who tapped first — no NFC-side roles transcript needed.
///
/// Three preconditions, enforced on every call (mirrors Android's `computeSas`):
/// length (32 bytes each), distinctness (self != peer — a self-handshake would let a
/// relay attacker satisfy the ceremony without ever seeing a real peer key), and
/// non-small-order (both inputs must decode to a full-order Ed25519 point — the 8
/// small-order torsion points would collapse the derivation into a 3-bit space).
public enum NfcSasComputation {

    public static let ikEdPubLen = 32
    /// Number of decimal digits in the SAS. Frozen at 6 (independent of
    /// `SasConstants.wordCount`, which is the in-call ceremony's word count).
    public static let sasDigitCount = 6

    private static let sasModulus: UInt32 = 1_000_000

    public enum SasError: Error, Equatable {
        case invalidLength
        case selfHandshake
        case smallOrderPoint
    }

    /// The 8 small-order points of the Ed25519 curve, canonical 32-byte RFC 8032 §5.1.2
    /// little-endian encoding — byte-identical table to Android's `SMALL_ORDER_POINTS`.
    private static let smallOrderPoints: [Data] = [
        Data(hex: "0100000000000000000000000000000000000000000000000000000000000000"),
        Data(hex: "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"),
        Data(hex: "0000000000000000000000000000000000000000000000000000000000000000"),
        Data(hex: "0000000000000000000000000000000000000000000000000000000000000080"),
        Data(hex: "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05"),
        Data(hex: "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85"),
        Data(hex: "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac0374"),
        Data(hex: "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03f4"),
    ]

    /// Derive the 6-digit SAS for a tap-paired peer.
    public static func computeSas(selfIkEdPub: Data, peerIkEdPub: Data) throws -> String {
        guard selfIkEdPub.count == ikEdPubLen, peerIkEdPub.count == ikEdPubLen else {
            throw SasError.invalidLength
        }
        guard !constantTimeEquals(selfIkEdPub, peerIkEdPub) else {
            throw SasError.selfHandshake
        }
        try requireNonSmallOrder(selfIkEdPub)
        try requireNonSmallOrder(peerIkEdPub)
        return computeSasUnchecked(selfIkEdPub: selfIkEdPub, peerIkEdPub: peerIkEdPub)
    }

    /// Internal derivation without input validation — used only by
    /// `NfcSasComputationKatTests`, which (like Android's own KAT self-check)
    /// pins the two frozen vectors through byte patterns (all-zeros, all-0xFF,
    /// counted bytes) that are deliberately NOT real Ed25519 points, so the
    /// public, validating `computeSas` cannot be used to exercise them —
    /// `internal` (not `private`) so `@testable import` can reach it.
    static func computeSasUnchecked(selfIkEdPub: Data, peerIkEdPub: Data) -> String {
        let first: Data
        let second: Data
        if compareUnsigned(selfIkEdPub, peerIkEdPub) <= 0 {
            first = selfIkEdPub
            second = peerIkEdPub
        } else {
            first = peerIkEdPub
            second = selfIkEdPub
        }
        var ikm = Data()
        ikm.append(first)
        ikm.append(second)

        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: SasConstants.saltBytes))
        let prkData = Data(prk)

        let sasUint = (UInt32(prkData[prkData.startIndex]) << 24)
            | (UInt32(prkData[prkData.startIndex + 1]) << 16)
            | (UInt32(prkData[prkData.startIndex + 2]) << 8)
            | UInt32(prkData[prkData.startIndex + 3])

        let digits = Int(sasUint % sasModulus)
        return String(format: "%0\(sasDigitCount)d", digits)
    }

    private static func requireNonSmallOrder(_ point: Data) throws {
        for small in smallOrderPoints where constantTimeEquals(point, small) {
            throw SasError.smallOrderPoint
        }
        // CryptoKit's Curve25519 signing key validates canonical encoding / on-curve
        // membership but is not documented to reject small-order points — the table
        // check above is the authoritative guard, matching Android's belt-and-suspenders
        // (explicit table + library validation) posture.
        guard (try? Curve25519.Signing.PublicKey(rawRepresentation: point)) != nil else {
            throw SasError.smallOrderPoint
        }
    }

    private static func compareUnsigned(_ a: Data, _ b: Data) -> Int {
        let n = min(a.count, b.count)
        for i in 0..<n {
            let ai = a[a.startIndex + i]
            let bi = b[b.startIndex + i]
            if ai != bi { return ai < bi ? -1 : 1 }
        }
        return a.count - b.count
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }
}

private extension Data {
    init(hex: String) {
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self = out
    }
}

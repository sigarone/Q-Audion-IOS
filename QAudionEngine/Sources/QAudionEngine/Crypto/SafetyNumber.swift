import Foundation
import CryptoKit

/// Persistent safety-number derivation — iOS side.
///
/// Authoritative spec: `apps/bcrypto-server/docs/WIRE_SPEC.md` §5.1.2.
/// Direct port of Android `core-trust/.../SafetyNumber.kt` (canonical
/// reference, KAT-tested against Desktop `SafetyNumber.ts`).
///
/// Goal: a 60-digit string the user verifies **once out-of-band** with the
/// peer (in person, by phone, signed letterhead) to pin the peer's
/// identity. The number is **stable** across re-keys and KMS pre-bootstrap
/// rotations — it changes ONLY when the peer rotates their `ikEdPub`. This
/// is the long-term identity-pin counterpart to the in-call freshness SAS
/// in `ComputeSasUseCase`.
///
/// **Protocol** (must match Android `SafetyNumber.kt` / Desktop
/// `SafetyNumber.ts` byte-for-byte):
/// ```
///   pair_input = canonical_cbor({
///     0: min_uuid       (16 B),     // lex-min(uuidA_raw, uuidB_raw)
///     1: max_uuid       (16 B),
///     2: min_ikEdPub    (32 B),     // ikEd belonging to min-uuid side
///     3: max_ikEdPub    (32 B),
///   })
///   prk    = HKDF-Extract(salt = empty, ikm = pair_input)
///   sn_30  = HKDF-Expand(prk, info = "q-audion-safety-number-v1", L = 30)
/// ```
///
/// Display: 12 chunks × 20 bits big-endian → modulo 100_000 → zero-padded
/// 5-digit groups. Order-invariance: lex-min/max sort over the 16-byte raw
/// UUID bytes (NOT the dashed string form) guarantees both peers compute
/// identical input regardless of which side calls the function.
///
/// KAT vector lives in `QAudionEngineTests/Crypto/SafetyNumberTests.swift`,
/// pinned against Android `SafetyNumberKatTest.kt`.
///
/// **⚠️ Crypto identity immutability:** only the immutable `userId` UUID and
/// `ikEdPub` (Ed25519 raw 32 B) feed this derivation. NEVER include phone
/// number, display name, or any mutable field — the safety number must be
/// tied only to stable cryptographic identity.
public enum SafetyNumber {

    public static let digitGroups = 12
    public static let digitsPerGroup = 5

    private static let uuidLen = 16
    private static let ikEdLen = 32
    private static let hkdfOutBytes = 30 // 240 bits → 12 × 20-bit chunks
    private static let snInfo = Data("q-audion-safety-number-v1".utf8)

    public enum SafetyNumberError: Error, Equatable {
        case badUuidLength(Int)
        case badKeyLength(Int)
        case equalUuids
    }

    public struct Result: Equatable {
        /// 12 groups of 5 digits each, e.g. ["54000","44743",...].
        public let groups: [String]
        /// Pre-joined display: "54000 44743 06999 ...".
        public let display: String
        /// Raw 30-byte HKDF output, lowercase hex. Cross-platform-safe
        /// encoding (matches Android's `fingerprintHex`).
        public let fingerprintHex: String
    }

    /// Parse a canonical dashed (or bare) UUID string into its raw 16
    /// bytes, in the same byte order as the string's hex representation
    /// (network/canonical order — matches Android's
    /// `UUID.fromString(...)` most/least-significant-bits big-endian
    /// encoding and Desktop's raw-bytes parse).
    public static func rawUuidBytes(fromUuidString s: String) -> Data? {
        let hex = s.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        var out = Data(capacity: 16)
        var idx = hex.startIndex
        for _ in 0..<16 {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// Derive the 60-digit safety number for the
    /// `(localUuidRaw, localIkEdPub, peerUuidRaw, peerIkEdPub)` pair.
    ///
    /// Both peers MUST obtain the same result regardless of which side
    /// calls the function.
    public static func compute(
        localUuidRaw: Data,
        localIkEdPub: Data,
        peerUuidRaw: Data,
        peerIkEdPub: Data
    ) throws -> Result {
        guard localUuidRaw.count == uuidLen else { throw SafetyNumberError.badUuidLength(localUuidRaw.count) }
        guard peerUuidRaw.count == uuidLen else { throw SafetyNumberError.badUuidLength(peerUuidRaw.count) }
        guard localIkEdPub.count == ikEdLen else { throw SafetyNumberError.badKeyLength(localIkEdPub.count) }
        guard peerIkEdPub.count == ikEdLen else { throw SafetyNumberError.badKeyLength(peerIkEdPub.count) }

        let cmp = lexCompare(localUuidRaw, peerUuidRaw)
        guard cmp != 0 else { throw SafetyNumberError.equalUuids }

        let minUuid = cmp < 0 ? localUuidRaw : peerUuidRaw
        let maxUuid = cmp < 0 ? peerUuidRaw : localUuidRaw
        let minIkEd = cmp < 0 ? localIkEdPub : peerIkEdPub
        let maxIkEd = cmp < 0 ? peerIkEdPub : localIkEdPub

        // Canonical CBOR map: { 0: min_uuid, 1: max_uuid, 2: min_ikEdPub, 3: max_ikEdPub }.
        // Map header for 4 entries: 0xa4.
        var ikm = Data([0xa4])
        ikm.append(cborUintByteString(key: 0, bytes: minUuid))
        ikm.append(cborUintByteString(key: 1, bytes: maxUuid))
        ikm.append(cborUintByteString(key: 2, bytes: minIkEd))
        ikm.append(cborUintByteString(key: 3, bytes: maxIkEd))

        // HKDF-Extract(salt=empty)-then-Expand in one CryptoKit call — RFC
        // 5869-compliant, matches BouncyCastle's HKDFBytesGenerator used
        // Android-side byte-for-byte (both implement the same spec).
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(),
            info: snInfo,
            outputByteCount: hkdfOutBytes
        )
        let out = derived.withUnsafeBytes { Data($0) }

        var groups = [String]()
        groups.reserveCapacity(digitGroups)
        for i in 0..<digitGroups {
            let bitOffset = i * 20
            let chunk = read20BitsBE(out, bitOffset)
            let value = chunk % 100_000
            groups.append(String(format: "%05d", value))
        }
        let display = groups.joined(separator: " ")
        let fingerprintHex = out.map { String(format: "%02x", $0) }.joined()

        return Result(groups: groups, display: display, fingerprintHex: fingerprintHex)
    }

    // MARK: - Internal

    /// Encode a CBOR `(unsigned-int -> byte-string)` map entry in canonical
    /// RFC 8949 §4.2.1 form. Used to build the safety-number IKM
    /// bit-identical to Android Kotlin and Desktop TypeScript impls.
    private static func cborUintByteString(key: Int, bytes: Data) -> Data {
        precondition((0...23).contains(key), "key out of canonical range: \(key)")
        var out = Data([UInt8(key)]) // major 0 (uint), value < 24 → the byte IS the value.
        switch bytes.count {
        case 0...23:
            out.append(UInt8(0x40 | bytes.count))
        case 24...0xff:
            out.append(contentsOf: [0x58, UInt8(bytes.count)])
        default:
            out.append(contentsOf: [
                0x59,
                UInt8((bytes.count >> 8) & 0xff),
                UInt8(bytes.count & 0xff),
            ])
        }
        out.append(bytes)
        return out
    }

    private static func lexCompare(_ a: Data, _ b: Data) -> Int {
        let len = min(a.count, b.count)
        let ab = [UInt8](a)
        let bb = [UInt8](b)
        for i in 0..<len {
            if ab[i] < bb[i] { return -1 }
            if ab[i] > bb[i] { return 1 }
        }
        return a.count - b.count
    }

    private static func read20BitsBE(_ buf: Data, _ bitOffset: Int) -> Int {
        let bytes = [UInt8](buf)
        let byteOffset = bitOffset >> 3
        let bitInByte = bitOffset & 0x7
        let b0 = Int(bytes[byteOffset])
        let b1 = Int(bytes[byteOffset + 1])
        let b2 = Int(bytes[byteOffset + 2])
        let window = (b0 << 16) | (b1 << 8) | b2
        let trailingDrop = 24 - bitInByte - 20 // 0..3
        return (window >> trailingDrop) & 0xfffff // 20-bit mask
    }
}

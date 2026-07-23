import Foundation
import CryptoKit

/// PskMix — multi-secret PSK mixing for shipOrder step 7 (multi-PSK-mixing
/// design, `keySchedule` §1-2). N=1 is the identity: `K_mix := s_1`,
/// byte-identical to every shipped peer today. N>=2 aggregates every mutually
/// held secret (ordinary PSK + NFC-derived, cap 4) into one 32-byte `K_mix`
/// via a single HMAC-then-Expand (RFC 5869 Extract-then-Expand, no second
/// Extract) so `deriveHybridSessionKey` stays unmodified — `K_mix` just
/// occupies the existing HKDF-Extract salt slot.
///
/// Byte-exact contract, mirrored in Desktop `PskMix.ts` and Android
/// `PskMix.kt`, pinned by `tools/kat/psk-mix/psk-mix-v1-kat.json`:
///
///   mix_id  = SHA-256( DOMAIN_MIX_ID(16) || u8(N) || fp_1 || ... || fp_N )        [32]
///   ikm_mix = DOMAIN_IKM(13) || u8(N) || fp_1(32)
///             || CONCAT_{i=2..N} ( fp_i(32) || u16be(32) || s_i(32) )
///   PRK_mix = HMAC-SHA256( key = s_1, msg = ikm_mix )                            [32]
///   K_mix   = HKDF-Expand( PRK_mix, info = DOMAIN_KEY(17) || u8(N) || mix_id, L=32 )
///
/// Ordering is WIRE-AUTHORITATIVE (the responder's advertised order), never
/// re-sorted here — `orderedSecrets`/`orderedFps` must already be in final
/// position order before calling these functions. This enum only implements
/// the aggregation math, not the ordering/selection wiring (a separate,
/// larger integration task).
///
/// Pure module: only CryptoKit. No app/UI deps, so the cross-platform KAT
/// exercises the real production path.
public enum PskMix {

    public static let secretBytes = 32
    public static let fpBytes = 32
    public static let keyBytes = 32
    public static let maxN = 4

    /// UTF-8 "qa-psk-mix-id-v1" — 16 bytes, `mix_id` preimage domain.
    private static let domainMixId = Data("qa-psk-mix-id-v1".utf8)
    /// UTF-8 "qa-psk-mix-v1" — 13 bytes, `ikm_mix` domain.
    private static let domainIkm = Data("qa-psk-mix-v1".utf8)
    /// UTF-8 "qa-psk-mix-key-v1" — 17 bytes, `K_mix` HKDF-Expand info domain.
    private static let domainKey = Data("qa-psk-mix-key-v1".utf8)

    private static func u8(_ n: Int) -> Data { Data([UInt8(n & 0xFF)]) }

    private static func u16be(_ n: Int) -> Data {
        Data([UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }

    /// `fp_i = SHA-256(s_i)`, raw 32 bytes.
    public static func fingerprint(_ secret: Data) -> Data {
        precondition(secret.count == secretBytes, "PskMix.fingerprint: secret must be \(secretBytes)B, got \(secret.count)")
        return Data(SHA256.hash(data: secret))
    }

    /// `mix_id = SHA-256(DOMAIN_MIX_ID || u8(N) || fp_1 || ... || fp_N)`.
    /// `orderedFps` must already be in wire-authoritative order (2 <= N <= 4).
    public static func mixId(_ orderedFps: [Data]) -> Data {
        let n = orderedFps.count
        precondition((2...maxN).contains(n), "PskMix.mixId: N must be 2..\(maxN), got \(n)")
        for (i, fp) in orderedFps.enumerated() {
            precondition(fp.count == fpBytes, "PskMix.mixId: fp_\(i + 1) must be \(fpBytes)B, got \(fp.count)")
        }
        var preimage = Data()
        preimage.append(domainMixId)
        preimage.append(u8(n))
        for fp in orderedFps { preimage.append(fp) }
        return Data(SHA256.hash(data: preimage))
    }

    /// `ikm_mix = DOMAIN_IKM || u8(N) || fp_1(32) || CONCAT_{i=2..N}(fp_i(32) || u16be(32) || s_i(32))`.
    /// `orderedSecrets`/`orderedFps` must already be in wire-authoritative order.
    public static func ikmMix(_ orderedFps: [Data], _ orderedSecrets: [Data]) -> Data {
        let n = orderedSecrets.count
        precondition((2...maxN).contains(n), "PskMix.ikmMix: N must be 2..\(maxN), got \(n)")
        precondition(orderedFps.count == n, "PskMix.ikmMix: fps length \(orderedFps.count) != secrets length \(n)")
        for (i, s) in orderedSecrets.enumerated() {
            precondition(s.count == secretBytes, "PskMix.ikmMix: s_\(i + 1) must be \(secretBytes)B, got \(s.count)")
        }
        for (i, fp) in orderedFps.enumerated() {
            precondition(fp.count == fpBytes, "PskMix.ikmMix: fp_\(i + 1) must be \(fpBytes)B, got \(fp.count)")
        }
        var out = Data()
        out.append(domainIkm)
        out.append(u8(n))
        out.append(orderedFps[0])
        for i in 1..<n {
            out.append(orderedFps[i])
            out.append(u16be(secretBytes))
            out.append(orderedSecrets[i])
        }
        return out
    }

    /// `PRK_mix = HMAC-SHA256(key = s_1, msg = ikm_mix)` — exposed for the KAT,
    /// not used directly by callers (folded into `deriveKMix` via HKDF-Expand).
    public static func prkMix(_ s1: Data, _ ikm: Data) -> Data {
        precondition(s1.count == secretBytes, "PskMix.prkMix: s_1 must be \(secretBytes)B, got \(s1.count)")
        let mac = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: s1))
        return Data(mac)
    }

    /// `K_mix` — N=1 is the identity (`K_mix := s_1`, byte-identical to today,
    /// no HMAC/Expand executed). N>=2 aggregates via HMAC-then-Expand.
    /// `orderedSecrets` must already be in wire-authoritative order (N capped at 4).
    public static func deriveKMix(_ orderedSecrets: [Data]) -> Data {
        let n = orderedSecrets.count
        precondition((1...maxN).contains(n), "PskMix.deriveKMix: N must be 1..\(maxN), got \(n)")
        for (i, s) in orderedSecrets.enumerated() {
            precondition(s.count == secretBytes, "PskMix.deriveKMix: s_\(i + 1) must be \(secretBytes)B, got \(s.count)")
        }

        if n == 1 {
            return orderedSecrets[0]
        }

        let orderedFps = orderedSecrets.map { fingerprint($0) }
        let ikm = ikmMix(orderedFps, orderedSecrets)
        let mid = mixId(orderedFps)
        var info = Data()
        info.append(domainKey)
        info.append(u8(n))
        info.append(mid)

        let prk = SymmetricKey(data: prkMix(orderedSecrets[0], ikm))
        let kMix = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: keyBytes)
        return kMix.withUnsafeBytes { Data($0) }
    }
}

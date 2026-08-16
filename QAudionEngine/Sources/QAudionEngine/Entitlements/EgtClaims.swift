import Foundation

/// Design doc §8 security-policy payload, carried inside the EGT so it
/// survives offline — a separate mechanism from tiering, riding the same
/// signed envelope. Matches `bcrypto-server`'s `EGTPolicy`
/// (`cmd/bcrypto-lite/entitlements_egt.go`) field-for-field; the server
/// always sets this (plain struct, no `omitempty`), so it is never absent
/// on a real token.
public struct EgtPolicy: Codable, Equatable {
    public let minAssurance: String
    public let onViolation: String

    enum CodingKeys: String, CodingKey {
        case minAssurance = "min_assurance"
        case onViolation = "on_violation"
    }

    public init(minAssurance: String, onViolation: String) {
        self.minAssurance = minAssurance
        self.onViolation = onViolation
    }
}

/// Decoded, SIGNATURE-VERIFIED payload of an Entitlement Grant Token (EGT),
/// design doc §3.1. Matches `bcrypto-server`'s `EGTClaims`
/// (`cmd/bcrypto-lite/entitlements_egt.go`) field-for-field — `sub`/`iat`/
/// `exp` come from an embedded `jwt.RegisteredClaims` there; Swift has no
/// equivalent embedded-claims type, so they are flattened into this
/// struct's own top-level fields (still with matching JSON keys, so
/// `Codable`'s synthesized coding keys need no `CodingKeys` override here).
///
/// This is everything `EgtVerifier.verify` hands back once the JWS
/// signature over `header.payload` has checked out under the pinned
/// entitlement public key. Deliberately NOT checked by `EgtVerifier`:
///  - `sub` matching the currently logged-in user — owned by
///    `CapabilityGate` (Task 3), not here.
///  - `ee`/`epr` anti-rollback (design doc §3.4) — **not yet implemented
///    anywhere on any platform**, matching Android's `EgtClaims` kdoc note
///    verbatim. Parsing these fields is not the same as enforcing them.
///  - Any expiry (`exp`, or a per-feature `fea` entry in the past) — see
///    `EgtVerifier.verify`'s doc comment for why.
public struct EgtClaims: Codable, Equatable {
    public let v: Int
    public let sub: String
    public let did: String
    public let dkt: String
    public let pkg: [String]
    /// feature key -> expiry unix seconds, `0` = perpetual (design doc §3.1).
    public let fea: [String: Int64]
    /// limit key -> numeric limit value.
    public let lim: [String: Int64]
    public let pol: EgtPolicy
    public let ee: UInt64
    /// Epoch-reset claim, design doc §3.4 — never set by anything yet
    /// (server field is `*uint64` with `omitempty`, so it is legitimately
    /// absent on every token minted today; `nil` here is the normal case,
    /// not a decode failure).
    public let epr: UInt64?
    public let iat: Int64
    /// Envelope expiry, unix seconds — a REFRESH TARGET, not a kill switch
    /// (design doc §3.2). Never used by `EgtVerifier` to reject a token.
    public let exp: Int64

    public init(
        v: Int, sub: String, did: String, dkt: String, pkg: [String],
        fea: [String: Int64], lim: [String: Int64], pol: EgtPolicy,
        ee: UInt64, epr: UInt64?, iat: Int64, exp: Int64
    ) {
        self.v = v; self.sub = sub; self.did = did; self.dkt = dkt; self.pkg = pkg
        self.fea = fea; self.lim = lim; self.pol = pol
        self.ee = ee; self.epr = epr; self.iat = iat; self.exp = exp
    }
}

import Foundation

/// Design doc §8 security-policy payload, carried inside the EGT so it
/// survives offline — a separate mechanism from tiering, riding the same
/// signed envelope. Matches `bcrypto-server`'s `EGTPolicy`
/// (`cmd/bcrypto-lite/entitlements_egt.go`) field-for-field; the server
/// always sets this (plain struct, no `omitempty`), so it is never absent
/// on a real token.
///
/// Both fields fall back rather than failing the decode, matching Android's
/// `parseClaims` (`min_assurance` -> `"none"`, `on_violation` -> `"warn"`).
/// See `EgtClaims`'s own note on why leniency is the correct posture here.
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` on a `decodeIfPresent` yields a double optional (`String??`):
        // the outer nil is "threw / wrong type", the inner is "absent or
        // null". Both collapse to the same fallback here.
        minAssurance = ((try? c.decodeIfPresent(String.self, forKey: .minAssurance)) ?? nil) ?? "none"
        onViolation = ((try? c.decodeIfPresent(String.self, forKey: .onViolation)) ?? nil) ?? "warn"
    }
}

/// Decoded, SIGNATURE-VERIFIED payload of an Entitlement Grant Token (EGT),
/// design doc §3.1. Matches `bcrypto-server`'s `EGTClaims`
/// (`cmd/bcrypto-lite/entitlements_egt.go`) field-for-field — `sub`/`iat`/
/// `exp` come from an embedded `jwt.RegisteredClaims` there; Swift has no
/// equivalent embedded-claims type, so they are flattened into this
/// struct's own top-level fields (still with matching JSON keys).
///
/// This is everything `EgtVerifier.verify` hands back once the JWS
/// signature over `header.payload` has checked out under the pinned
/// entitlement public key. Deliberately NOT checked by `EgtVerifier`:
///  - `sub` matching the currently logged-in user — owned by
///    `CapabilityGate` (Task 3), not here.
///  - `ee`/`epr` anti-rollback (design doc §3.4) — **not yet implemented
///    anywhere on any platform**. Android's `EgtClaims` kdoc makes the same
///    point for `ee` (it has no `epr` field at all, so iOS is the only
///    platform parsing that claim today). Parsing these fields is not the
///    same as enforcing them.
///  - Any expiry (`exp`, or a per-feature `fea` entry in the past) — see
///    `EgtVerifier.verify`'s doc comment for why.
///
/// ## Decoding is deliberately LENIENT, and that is a security posture
/// Only `v` and `sub` are required. Every other field falls back to an
/// empty/zero value if it is absent, `null`, or the wrong JSON type —
/// byte-for-byte the same rule set as Android's `parseClaims`
/// (`did`/`dkt` -> `""`, `pkg`/`fea`/`lim` -> empty, `pol` -> `nil`,
/// `ee`/`iat`/`exp` -> `0`).
///
/// The tempting alternative — Swift's synthesized `Codable`, where every
/// non-optional field is mandatory — is wrong here in a way that is easy to
/// miss, because it fails in the *unsafe* direction despite looking
/// stricter. A signed token with one unexpected field shape (a Go nil map
/// marshalling to `"fea":null`, a DR-restored record from an older schema,
/// an `omitempty` added upstream) would fail to decode wholesale, so
/// `EgtVerifier.verify` would return `nil`, and the user would silently
/// lose their ENTIRE entitlement state — on a token whose signature is
/// perfectly valid. That is the "a blip looks like a downgrade" failure
/// design doc §3.2 rules out, arriving through the decoder instead of
/// through the network, and it would hit iOS while Android degraded
/// gracefully on the identical token. Strictness that costs a paying user
/// their features is not strictness worth having; the signature is what
/// establishes trust, and it has already been checked before any of this
/// runs.
///
/// Known and accepted asymmetry: a single malformed ENTRY inside `fea`/
/// `lim`/`pkg` is dropped and the rest of the collection is kept, matching
/// Android's per-entry `mapNotNull`. A malformed collection (a `null`, or
/// an array where an object belongs) yields the empty default.
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
    /// `nil` when the token carries no `pol` object at all — matching
    /// Android's nullable `pol`. Absence is reported, never fabricated into
    /// a permissive-looking default, so a consumer can tell "no policy was
    /// stated" from "a policy of none/warn was stated".
    public let pol: EgtPolicy?
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

    enum CodingKeys: String, CodingKey {
        case v, sub, did, dkt, pkg, fea, lim, pol, ee, epr, iat, exp
    }

    public init(
        v: Int, sub: String, did: String, dkt: String, pkg: [String],
        fea: [String: Int64], lim: [String: Int64], pol: EgtPolicy?,
        ee: UInt64, epr: UInt64?, iat: Int64, exp: Int64
    ) {
        self.v = v; self.sub = sub; self.did = did; self.dkt = dkt; self.pkg = pkg
        self.fea = fea; self.lim = lim; self.pol = pol
        self.ee = ee; self.epr = epr; self.iat = iat; self.exp = exp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // The only two hard requirements, mirroring Android's
        // `intField("v") ?: return null` / `stringField("sub") ?: return null`.
        // `decode` (not `decodeIfPresent`) throws on absent AND on wrong
        // type, which is the behaviour wanted: a token with no subject, or a
        // numeric one, is not a token this app can reason about at all.
        v = try c.decode(Int.self, forKey: .v)
        sub = try c.decode(String.self, forKey: .sub)

        did = Self.string(c, .did) ?? ""
        dkt = Self.string(c, .dkt) ?? ""
        let rawPkg = ((try? c.decodeIfPresent([LenientString?].self, forKey: .pkg)) ?? nil) ?? []
        pkg = rawPkg.compactMap { $0.flatMap(\.value) }
        fea = Self.int64Map(c, .fea)
        lim = Self.int64Map(c, .lim)
        pol = (try? c.decodeIfPresent(EgtPolicy.self, forKey: .pol)) ?? nil
        ee = Self.number(c, .ee) ?? 0
        epr = Self.number(c, .epr)
        iat = Self.number(c, .iat) ?? 0
        exp = Self.number(c, .exp) ?? 0
    }

    // MARK: - Per-field leniency helpers
    //
    // Each swallows both "absent/null" and "present but wrong JSON type",
    // because Android's accessors do: its `stringField` requires
    // `isString`, its `longField` requires `!isString`, and a failed check
    // yields null (-> the field's default) rather than killing the parse.
    // Swift's `decodeIfPresent` returns nil for the first case but THROWS
    // for the second, so each call needs the `try?` to collapse them.

    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil)
    }

    private static func number<T: Decodable>(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> T? {
        ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil)
    }

    private static func int64Map(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> [String: Int64] {
        guard let raw = ((try? c.decodeIfPresent([String: LenientInt64?].self, forKey: key)) ?? nil) else {
            return [:]
        }
        return raw.compactMapValues { $0.flatMap(\.value) }
    }
}

// MARK: - Element wrappers for per-entry leniency
//
// Swift's collection decoding is all-or-nothing: one bad element throws and
// the WHOLE array/dictionary is lost. These wrappers move the failure down
// to the individual element (their `init(from:)` never throws — it records
// nil), so a malformed entry is dropped and its siblings survive, which is
// what Android's `mapNotNull`-based `stringListField`/`longMapField` do.
//
// They are always decoded as OPTIONAL elements (`[LenientString?]`,
// `[String: LenientInt64?]`), never bare. A JSON `null` element is the
// reason: whether `JSONDecoder` short-circuits a null before calling a
// custom `init(from:)`, or pushes it and lets that init throw internally,
// is an implementation detail not worth depending on. Declaring the element
// optional makes the null land on the decoder's own well-defined path in
// either case, so a `["base", null, "pro"]` drops only the null instead of
// possibly losing the whole array.

private struct LenientString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(String.self)
    }
}

private struct LenientInt64: Decodable {
    let value: Int64?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Int64.self)
    }
}

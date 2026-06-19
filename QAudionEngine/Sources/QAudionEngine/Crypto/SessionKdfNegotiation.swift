import Foundation

/// KMS-rotation-v2 Phase-1 (D6) — session-KDF version negotiation.
///
/// The session key is derived with either the schema:2 ct-binding KDF
/// (`QAudionCallIntegration.deriveHybridSessionKey`) or the schema:3 KDF
/// (`...deriveHybridSessionKeyV3`, which folds the negotiated fingerprint into
/// the HKDF `info`). The two are NOT interchangeable — a v2 peer and a v3 peer
/// derive DIFFERENT keys from the same inputs (the schema:3 `info` is 32 bytes
/// longer), so both legs MUST agree on the version before deriving.
///
/// **Rule (frozen):** v3 is selected ONLY when BOTH legs advertise v3 support.
/// If EITHER peer lacks v3 (legacy build, capability absent/false), both fall
/// back to v2 — the mixed-fleet floor. This mirrors the Android / Desktop
/// negotiation and the firmware handshake-version gate.
///
/// The version is carried by the handshake (a) version byte and (b) a
/// capability flag; this helper takes the already-decoded booleans so it stays
/// pure and host-testable (no wire decode here).
public enum SessionKdfNegotiation {

    public enum Version: Int, Equatable {
        case v2 = 2
        case v3 = 3
    }

    /// The schema:3-capable handshake version byte. A peer that presents a
    /// handshake version >= this AND the v3 capability flag is treated as
    /// v3-capable. (Today the only frozen handshake version is 1; the v3 KDF is
    /// gated on the capability flag, with the version byte reserved for a future
    /// hard cutover — kept here so the gate is in ONE place.)
    public static let v3HandshakeVersion: UInt8 = 1

    /// Decide the session-KDF version for this call.
    ///
    /// - Parameters:
    ///   - localSupportsV3: does THIS device implement the schema:3 KDF? (true
    ///     for any Phase-1+ build).
    ///   - peerSupportsV3: did the PEER advertise schema:3 support (capability
    ///     flag true AND handshake version >= `v3HandshakeVersion`)? Resolve this
    ///     from the inbound bundle BEFORE calling — see `peerAdvertisesV3`.
    /// - Returns: `.v3` iff both legs support it; otherwise `.v2`.
    public static func resolve(localSupportsV3: Bool, peerSupportsV3: Bool) -> Version {
        return (localSupportsV3 && peerSupportsV3) ? .v3 : .v2
    }

    /// Convenience: does an inbound peer advertise v3? v3 requires BOTH the
    /// capability flag set AND a handshake version at/above the v3 floor. A nil
    /// capability (legacy bundle that omits the field) is treated as false.
    public static func peerAdvertisesV3(capabilityV3: Bool?, peerHandshakeVersion: UInt8) -> Bool {
        return (capabilityV3 ?? false) && peerHandshakeVersion >= v3HandshakeVersion
    }
}

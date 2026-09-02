import Foundation
import CryptoKit

/// Verifies a server-signed `remote_wipe` command before ANY caller is
/// allowed to run `LocalCryptoWipe.wipeAll()` — TRUST-2
/// (`docs/security/CRYPTO_PROTOCOL_AUDIT_2026-09-01.md`).
///
/// ## The bug this closes
/// Before this, iOS wiped every key and all data on receipt of a BARE
/// `{"type":"remote_wipe"}` WS envelope with **zero** payload validation —
/// not even the "wipe_id must be non-empty" filter Android/Desktop already
/// had (see `AppState.swift`'s `remote_wipe` handler, W330: the server also
/// tries an FCM push but `hub.go:615` SKIPS it for ios-apns devices, so the
/// WS envelope is the ONLY delivery path on this platform — anyone able to
/// inject on that authenticated channel could already wipe a device with no
/// proof of anything beyond "I can send a WS frame"). TRUST-2's fix is a
/// cryptographic command, not a marker field: the server signs
/// `domain_tag || device_id || wipe_id || issued_at(8B BE) || nonce(16B)`
/// with a DEDICATED Ed25519 keypair (never the OTA/entitlement key — see
/// `WipeSigningPublicKey`'s kdoc for why), and the client verifies that
/// signature, a tight freshness window, and single-use (nonce replay)
/// before the wipe handler is even reachable.
///
/// ## Fail-closed contract — the load-bearing property
/// `verify(...)` returns `true` ONLY when every gate below passes. Any
/// doubt — missing field, malformed field, bad signature, stale
/// `issued_at`, or a replayed `(device_id, nonce)` — returns `false`, and
/// the caller MUST treat `false` as "do not wipe, do not act", never as
/// "wipe anyway to be safe". This mirrors `EgtVerifier`'s contract exactly
/// (nil/false on ANY failure, never a partial success) — see that type's
/// kdoc for the same discipline applied to entitlement tokens.
///
/// ## Wire field names are this file's one unverified assumption
/// bcrypto-server's TRUST-2 fix is being implemented by a separate agent in
/// the same batch; this client cannot see its exact field names. The names
/// below (`device_id`, `wipe_id`, `issued_at`, `nonce`, `signature`, all
/// snake_case matching this file's existing WS envelope convention — e.g.
/// `sender_device_id`, `server_ts_ms` elsewhere in `AppState.swift`) are a
/// reasonable, clearly-isolated guess: `parseWipeCommand(from:)` below is
/// the ONLY place that has to change if the server lands different key
/// names. `issued_at` is read as a Unix-seconds integer; `nonce` and
/// `signature` are base64 strings.
///
/// ## Where does the Ed25519 verify come from?
/// `CryptoKit.Curve25519.Signing.PublicKey.isValidSignature(_:for:)` — same
/// primitive `EgtVerifier` and `BCryptoOtaModelClient` already use, no new
/// dependency.
public final class WipeCommandVerifier: @unchecked Sendable {

    /// Domain-separation tag for the signed canonical bytes. MUST match
    /// whatever literal bytes bcrypto-server signs with — see the wire-field
    /// note above, same caveat applies to this constant.
    public static let domainTag = Data("qaudion-wipe-v1".utf8)

    /// TRUST-2 fix note: "issued_at is within a tight window (e.g. 5
    /// minutes)".
    public static let defaultFreshnessWindowSeconds: Int64 = 300

    /// Small forward tolerance for clock skew between this device and the
    /// server — a command stamped a few seconds in the future (server clock
    /// slightly ahead) is not evidence of forgery. Deliberately much smaller
    /// than the freshness window itself.
    public static let clockSkewToleranceSeconds: Int64 = 30

    /// A parsed (not yet verified) wipe command envelope.
    public struct WipeCommand: Equatable {
        public let deviceId: String
        public let wipeId: String
        public let issuedAtUnixSeconds: Int64
        public let nonce: Data
        public let signature: Data

        public init(deviceId: String, wipeId: String, issuedAtUnixSeconds: Int64, nonce: Data, signature: Data) {
            self.deviceId = deviceId
            self.wipeId = wipeId
            self.issuedAtUnixSeconds = issuedAtUnixSeconds
            self.nonce = nonce
            self.signature = signature
        }
    }

    /// The Ed25519 signature-verify primitive, bound to the pinned key.
    /// Injectable closure (not a direct `pinnedPublicKey.isValidSignature`
    /// call) purely so tests can spy on it — same pattern as `EgtVerifier`.
    private let verifySignature: @Sendable (_ signature: Data, _ signedBytes: Data) -> Bool

    /// - Parameter pinnedPublicKeyRaw: the 32-byte raw Ed25519 public key
    ///   (not SPKI-wrapped — `WipeSigningPublicKey.rawKey(fromSpkiPem:)` does
    ///   that extraction for the pinned build asset). `nil` on anything that
    ///   is not a valid Curve25519 signing key, matching the fail-closed
    ///   contract even at construction time.
    public init?(pinnedPublicKeyRaw: Data) {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pinnedPublicKeyRaw) else {
            return nil
        }
        self.verifySignature = { signature, signedBytes in
            key.isValidSignature(signature, for: signedBytes)
        }
    }

    /// Test-only seam (internal, reachable via `@testable import`).
    init(verifySignatureOverride: @escaping @Sendable (_ signature: Data, _ signedBytes: Data) -> Bool) {
        self.verifySignature = verifySignatureOverride
    }

    /// Builds the exact byte string the server signs:
    /// `domain_tag || device_id (UTF-8) || wipe_id (UTF-8) ||
    /// issued_at_unix_seconds (8 bytes, big-endian) || nonce (16 bytes)`.
    /// No separators, no length prefixes — literal concatenation, per the
    /// TRUST-2 fix note. Public + pure so it is independently testable and
    /// so a KAT vector (once the server's real one exists) can be dropped in
    /// without touching `verify`.
    public static func canonicalBytes(deviceId: String, wipeId: String, issuedAtUnixSeconds: Int64, nonce: Data) -> Data {
        var out = Data()
        out.reserveCapacity(domainTag.count + deviceId.utf8.count + wipeId.utf8.count + 8 + nonce.count)
        out.append(domainTag)
        out.append(contentsOf: deviceId.utf8)
        out.append(contentsOf: wipeId.utf8)
        var be = issuedAtUnixSeconds.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(nonce)
        return out
    }

    /// Full gate. Every check below is a hard `false` on failure — order
    /// matters only for cost (cheap format checks first, so a garbage/
    /// unsigned envelope never touches the persisted replay cache; see the
    /// note on `replayCache` below), never for correctness, since every
    /// single gate is independently sufficient to reject.
    ///
    /// - Parameters:
    ///   - command: the parsed envelope.
    ///   - expectedDeviceId: THIS device's own id (`TokenVault.loadDeviceId()`
    ///     on the call site). `command.deviceId` is signed data, but a
    ///     signature alone only proves the server signed *some* command for
    ///     *some* device — without this check, a command legitimately signed
    ///     for a DIFFERENT device could be replayed at this one. Binding to
    ///     the local device id is what makes `device_id` in the canonical
    ///     bytes do anything.
    ///   - replayCache: MUST be a persisted instance shared across calls
    ///     (see `WipeReplayCache`) — an in-memory-only cache would let an
    ///     attacker replay a captured command once per app relaunch inside
    ///     the freshness window, defeating the whole point of the nonce.
    /// - Returns: `true` only if the command is authentic, addressed to this
    ///   device, fresh, and not a replay. `false` in every other case —
    ///   the caller MUST NOT wipe on `false`.
    public func verify(
        command: WipeCommand,
        expectedDeviceId: String,
        replayCache: WipeReplayCache,
        now: Date = Date(),
        freshnessWindowSeconds: Int64 = WipeCommandVerifier.defaultFreshnessWindowSeconds
    ) -> Bool {
        guard !expectedDeviceId.isEmpty else { return false }
        guard !command.deviceId.isEmpty, command.deviceId == expectedDeviceId else { return false }
        guard !command.wipeId.isEmpty else { return false }
        guard command.nonce.count == 16 else { return false }
        // Ed25519 signatures are always exactly 64 bytes — reject anything
        // else before ever handing it to CryptoKit.
        guard command.signature.count == 64 else { return false }

        let canonical = Self.canonicalBytes(
            deviceId: command.deviceId,
            wipeId: command.wipeId,
            issuedAtUnixSeconds: command.issuedAtUnixSeconds,
            nonce: command.nonce
        )
        guard verifySignature(command.signature, canonical) else { return false }

        let nowSeconds = Int64(now.timeIntervalSince1970)
        let ageSeconds = nowSeconds - command.issuedAtUnixSeconds
        guard ageSeconds >= -Self.clockSkewToleranceSeconds, ageSeconds <= freshnessWindowSeconds else {
            return false
        }

        // Replay check LAST, and only after a genuine signature has already
        // verified: checking it earlier would let an attacker who cannot
        // forge a signature still burn/probe entries in the persisted
        // replay set with garbage (device_id, nonce) pairs.
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        guard replayCache.putIfAbsent(deviceId: command.deviceId, nonce: command.nonce, nowMs: nowMs) else {
            return false
        }

        return true
    }

    /// Parses a `WipeCommand` out of a WS envelope's `data` dictionary.
    /// Returns `nil` on ANY missing/malformed field — `verify` never even
    /// runs on an incomplete envelope, and a `nil` here MUST be treated
    /// exactly like a `verify() == false`: refuse to wipe.
    ///
    /// See this file's header for the wire-field-name caveat: this is the
    /// one place to update if bcrypto-server's real key names differ.
    public static func parseWipeCommand(from data: [String: Any]) -> WipeCommand? {
        guard let deviceId = (data["device_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceId.isEmpty else { return nil }
        guard let wipeId = (data["wipe_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !wipeId.isEmpty else { return nil }
        let issuedAt: Int64
        if let n = data["issued_at"] as? NSNumber {
            issuedAt = n.int64Value
        } else if let s = data["issued_at"] as? String, let parsed = Int64(s) {
            issuedAt = parsed
        } else {
            return nil
        }
        guard let nonceB64 = data["nonce"] as? String,
              let nonce = Data(base64Encoded: nonceB64), nonce.count == 16 else { return nil }
        guard let sigB64 = data["signature"] as? String,
              let signature = Data(base64Encoded: sigB64), signature.count == 64 else { return nil }
        return WipeCommand(deviceId: deviceId, wipeId: wipeId, issuedAtUnixSeconds: issuedAt, nonce: nonce, signature: signature)
    }
}

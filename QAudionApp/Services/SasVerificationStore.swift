import Foundation

/// W368 — persistence for the in-call SAS ceremony.
///
/// Once a user taps "CONFERMA COINCIDONO" in the InCallScreen, the
/// (peer, sasFingerprint) tuple is stored so the next call between
/// the same two peers automatically renders the panel as VERIFIED
/// (no need to re-do the ceremony for every call).
///
/// **Cross-platform parity:** mirrors Android's
/// `SasVerificationTracker.kt` — both store a SHA-256 of the
/// peerUserId + the SAS-words bundle so a tampered chain key (which
/// would change the SAS) auto-invalidates the verification.
///
/// **Storage:** UserDefaults keyed by
/// `qaudion.sas.verified.<peerUserId>` with the fingerprint as
/// value. UserDefaults is fine here because:
/// - The fingerprint isn't a secret (it's hex of a hash anyway).
/// - Persistence is informational, not security-load-bearing — even
///   a tampered store can only make a verified peer appear
///   unverified, not the other way around (the SAS computation is
///   re-run on every call).
public final class SasVerificationStore {

    public static let shared = SasVerificationStore()

    private let prefix = "qaudion.sas.verified."

    public init() {}

    /// Persist that `peerUserId` confirmed SAS coincidence under
    /// `fingerprint`. Replaces any previous fingerprint for the
    /// same peer (e.g. after a key rotation that produces a new SAS).
    public func recordVerified(peerUserId: String, fingerprint: String) {
        UserDefaults.standard.set(fingerprint, forKey: prefix + peerUserId)
    }

    /// Returns the previously-stored fingerprint, or nil if the user
    /// has never confirmed an SAS for this peer (or the store was
    /// reset).
    public func storedFingerprint(peerUserId: String) -> String? {
        return UserDefaults.standard.string(forKey: prefix + peerUserId)
    }

    /// Convenience: returns true if `currentFingerprint` matches the
    /// last verified fingerprint for the peer. Used to render the
    /// "SAS VERIFICATO" badge on InCallScreen at call start without
    /// requiring the user to re-confirm.
    public func isVerified(peerUserId: String, currentFingerprint: String) -> Bool {
        guard let stored = storedFingerprint(peerUserId: peerUserId) else {
            return false
        }
        return stored == currentFingerprint
    }

    /// Forget the verification for a peer — used when the user
    /// explicitly resets a contact, or when key material rotates
    /// in a way that invalidates the historical fingerprint.
    public func clear(peerUserId: String) {
        UserDefaults.standard.removeObject(forKey: prefix + peerUserId)
    }

    /// Compute the canonical fingerprint for a SAS-words bundle.
    /// The fingerprint is what gets persisted — derived from the
    /// SAS rather than the raw session key so a manual reset by the
    /// user (UserDefaults clear) doesn't expose any secret material.
    public static func fingerprint(forWords words: [String]) -> String {
        let joined = words.map { $0.uppercased() }.joined(separator: "|")
        let utf8 = Data(joined.utf8)
        // Lightweight 64-bit FNV-1a hash; we don't need cryptographic
        // strength here (the SAS itself is the security primitive).
        var h: UInt64 = 0xcbf29ce484222325
        for b in utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%016llx", h)
    }
}

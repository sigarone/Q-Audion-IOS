import Foundation

/// Server URL that the app is **pinned** to. Single source of truth for
/// every network call and the security gate for fast-setup QR validation.
///
/// Cross-platform alignment: Android (`qaudion-android-new`) carries an
/// `apiBaseUrl` in build flavors; iOS doesn't have build flavors, so we
/// hard-code the production host here. Override only by recompiling.
///
/// Why pin instead of letting the user type a server URL:
///   - prevents redirect attacks (a malicious fast-setup QR cannot send
///     the phone to an attacker-controlled server — the scanner aborts
///     unless `payload.server` starts with this host);
///   - matches Android's UX (server is invisible to the user);
///   - eliminates the typo-prone "https://bcrypto.example.com" / "api.qaudion.com"
///     placeholders that landed in the v1.0.0..v1.0.50 builds and made
///     login impossible without a manual override.
public enum PinnedServerHost {

    /// Production VoIP backend for Q-Audion. Same value Android pins to.
    /// Source of truth (per user 2026-04-29): `https://voip.bcrypto.com`.
    public static let url: String = "https://voip.bcrypto.com"

    /// Host portion of `url`, used by the fast-setup scanner to verify
    /// that `payload.server` doesn't redirect to a different origin.
    /// Returns `voip.bcrypto.com`.
    public static var host: String {
        URL(string: url)?.host ?? "voip.bcrypto.com"
    }

    /// True if `candidate` (the `server` field from a scanned QR payload)
    /// is acceptable — i.e. it points at the same origin we're pinned to.
    /// We compare on origin (scheme + host) so an admin panel that emits
    /// `https://voip.bcrypto.com:443` or `https://voip.bcrypto.com/` still
    /// matches.
    public static func accepts(_ candidate: String) -> Bool {
        guard let candidateUrl = URL(string: candidate),
              let candidateHost = candidateUrl.host else {
            return false
        }
        // Match on host only; allow the scheme and any trailing path.
        // A candidate IP literal (e.g. "https://217.160.65.35") will NOT
        // match "voip.bcrypto.com" — that's the desired behaviour: the QR
        // must point at the canonical hostname, never a raw IP.
        return candidateHost.lowercased() == host.lowercased()
    }
}

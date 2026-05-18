import Foundation

/// Server URL that the app is **pinned** to. Single source of truth for
/// every network call and the security gate for fast-setup QR validation.
///
/// W413 — robust pinning that does NOT break when the server emits a QR
/// containing a raw IP literal (e.g. `https://217.160.65.35`) instead of
/// the canonical hostname. Until W413 the gate compared `candidateHost`
/// strictly to the literal `voip.bcrypto.com` string — any IP-form QR
/// failed the check, blocking onboarding for users whose server-side
/// admin panel emitted IP-form invites (production-staging, demo, dev).
///
/// **Acceptance ladder** (first match wins):
///   1. Hostname match — `candidate.host` lowercases to `host` (fast path).
///   2. Static allowlist — `candidate.host` is one of `knownAddresses`
///      (canonical hostname + admin-curated IP fallbacks). Useful when
///      DNS is unavailable (offline scan, CGNAT DNS poisoning).
///
/// SECURITY H-4 + L-1 — the former step 3 (DNS-resolved match via
/// `getaddrinfo`) was REMOVED. Resolving an attacker-controlled
/// `server` field turned the QR scanner into an SSRF + DNS-rebinding
/// oracle (H-4), and the unbounded process-lifetime resolve cache was
/// a slow memory leak (L-1). Acceptance is now purely a static,
/// offline string comparison against the canonical host + the
/// admin-curated `knownAddresses` allowlist. To onboard a new backend
/// IP, add it to `knownAddresses` (a reviewed code change), never via
/// runtime DNS.
///
/// Both checks are local, synchronous, and perform no network I/O.
///
/// **Why pin instead of letting the user type a server URL:**
///   - prevents redirect attacks (a malicious fast-setup QR cannot send
///     the phone to an attacker-controlled server unless the attacker
///     also controls a valid A record for the canonical hostname);
///   - matches Android's UX (server is invisible to the user);
///   - eliminates the typo-prone `https://bcrypto.example.com` /
///     `api.qaudion.com` placeholders that landed in v1.0.0..v1.0.50.
///
/// **What the W413 ladder does NOT change:**
///   - The actual network calls still go to `PinnedServerHost.url` — the
///     QR's server field is only used to verify the user scanned the
///     intended issuer; production traffic always hits the canonical
///     hostname so HSTS and certificate pinning continue to work.
public enum PinnedServerHost {

    /// Production VoIP backend for Q-Audion. Same value Android pins to.
    /// Source of truth (per user 2026-04-29): `https://voip.bcrypto.com`.
    public static let url: String = "https://voip.bcrypto.com"

    // MARK: - Certificate pinning (IMPORTANT-2a)
    //
    // We pin two certs from the chain, NOT the leaf cert (which Let's Encrypt
    // rotates every ~90 days and would break the app on automatic renewal):
    //
    //   [0] Let's Encrypt E8 intermediate  — expires 2027-03-13
    //       SHA-256(DER): g2JP0zjI2bAjwYpny3qcBRnaQ9EXdbTGy9rUXD2ZfFI=
    //
    //   [1] ISRG Root X1 (Let's Encrypt root) — expires 2035-06-04
    //       SHA-256(DER): lrzsBiZJdvN0YHeazyjFp8/oo8Cq4RqP/O4FwL3fCMY=
    //
    // CertPinningDelegate in BCryptoRestClient checks all certs in the server's
    // TLS chain. A connection succeeds iff at least one cert's DER SHA-256 is
    // in this list. This design:
    //   - survives leaf cert rotation (E8 or Root X1 will still match)
    //   - blocks a MITM with a cert from a different CA (no match in chain)
    //   - requires no app update when Let's Encrypt issues a new leaf cert
    //
    // **Rotation:** if Let's Encrypt switches from E8 to a new intermediate,
    // update `certChainPins[0]` before the old intermediate expires (2027-03-13).
    // The ISRG Root X1 is a multi-decade anchor — only changes if ISRG revokes it.
    //
    // Computed on 2026-05-17 from the live chain at voip.bcrypto.com:443.
    public static let certChainPins: String = [
        "g2JP0zjI2bAjwYpny3qcBRnaQ9EXdbTGy9rUXD2ZfFI=",  // Let's Encrypt E8 (2027-03-13)
        "lrzsBiZJdvN0YHeazyjFp8/oo8Cq4RqP/O4FwL3fCMY=",  // ISRG Root X1 (2035-06-04)
    ].joined(separator: ",")

    /// Host portion of `url`. Returns `voip.bcrypto.com`.
    public static var host: String {
        URL(string: url)?.host ?? "voip.bcrypto.com"
    }

    /// Static allowlist consulted before DNS lookup. Contains the
    /// canonical hostname plus admin-curated IP fallbacks. Add new
    /// IPs here when the backend rotates and you want offline scans
    /// to keep working without a fresh DNS resolve.
    ///
    /// Sorted for human readability; comparison is case-insensitive.
    public static let knownAddresses: [String] = [
        "voip.bcrypto.com",
        // Production backend IPv4 (osservato nei QR fast-setup
        // emessi dal server admin panel quando il DNS punta lì).
        // Allargare quando si fa rotation IP o si aggiunge un
        // bilanciatore.
        "217.160.65.35",
    ]

    /// True if `candidate` (the `server` field from a scanned QR payload)
    /// is acceptable. SECURITY H-4 + L-1 — static, offline string match
    /// only; NO DNS resolution (the DNS step was an SSRF / DNS-rebinding
    /// vector and its cache leaked memory).
    public static func accepts(_ candidate: String) -> Bool {
        guard let candidateUrl = URL(string: candidate),
              let rawHost = candidateUrl.host else {
            return false
        }
        let candidateHost = rawHost.lowercased()
        let canonicalHost = host.lowercased()

        // 1) Hostname match (fast path).
        if candidateHost == canonicalHost {
            return true
        }
        // 2) Static allowlist (admin-curated IP fallbacks). This is the
        //    ONLY way a non-canonical host is accepted — extend
        //    `knownAddresses` via a reviewed code change, never via a
        //    runtime DNS lookup of the untrusted QR `server` field.
        if knownAddresses.map({ $0.lowercased() }).contains(candidateHost) {
            return true
        }
        return false
    }

    /// SECURITY H-4 + L-1 — retained as an inert no-op so any external
    /// or test reference to this symbol still links. The DNS resolve
    /// cache it used to flush no longer exists.
    public static func clearResolveCache() {
        // No-op: DNS resolution removed (SSRF / DNS-rebinding + leak).
    }
}

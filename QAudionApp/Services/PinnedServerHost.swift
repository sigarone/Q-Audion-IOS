import Foundation

/// Server URL that the app is **pinned** to. Single source of truth for
/// every network call and the security gate for fast-setup QR validation.
///
/// **Acceptance ladder** (first match wins):
///   1. Hostname match — `candidate.host` lowercases to `host` (fast path).
///   2. Static allowlist — `candidate.host` is one of `knownAddresses`
///      (canonical hostname). Extend via reviewed code change if the
///      backend hostname ever changes.
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
        // NEW LE hierarchy (added 2026-07-10): the origin (reached directly via
        // the REALITY tunnel / DNS-only failover, bypassing the Cloudflare edge
        // the clearnet path validates against) migrated to leaf ← YE1 ← ISRG
        // Root YE ← ISRG Root X2. The E8/Root-X1 pins above are NOT in that
        // chain, so REALITY + direct failover failed. These are SHA-256(cert
        // DER), computed live 2026-07-10 from voip.bcrypto.com:443 origin.
        // Purely additive; matches Desktop + Android (which pin the SPKI form).
        "7l96vWmBuwJVYyzY9JKDRRtLGIRNEgQLRO4A8HuP4sY=",  // ISRG Root X2 (durable anchor)
        "ojctBkMelxY2Xu7UfsAgNRSX0YL8wDjkV+WBaKA8rAc=",  // Let's Encrypt YE1 (intermediate)
        // W-CERTPIN-YE2 (2026-07-23) — SECOND LE hierarchy rotation since the
        // YE1 pins above were added. THE ROOT CAUSE of "133 makes zero
        // requests, ever, even with a confirmed-perfect network connection":
        // live chain fetched today from voip.bcrypto.com:443 is
        // leaf(bcrypto.com) <- YE2 <- "ISRG Root YE" (cross-signed by ISRG
        // Root X2, but a DISTINCT cert with its own DER hash — X2's own pin
        // above does NOT match it). None of the 4 existing pins matched any
        // cert in that chain, so CertPinningDelegate rejected the TLS
        // handshake before a single HTTP byte was sent — the server-side
        // access log showed literally nothing, indistinguishable from "the
        // app never tried," because from the server's perspective it never
        // did. Any client with an already-live WS from before this rotation
        // was unaffected (no fresh handshake, no re-validation); only a
        // client forced into a FRESH connection (e.g. after a node failover)
        // hit this. Purely additive, same pattern as the 2026-07-10 rotation.
        "l2WN6MaN+pis4eUCimPVShqukRs+IUcQdsaFDNCMurQ=",  // Let's Encrypt YE2 (intermediate)
        "D8CQHMorrp6f27AtUNAvEJT3s2ZyCGmRueiXYm3EhfA=",  // ISRG Root YE (cross-signed by X2)
    ].joined(separator: ",")

    /// Host portion of `url`. Returns `voip.bcrypto.com`.
    public static var host: String {
        URL(string: url)?.host ?? "voip.bcrypto.com"
    }

    /// Static allowlist consulted before DNS lookup. Contains the
    /// canonical hostname. Add entries here when the backend moves to
    /// a new hostname (reviewed code change, no runtime DNS lookup).
    ///
    /// Sorted for human readability; comparison is case-insensitive.
    public static let knownAddresses: [String] = [
        "voip.bcrypto.com",
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

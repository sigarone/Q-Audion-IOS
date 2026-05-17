import Foundation
import Darwin

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
/// **W413 acceptance ladder** (first match wins):
///   1. Hostname match — `candidate.host` lowercases to `host` (fast path).
///   2. Static allowlist — `candidate.host` is one of `knownAddresses`
///      (canonical hostname + admin-curated IP fallbacks). Useful when
///      DNS is unavailable (offline scan, CGNAT DNS poisoning).
///   3. DNS-resolved match — resolve both the canonical hostname and
///      the candidate to their A/AAAA records and accept if the IP sets
///      intersect. This handles the IP-literal QR case without a static
///      allowlist update.
///
/// All three checks are local and synchronous. The DNS resolver is
/// `getaddrinfo(3)` from Darwin; cache lives for the process lifetime
/// to keep repeated scans fast.
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
    /// is acceptable. Runs the W413 acceptance ladder above.
    public static func accepts(_ candidate: String) -> Bool {
        guard let candidateUrl = URL(string: candidate),
              let rawHost = candidateUrl.host else {
            return false
        }
        let candidateHost = rawHost.lowercased()
        let canonicalHost = host.lowercased()

        // 1) Hostname match (fast path, no DNS).
        if candidateHost == canonicalHost {
            return true
        }
        // 2) Static allowlist (admin-curated IP fallbacks).
        if knownAddresses.map({ $0.lowercased() }).contains(candidateHost) {
            return true
        }
        // 3) DNS-resolved match. Resolve canonical → IP set; if
        //    candidateHost itself is an IP, check membership directly.
        //    Else resolve candidateHost too and intersect.
        let canonicalIPs = resolveAddresses(canonicalHost)
        if canonicalIPs.contains(candidateHost) {
            return true
        }
        let candidateIPs = resolveAddresses(candidateHost)
        if !canonicalIPs.intersection(candidateIPs).isEmpty {
            return true
        }
        return false
    }

    // MARK: - DNS resolution (cached)

    private static var resolveCache: [String: Set<String>] = [:]
    private static let resolveCacheLock = NSLock()

    /// `getaddrinfo` wrapper returning the union of A + AAAA literal
    /// strings for `host`. Cached for the process lifetime so the
    /// FastSetup scan path stays fast across repeated attempts.
    /// Returns empty set on resolve failure (offline / NXDOMAIN).
    private static func resolveAddresses(_ host: String) -> Set<String> {
        resolveCacheLock.lock()
        if let cached = resolveCache[host] {
            resolveCacheLock.unlock()
            return cached
        }
        resolveCacheLock.unlock()

        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var infoOpt: UnsafeMutablePointer<addrinfo>? = nil
        let rc = host.withCString { cHost in
            getaddrinfo(cHost, nil, &hints, &infoOpt)
        }
        guard rc == 0, let firstInfo = infoOpt else {
            resolveCacheLock.lock()
            resolveCache[host] = []
            resolveCacheLock.unlock()
            return []
        }
        defer { freeaddrinfo(infoOpt) }

        var ips: Set<String> = []
        var current: UnsafeMutablePointer<addrinfo>? = firstInfo
        while let cur = current {
            let info = cur.pointee
            var nameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let niRc = getnameinfo(
                info.ai_addr, info.ai_addrlen,
                &nameBuffer, socklen_t(nameBuffer.count),
                nil, 0,
                NI_NUMERICHOST)
            if niRc == 0 {
                let ip = String(cString: nameBuffer).lowercased()
                if !ip.isEmpty { ips.insert(ip) }
            }
            current = info.ai_next
        }

        resolveCacheLock.lock()
        resolveCache[host] = ips
        resolveCacheLock.unlock()
        return ips
    }

    /// Test/diagnostics helper — drops the resolve cache so the next
    /// `accepts(...)` re-queries DNS. Not used in production paths.
    public static func clearResolveCache() {
        resolveCacheLock.lock()
        resolveCache.removeAll()
        resolveCacheLock.unlock()
    }
}

import Foundation
import QAudionEngine
import os

/// Probes RTT to each bcrypto server node and selects the fastest.
///
/// ## Algorithm
/// 1. GET /api/v1/servers (authenticated — requires a live access token)
/// 2. HEAD /api/v1/health on each node (5 s timeout, no auth needed)
/// 3. Pick lowest RTT; update `BCryptoBackendProvider` if it beats the
///    current node by at least `improvementFactor` AND the current RTT
///    exceeds `switchThresholdMs` (avoids flapping on similar nodes).
///
/// ## Usage
///   After login: `await serverSelector.selectBestServer(provider: provider)`
///   Background:  `serverSelector.startMonitor(provider: provider)`
@MainActor
final class ServerSelector {

    static let shared = ServerSelector()
    private init() {}

    // MARK: - Constants
    private let probeTimeoutSec: TimeInterval = 5.0
    private let monitorIntervalSec: TimeInterval = 5 * 60   // 5 min
    private let switchThresholdMs: Double = 300
    private let improvementFactor: Double = 1.5

    /// How strongly a node's reported load penalises its RTT in selection.
    /// effectiveRtt = rtt * (1 + loadWeight * loadPct/100): at 100 % load a node's
    /// effective RTT doubles, at 50 % it is ×1.5. Spreads NEW connections off an
    /// overloaded-but-close node instead of piling on by latency alone. 0 = pure
    /// RTT; 1.0 is the validated default. Mirrors Android/Desktop ServerSelector.
    static let loadWeight: Double = 1.0

    /// Load-aware ranking score (pure; testable). Static so unit tests need no instance.
    static func effectiveRtt(_ rttMs: Double, loadPct: Double) -> Double {
        let load = min(100, max(0, loadPct))
        return rttMs * (1 + loadWeight * load / 100)
    }

    /// Hosts the client trusts as VoIP nodes. Every selection + failover path only
    /// ever targets these — never an attacker-injected host.
    ///
    /// W-NODRFAILOVER (2026-07-23) — fi1.bcrypto.com is a dev/build box + DR
    /// snapshot replica, NOT a live mirror of production: it has no real-time
    /// user-data sync and no cross-node call routing. Root-caused on device
    /// e1f5690b (call 9c490c46 and others, 2026-07-23): a refresh-token 401
    /// blip at 08:46 UTC tripped `onNodeStalled` (3 consecutive failed WS
    /// reconnects), the client failed over here per the old allowlist below,
    /// and got stuck — the DR box happily authenticated the client's stale
    /// session (its own snapshot still had the old refresh token) but had no
    /// row for the user at all ("identity key mirror failed: user not
    /// found"), so every call in or out silently died for the rest of the
    /// day while the client believed it was fully connected (200s, WS auth).
    /// A client that CANNOT reach production is better served by retrying
    /// production (or falling through to the Reality censorship-bypass path,
    /// which already exists for exactly this "every trusted clearnet node
    /// unreachable" case — see `handleNodeStalled` in AppState.swift) than by
    /// silently wandering onto a node that answers but cannot actually serve
    /// it. Until fi-1 gets real cross-node user-data replication + call
    /// routing, it must not be an automatic client failover target — pull it
    /// from the allowlist entirely. (Android FAILOVER_HOSTS / Desktop
    /// PINNED_HOSTNAMES carry the identical latent bug and need the same fix.)
    private let trustedHosts: Set<String> = ["voip.bcrypto.com"]

    /// Hardcoded TRUSTED-HOSTNAME fallback node list. Used ONLY when the live
    /// /api/v1/servers list can't be fetched (the node serving it died). WS path
    /// is /ws (the real route; /api/v1/ws 404s).
    ///
    /// W-NODRFAILOVER — fi-1 removed, see `trustedHosts` above. This now only
    /// ever offers the single production node back to itself, which is
    /// intentional: `reselectExcluding` filtering it out (it IS the dead node
    /// being excluded) correctly yields zero candidates, so the caller falls
    /// through to the Reality bypass path instead of a broken DR box.
    private let fallbackNodes: [[String: Any]] = [
        ["id": "eu-de-1", "https_url": "https://voip.bcrypto.com", "wss_url": "wss://voip.bcrypto.com/ws"],
    ]

    // MARK: - State
    private var monitorTask: Task<Void, Never>?
    private weak var currentProvider: BCryptoBackendProvider?

    // MARK: - Public API

    /// Fetch server list, probe RTT, update provider if a better node found.
    /// Safe to call on every login — does nothing if probing fails.
    func selectBestServer(provider: BCryptoBackendProvider) async {
        currentProvider = provider
        let baseUrl = provider.config.serverUrl
        guard let nodes = await fetchServers(provider: provider) else { return }
        guard !nodes.isEmpty else { return }
        let ranked = await probeAll(nodes: nodes)
        guard let best = ranked.first else { return }
        applyIfBetter(provider: provider, candidate: best.url, candidateRtt: best.rtt,
                      currentUrl: baseUrl)
    }

    /// Fail OFF a dead node: re-select the best REACHABLE trusted node whose
    /// wss_url is not `deadWssUrl`, and switch the provider to it. Tries the live
    /// server list first; if that can't be fetched (the dead node was serving it)
    /// falls back to `fallbackNodes`. Returns the new wss_url, or nil if nothing
    /// reachable — caller must NOT switch (implicit network-gate: if nothing
    /// probes, the local network is likely the problem, not the node).
    /// SECURITY: candidates are restricted to trusted `wss://` hosts only.
    func reselectExcluding(deadWssUrl: String, provider: BCryptoBackendProvider) async -> String? {
        currentProvider = provider
        let live = await fetchServers(provider: provider)
        let source: [[String: Any]]
        if let live = live, !live.isEmpty {
            source = live
        } else {
            source = fallbackNodes
        }
        let candidates = trustedFailoverCandidates(source, deadWssUrl: deadWssUrl)
        guard !candidates.isEmpty else {
            os_log("ServerSelector: no trusted alternative node to fail over to")
            return nil
        }
        let ranked = await probeAll(nodes: candidates)
        guard let best = ranked.first else {
            os_log("ServerSelector: failover candidates unreachable — local net likely down, not switching")
            return nil
        }
        os_log("ServerSelector: failover to %{public}@ (rtt=%.0fms)", best.url, best.rtt)
        provider.updateServerUrl(to: best.url)
        return best.wssUrl
    }

    /// Start periodic re-probing in background. Idempotent.
    func startMonitor(provider: BCryptoBackendProvider) {
        guard monitorTask == nil else { return }
        currentProvider = provider
        // Task inherits @MainActor isolation from the enclosing context,
        // so all accesses to self (and provider.config) are safe.
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.monitorIntervalSec * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let p = self.currentProvider else { break }
                let baseUrl = p.config.serverUrl
                // W-PRIMARYSNAP — a client parked on a failover node (via
                // reselectExcluding, e.g. after 3 stalled reconnects) must not
                // stay there just because its RTT looks fine. fi1.bcrypto.com
                // is a dev/DR box, not a peer of voip.bcrypto.com — it can
                // authenticate an old session (stale snapshot) while missing
                // the live user row entirely, so the client "works" (200s,
                // WS auth) but every call it originates or is offered dies:
                // the real production node sees it as offline the whole time.
                // Root-caused 2026-07-23 (call 9c490c46 and others): device
                // failed over off voip.bcrypto.com during a refresh-token
                // blip at 08:46 UTC and never came back — the RTT-gated
                // applyIfBetter below only switches when a candidate beats
                // the current node by 1.5x AND the current RTT exceeds
                // 300ms, which a merely-slow-but-alive failover node can
                // dodge indefinitely. So: if we are NOT on the pinned
                // primary, probe it directly and snap back unconditionally
                // the moment it answers at all — no RTT contest. The primary
                // is home; every other trusted host is a last resort.
                if URL(string: baseUrl)?.host?.lowercased() != URL(string: PinnedServerHost.url)?.host?.lowercased() {
                    if let primaryRtt = await self.measureRtt(url: PinnedServerHost.url + "/api/v1/health") {
                        os_log("ServerSelector: W-PRIMARYSNAP — off primary (%{public}@), primary reachable (rtt=%.0fms) — snapping back",
                               baseUrl, primaryRtt)
                        p.updateServerUrl(to: PinnedServerHost.url)
                        continue
                    }
                }
                guard let nodes = await self.fetchServers(provider: p) else { continue }
                let ranked = await self.probeAll(nodes: nodes)
                guard let best = ranked.first else { continue }
                let currentRtt = await self.measureRtt(url: baseUrl + "/api/v1/health") ?? Double.infinity
                self.applyIfBetter(provider: p, candidate: best.url, candidateRtt: best.rtt,
                                   currentUrl: baseUrl, currentRtt: currentRtt)
            }
        }
    }

    func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Private helpers

    private struct NodeProbe {
        let url: String
        let wssUrl: String
        let rtt: Double
        let load: Double
    }

    /// SECURITY C-6 — uses the provider's cert-pinned BCryptoRestClient session.
    private func fetchServers(provider: BCryptoBackendProvider) async -> [[String: Any]]? {
        guard let token = provider.config.accessToken, !token.isEmpty else { return nil }
        let cleaned = provider.config.serverUrl.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(cleaned)/api/v1/servers") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await provider.getRestClient().urlSession.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["servers"] as? [[String: Any]] else { return nil }
            return servers
        } catch {
            os_log("ServerSelector: fetchServers error: %{public}@", error.localizedDescription)
            return nil
        }
    }

    /// True if `wssUrl` is a `wss://` URL on a trusted (pinned) node. Both checks
    /// are security-critical: a poisoned /api/v1/servers list could otherwise
    /// advertise an untrusted host (steering) or a `ws://` cleartext URL (TLS
    /// downgrade) that a hostname-only check would accept. (review-driven parity
    /// with Android/Desktop)
    private func isTrustedFailoverHost(_ wssUrl: String) -> Bool {
        guard let u = URL(string: wssUrl), u.scheme == "wss", let host = u.host else { return false }
        return trustedHosts.contains(host.lowercased())
    }

    /// SECURITY-CRITICAL failover filter: keep ONLY nodes that are not the dead one
    /// and on a trusted `wss://` host. Dropping untrusted/cleartext hosts means a
    /// failover can never be steered to a weaker endpoint.
    private func trustedFailoverCandidates(_ nodes: [[String: Any]], deadWssUrl: String) -> [[String: Any]] {
        return nodes.filter { node in
            guard let wss = node["wss_url"] as? String else { return false }
            return wss != deadWssUrl && isTrustedFailoverHost(wss)
        }
    }

    private func probeAll(nodes: [[String: Any]]) async -> [NodeProbe] {
        var results: [NodeProbe] = []
        for node in nodes {
            // SECURITY (review-driven): probe/select ONLY trusted `wss://` hosts, so
            // a poisoned /api/v1/servers list can never steer normal selection
            // (selectBestServer / monitor) onto an untrusted or cleartext endpoint.
            guard let httpsUrl = node["https_url"] as? String, !httpsUrl.isEmpty,
                  let wssUrl = node["wss_url"] as? String, !wssUrl.isEmpty,
                  isTrustedFailoverHost(wssUrl) else { continue }
            let healthUrl = httpsUrl.trimmingCharacters(in: .init(charactersIn: "/")) + "/api/v1/health"
            if let rtt = await measureRtt(url: healthUrl) {
                let load = (node["load_pct"] as? NSNumber)?.doubleValue ?? 0
                results.append(NodeProbe(url: httpsUrl, wssUrl: wssUrl, rtt: rtt, load: load))
            }
        }
        // Rank by load-aware effectiveRtt (not raw RTT) so new selections shed off
        // an overloaded-but-close node. The ±1% jitter is computed ONCE per element
        // (never inside the comparator) and spreads the decision boundary so clients
        // don't all flip at the same load threshold (30s-stale load + un-synced
        // client cycles already damp most of the herd).
        return results
            .map { probe -> (NodeProbe, Double) in
                let jitter = 1 + Double.random(in: -0.01...0.01)
                return (probe, ServerSelector.effectiveRtt(probe.rtt, loadPct: probe.load) * jitter)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }

    private func measureRtt(url urlStr: String) async -> Double? {
        guard let url = URL(string: urlStr) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeoutSec
        config.timeoutIntervalForResource = probeTimeoutSec
        let session = URLSession(configuration: config)
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        do {
            let start = Date()
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200...499).contains(http.statusCode) else { return nil }
            // 401 is fine — server is alive, we don't need auth for RTT
            return Date().timeIntervalSince(start) * 1000  // ms
        } catch {
            return nil
        }
    }

    private func applyIfBetter(provider: BCryptoBackendProvider,
                                candidate: String,
                                candidateRtt: Double,
                                currentUrl: String,
                                currentRtt: Double? = nil) {
        let effectiveCurrentRtt = currentRtt ?? Double.infinity
        // Only switch if current is slow AND candidate is meaningfully better
        if effectiveCurrentRtt > switchThresholdMs &&
            candidateRtt * improvementFactor < effectiveCurrentRtt {
            os_log("ServerSelector: switching to %{public}@ (rtt=%.0fms < current=%.0fms)",
                   candidate, candidateRtt, effectiveCurrentRtt)
            provider.updateServerUrl(to: candidate)
        } else if currentRtt == nil {
            // First-time selection: always apply best server (no current RTT baseline)
            os_log("ServerSelector: initial selection %{public}@ (rtt=%.0fms)", candidate, candidateRtt)
            provider.updateServerUrl(to: candidate)
        }
    }
}

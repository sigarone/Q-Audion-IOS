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

    // MARK: - State
    private var monitorTask: Task<Void, Never>?
    private weak var currentProvider: BCryptoBackendProvider?

    // MARK: - Public API

    /// Fetch server list, probe RTT, update provider if a better node found.
    /// Safe to call on every login — does nothing if probing fails.
    func selectBestServer(provider: BCryptoBackendProvider) async {
        currentProvider = provider
        let baseUrl = provider.config.serverUrl
        guard let nodes = await fetchServers(baseUrl: baseUrl,
                                             accessToken: provider.config.accessToken) else { return }
        guard !nodes.isEmpty else { return }
        let ranked = await probeAll(nodes: nodes)
        guard let best = ranked.first else { return }
        applyIfBetter(provider: provider, candidate: best.url, candidateRtt: best.rtt,
                      currentUrl: baseUrl)
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
                let token = p.config.accessToken
                guard let nodes = await self.fetchServers(baseUrl: baseUrl, accessToken: token) else { continue }
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
    }

    private func fetchServers(baseUrl: String, accessToken: String?) async -> [[String: Any]]? {
        guard let token = accessToken, !token.isEmpty else { return nil }
        let cleaned = baseUrl.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(cleaned)/api/v1/servers") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["servers"] as? [[String: Any]] else { return nil }
            return servers
        } catch {
            os_log("ServerSelector: fetchServers error: %{public}@", error.localizedDescription)
            return nil
        }
    }

    private func probeAll(nodes: [[String: Any]]) async -> [NodeProbe] {
        var results: [NodeProbe] = []
        for node in nodes {
            guard let httpsUrl = node["https_url"] as? String, !httpsUrl.isEmpty,
                  let wssUrl = node["wss_url"] as? String, !wssUrl.isEmpty else { continue }
            let healthUrl = httpsUrl.trimmingCharacters(in: .init(charactersIn: "/")) + "/api/v1/health"
            if let rtt = await measureRtt(url: healthUrl) {
                results.append(NodeProbe(url: httpsUrl, wssUrl: wssUrl, rtt: rtt))
            }
        }
        return results.sorted { $0.rtt < $1.rtt }
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

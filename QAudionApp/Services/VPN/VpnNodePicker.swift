// VpnNodePicker.swift — Q-Audion iOS
//
// Port of Android NodePicker.kt so every client agrees on the same winner:
//
//   score = 0.4 · latencyScore + 0.4 · (1 − load) + 0.2 · jurisdictionScore
//   latencyScore = 1 / (1 + latencyMs/300)
//
// TCP-pings each node's WireGuard endpoint host:port (UDP latency isn't measurable
// without raw sockets) with a 100ms cap, then returns the best — so the client
// prefers it-mi-2 over de-1 when nearer / less loaded, instead of taking
// `nodes.first`. The endpoint arrives in the server's legacy `quic_addr` JSON
// field (see VpnNode.quicAddr); there is no QUIC involved, it is the WireGuard
// UDP endpoint.

import Foundation
import Network

enum VpnNodePicker {

    /// Data-retention-law risk (higher = better privacy), matching Android.
    private static let jurisdiction: [String: Double] = [
        "DE": 1.0, "NL": 1.0, "FI": 1.0, "IS": 1.0, "CH": 1.0,
        "FR": 0.8, "IT": 0.8, "ES": 0.8, "AT": 0.8,
        "SE": 0.7, "NO": 0.7, "DK": 0.7,
        "GB": 0.4,
    ]

    /// Score in (0, 1]; higher is better. `latencyMs` 999 = unknown.
    static func score(_ node: VpnNode, latencyMs: Int) -> Double {
        let latencyNorm = Double(max(1, latencyMs)) / 300.0
        let latencyScore = 1.0 / (1.0 + latencyNorm)
        let loadScore = 1.0 - min(1.0, max(0.0, node.loadPct))
        let js = jurisdiction[node.country] ?? 0.5
        return 0.4 * latencyScore + 0.4 * loadScore + 0.2 * js
    }

    /// Best node: 5 nearest by Haversine (device coords, 0,0 if unknown) → TCP-ping
    /// each → highest score. Returns nil only for an empty list.
    static func selectBest(_ nodes: [VpnNode], myLat: Double = 0, myLon: Double = 0) async -> VpnNode? {
        guard !nodes.isEmpty else { return nil }
        let top5 = Array(
            nodes.sorted { distanceKm(myLat, myLon, $0.lat, $0.lon) < distanceKm(myLat, myLon, $1.lat, $1.lon) }
                .prefix(5)
        )
        var latencies: [String: Int] = [:]
        await withTaskGroup(of: (String, Int).self) { group in
            for n in top5 { group.addTask { (n.id, await measureLatencyMs(n)) } }
            for await (id, ms) in group { latencies[id] = ms }
        }
        return selectBestSync(top5, latencies: latencies)
    }

    /// Deterministic selection given a pre-measured latency map (unit-testable).
    static func selectBestSync(_ nodes: [VpnNode], latencies: [String: Int]) -> VpnNode? {
        nodes.max {
            score($0, latencyMs: latencies[$0.id] ?? 999) < score($1, latencyMs: latencies[$1.id] ?? 999)
        }
    }

    /// TCP-connect to the node's WireGuard endpoint host:port as a latency
    /// proxy; 100ms cap → 999.
    private static func measureLatencyMs(_ node: VpnNode) async -> Int {
        let parts = node.quicAddr.split(separator: ":", maxSplits: 1)
        let host = String(parts.first ?? "")
        let portValue = UInt16(parts.count > 1 ? String(parts[1]) : "") ?? 443
        guard !host.isEmpty, let port = NWEndpoint.Port(rawValue: portValue) else { return 999 }

        let start = Date()
        return await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let timer = DispatchSource.makeTimerSource()

            // FinishOnce: @unchecked Sendable because NSLock manually guards `done`.
            final class FinishOnce: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                func tryFire() -> Bool {
                    lock.lock(); defer { lock.unlock() }
                    if done { return false }
                    done = true; return true
                }
            }
            let once = FinishOnce()
            let finish: @Sendable (Int) -> Void = { ms in
                guard once.tryFire() else { return }
                timer.cancel()
                conn.cancel()
                cont.resume(returning: ms)
            }

            timer.schedule(deadline: .now() + .milliseconds(100))
            timer.setEventHandler { finish(999) }
            timer.resume()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(Int(Date().timeIntervalSince(start) * 1000))
                case .failed, .cancelled:
                    finish(999)
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    /// Haversine great-circle distance in km.
    private static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        let dLat = rad(lat2 - lat1)
        let dLon = rad(lon2 - lon1)
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(lat1)) * cos(rad(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

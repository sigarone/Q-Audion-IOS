import Foundation

/// W-RELAYGEO (2026-08-26, best-practices audit item 5) — client-side
/// latency-aware relay ordering.
///
/// Before this, `QAudionWebRtcCallController.fetchIceServers()` handed
/// libwebrtc the server's `/api/v1/calling/relays` response in whatever
/// order the server returned it — no client-side latency- or
/// geography-aware placement, and `RelayServer` (the client's relay DTO)
/// carried no region/geo field to place by even if the client wanted to.
/// This file adds the client-measurable half of that gap:
///   - `RelayOrdering` — pure, unit-testable reordering by measured RTT.
///   - `RelayLatencyProbe` — a real (STUN Binding Request over UDP,
///     `StunClient.measureRttMs`) but bounded/best-effort concurrent probe
///     of every relay in a bundle.
///
/// SERVER-SIDE DEPENDENCY (flagged, not implemented here — out of this
/// client repo's scope): the relay-server data model has no region/geo
/// field server-side yet. `RelayServer.region` (added alongside this file)
/// is the client's forward-compatible READ side for that hint, but it
/// stays `nil` on every deployment until the server starts populating it.
/// `RelayOrdering` does not need it to be useful — it orders on measured
/// RTT alone today, and would prefer a `region` hint (once populated) only
/// as a same-cost tiebreaker in a future iteration, not a prerequisite.
public enum RelayOrderingConstants {
    /// Per-relay probe timeout. Bounded low so one dead/unreachable relay
    /// never meaningfully delays call setup — it just sorts to the back of
    /// the list, indistinguishable from "never probed".
    public static let probeTimeoutSec: TimeInterval = 0.8

    /// Overall wall-clock budget for probing the WHOLE relay bundle
    /// (every relay probed concurrently, so this is normally only a
    /// safety margin above `probeTimeoutSec`, not `probeTimeoutSec ×
    /// relay count`). If this elapses before the concurrent probe round
    /// finishes, ordering is skipped entirely for this call setup — the
    /// server's original order is used, exactly like today's behavior.
    /// Call setup must never wait meaningfully long for a latency
    /// optimization.
    public static let overallBudgetSec: TimeInterval = 1.2
}

/// Pure reordering step — no networking, fully unit-testable.
public enum RelayOrdering {

    /// Reorders `servers` by ascending measured RTT, using each server's
    /// FIRST url string as its identity (matches `RelayLatencyProbe`'s
    /// measurement key — `RelayServer` itself is not `Hashable`, and a
    /// relay's first URL is effectively its identity for this purpose: two
    /// distinct entries sharing one is a server-side duplicate this client
    /// has no way to disambiguate anyway).
    ///
    /// A server with no entry in `rttMsByFirstUrl` (never probed — no
    /// probeable `turn:`/`stun:` URL, timed out, or unreachable) is
    /// "unknown", not "worst" — every unknown entry is placed AFTER every
    /// measured entry but otherwise keeps its ORIGINAL relative order,
    /// letting ICE's own candidate-pair selection have the real final say
    /// among relays this pass had no signal about (mirrors the audit
    /// item's suggested "...before falling back to ICE's own
    /// candidate-pair selection").
    ///
    /// Ties among measured entries also keep their original relative
    /// order (stable sort) — this function never invents a preference
    /// between two relays it measured as equally fast.
    public static func order(_ servers: [RelayServer], rttMsByFirstUrl: [String: Double]) -> [RelayServer] {
        guard servers.count > 1, !rttMsByFirstUrl.isEmpty else { return servers }

        var measured: [(originalIndex: Int, server: RelayServer, rttMs: Double)] = []
        var unmeasured: [RelayServer] = []
        for (index, server) in servers.enumerated() {
            if let url = server.urls.first, let rtt = rttMsByFirstUrl[url] {
                measured.append((index, server, rtt))
            } else {
                unmeasured.append(server)
            }
        }
        guard !measured.isEmpty else { return servers }

        measured.sort { lhs, rhs in
            if lhs.rttMs != rhs.rttMs { return lhs.rttMs < rhs.rttMs }
            return lhs.originalIndex < rhs.originalIndex
        }
        return measured.map { $0.server } + unmeasured
    }
}

/// Concurrently probes every relay in a bundle and returns RTT samples
/// keyed by the same "first URL string" identity `RelayOrdering.order`
/// reads. Stateless wrapper around `StunClient` — safe to construct fresh
/// per call setup.
public struct RelayLatencyProbe: Sendable {
    private let stun: StunClient

    public init(stun: StunClient = StunClient()) {
        self.stun = stun
    }

    /// Probe every server in `servers` concurrently, bounded by
    /// `RelayOrderingConstants.overallBudgetSec` overall. Returns an empty
    /// dictionary (never throws) on total timeout, on an empty/unprobeable
    /// input, or if every probe failed — callers treat an empty result the
    /// same as "skip ordering, use server order" via
    /// `RelayOrdering.order`'s own empty-map short-circuit.
    public func measureAll(_ servers: [RelayServer]) async -> [String: Double] {
        let targets: [(url: String, host: String, port: UInt16)] = servers.compactMap { server in
            guard let url = server.urls.first,
                  let hostPort = Self.parseHostPort(fromRelayUrl: url) else { return nil }
            return (url, hostPort.host, hostPort.port)
        }
        guard !targets.isEmpty else { return [:] }
        // Captured explicitly (rather than implicitly via `self`) so the
        // `@Sendable` task closures below capture only this Sendable class
        // reference, not the whole struct.
        let stunClient = stun

        // Race the real probe round against the overall budget, same
        // "race + cancelAll in defer" idiom as
        // `EarbudPairingRelay.withThrowingTimeout` — non-throwing here
        // since a budget overrun is a normal, expected outcome (a slow/
        // congested network), not an error condition.
        return await withTaskGroup(of: [String: Double].self) { outer in
            outer.addTask {
                await Self.probeAll(targets, stun: stunClient)
            }
            outer.addTask {
                try? await Task.sleep(nanoseconds: UInt64(RelayOrderingConstants.overallBudgetSec * 1_000_000_000))
                return [:]
            }
            defer { outer.cancelAll() }
            return await outer.next() ?? [:]
        }
    }

    private static func probeAll(
        _ targets: [(url: String, host: String, port: UInt16)],
        stun: StunClient
    ) async -> [String: Double] {
        await withTaskGroup(of: (String, Double)?.self) { inner in
            for target in targets {
                inner.addTask {
                    guard let rtt = await stun.measureRttMs(
                        host: target.host,
                        port: target.port,
                        timeoutSec: RelayOrderingConstants.probeTimeoutSec
                    ) else { return nil }
                    return (target.url, rtt)
                }
            }
            var results: [String: Double] = [:]
            for await item in inner {
                if let (url, rtt) = item { results[url] = rtt }
            }
            return results
        }
    }

    /// Parse `turn:host:port(?params)` / `stun:host:port` / bare
    /// `turn:host` (default port 3478, RFC 5766 §4) into a probeable
    /// (host, port) pair. `turns:` (TLS/DTLS-only TURN) is deliberately
    /// excluded — a plain UDP STUN Binding probe against a TLS-only port
    /// would just time out, wasting probe budget on a relay this method
    /// cannot actually reach this way.
    static func parseHostPort(fromRelayUrl url: String) -> (host: String, port: UInt16)? {
        let scheme: String
        if url.hasPrefix("turn:") {
            scheme = "turn:"
        } else if url.hasPrefix("stun:") {
            scheme = "stun:"
        } else {
            return nil
        }
        var rest = String(url.dropFirst(scheme.count))
        if let queryIndex = rest.firstIndex(of: "?") {
            rest = String(rest[rest.startIndex..<queryIndex])
        }
        guard !rest.isEmpty else { return nil }
        // W-STUNDUALSTACK (2026-08-30) — splitting on the FIRST colon
        // mangles an IPv6 literal: `[2a02:…]:3478` became host "[2a02" and
        // a bare literal lost everything past its first group. Take the
        // port from the LAST colon, and only when it follows the closing
        // bracket of a bracketed literal; a bare unbracketed IPv6 literal
        // (several colons, no bracket) is all address, default port. Same
        // rule Android's NodePicker.splitHostPort applies. Inert for every
        // URL the server emits today (hostnames and v4 literals) — this is
        // the trap that would have sprung the moment an IPv6-literal relay
        // URL appeared in a bundle.
        if rest.hasPrefix("[") {
            guard let closing = rest.firstIndex(of: "]") else { return nil }
            let host = String(rest[rest.index(after: rest.startIndex)..<closing])
            guard !host.isEmpty else { return nil }
            let after = rest.index(after: closing)
            if after < rest.endIndex, rest[after] == ":",
               let parsedPort = UInt16(rest[rest.index(after: after)...]) {
                return (host, parsedPort)
            }
            return (host, 3478)
        }
        let colonCount = rest.filter { $0 == ":" }.count
        if colonCount > 1 {
            // Bare IPv6 literal — every colon belongs to the address.
            return (rest, 3478)
        }
        let parts = rest.split(separator: ":", maxSplits: 1)
        guard let hostPart = parts.first, !hostPart.isEmpty else { return nil }
        let host = String(hostPart)
        if parts.count > 1, let parsedPort = UInt16(parts[1]) {
            return (host, parsedPort)
        }
        return (host, 3478)
    }
}

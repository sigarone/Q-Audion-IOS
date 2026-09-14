import Foundation

/// W-RELAYFLEET (2026-08-31) — decides whether a `relays_updated` push from the
/// server is any of THIS call's business.
///
/// The server sends that push to every user in a call whenever ANY node
/// advertising an embedded TURN relay leaves its fresh set. Most of those calls
/// were never relaying through the node that left, and an ICE restart on a
/// healthy session costs a re-gather for nothing. Worse, a node that flaps
/// turns one notification into a fleet-wide restart storm — the accelerator
/// becomes the outage.
///
/// So the push is only acted on when this session's SELECTED candidate pair is
/// relaying through an address the fresh bundle no longer advertises.
/// Everything else discards it and keeps the refreshed bundle for the next
/// call.
///
/// Worth knowing what this is racing: a nominated pair whose relay has died is
/// already declared failed by ICE consent checks within roughly thirty seconds,
/// with no server involvement at all. This does not add recovery that was
/// missing — it collapses that thirty-second window to nearly zero. Which is
/// exactly why the gate has to be conservative: a wrong restart is strictly
/// worse than the baseline it is trying to beat.
///
/// Mirrors Android `RelayFleetReselection` and Desktop
/// `relayFleetReselection.ts` decision-for-decision; keep the three in step.
public enum RelayFleetReselection {

    /// Every host advertised by a relay bundle, from ICE urls shaped
    /// `turn:host:port?transport=udp`, `turns:host:port` or `stun:host`. IPv6
    /// literals arrive bracketed and come back unbracketed, matching the bare
    /// form WebRTC stats report.
    public static func relayHosts(from urls: [String]) -> Set<String> {
        var hosts = Set<String>()
        for url in urls {
            if let host = self.host(of: url) { hosts.insert(host) }
        }
        return hosts
    }

    /// - Parameters:
    ///   - selectedRelayAddress: address of the relay the selected candidate
    ///     pair currently traverses, or nil/empty when the pair is direct or
    ///     the stats could not be read. Both mean "nothing to act on".
    ///   - freshRelayHosts: hosts from the bundle fetched right after the push.
    public static func shouldRestartIce(
        selectedRelayAddress: String?,
        freshRelayHosts: Set<String>
    ) -> Bool {
        let address = (selectedRelayAddress ?? "").trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return false }
        // A bundle that advertises only DNS names has nothing comparable to the
        // numeric address ICE reports: "absent" would mean "not resolved here",
        // not "gone". Refuse to decide rather than restart on a guess.
        if !freshRelayHosts.contains(where: isIpLiteral) { return false }
        return !freshRelayHosts.contains(address)
    }

    private static func host(of url: String) -> String? {
        guard let schemeEnd = url.firstIndex(of: ":") else { return nil }
        let afterScheme = String(url[url.index(after: schemeEnd)...])
        let hostAndPort = afterScheme.split(separator: "?", maxSplits: 1,
                                            omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if hostAndPort.hasPrefix("[") {
            guard let close = hostAndPort.firstIndex(of: "]") else { return nil }
            let inner = String(hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<close])
            return inner.isEmpty ? nil : inner
        }
        let host = hostAndPort.split(separator: ":", maxSplits: 1,
                                     omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }

    private static func isIpLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        return !host.isEmpty && host.allSatisfy { $0.isNumber || $0 == "." }
    }
}

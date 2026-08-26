import Foundation

/// Splits an IPv4 CIDR block into the minimal set of smaller CIDR blocks
/// that cover everything in the original block EXCEPT one excluded /32
/// host. This is the standard "punch a hole in a route" technique WireGuard
/// configs use for split exclusion: WireGuard/NetworkExtension only support
/// INCLUDING address ranges (`allowedIPs`/`includedRoutes`), there is no
/// native "exclude this host" primitive at that layer, so excluding one
/// address from an otherwise-full-tunnel `0.0.0.0/0` means replacing it with
/// every other block that does NOT contain that address.
///
/// Used by the iOS VPN call-media gate (mirrors Android's `07c517b9a`
/// `WireGuardTunnel.setAppExcluded` fix, which has no direct iOS equivalent —
/// `NEPacketTunnelProvider` has no per-app exclusion API for a non-MDM app,
/// and the vendored WireGuardKit fork's `PacketTunnelSettingsGenerator`
/// derives `NEPacketTunnelNetworkSettings.includedRoutes` purely from
/// `peer.allowedIPs`, with no `excludedRoutes` concept at all — confirmed by
/// reading the real source at the pinned revision, not assumed). The call
/// site punches the live call's selected ICE candidate-pair remote host out
/// of the tunnel's `allowedIPs` for the duration of the call, so that one
/// destination's traffic — and only that destination's — goes out the real
/// interface instead of the WireGuard tunnel.
///
/// Pure integer/string function, zero WireGuardKit/NetworkExtension
/// dependency, so it is unit-testable directly. `QAudionPacketTunnel`
/// (the actual call site) cannot depend on this package today — the
/// extension target has no `QAudionEngine` product dependency wired in the
/// Xcode project, and editing `.pbxproj` target membership by hand without
/// being able to open the project in Xcode to verify it still resolves is a
/// real risk, not a hypothetical one — so `QAudionPacketTunnel/CidrExclusion.swift`
/// carries a byte-identical copy of the core algorithm below. THIS file is
/// the canonical, tested copy; keep the two in sync by hand if either
/// changes (there is no automated cross-target check for that today —
/// disclosed here rather than silently assumed to stay in sync).
public enum CidrExclusion {

    /// Returns the minimal list of "a.b.c.d/n" CIDR strings covering
    /// `coveringCidr` minus `excludedHost`. If `excludedHost` is not a valid
    /// IPv4 address, or `coveringCidr` is not a valid IPv4 CIDR block, or the
    /// excluded host falls outside the covering block, returns
    /// `[coveringCidr]` unchanged (nothing to punch) rather than throwing —
    /// callers apply this as a best-effort narrowing, and a no-op result is
    /// always a SAFE fallback (traffic to the un-excludable host simply stays
    /// tunneled, exactly like before this feature existed), never a wider
    /// hole than intended.
    public static func excludingHost(from coveringCidr: String, excludedHost: String) -> [String] {
        guard
            let (network, prefixLength) = parseIPv4Cidr(coveringCidr),
            let hostValue = parseIPv4Address(excludedHost)
        else {
            return [coveringCidr]
        }
        guard isAddress(hostValue, within: network, prefixLength: prefixLength) else {
            return [coveringCidr]
        }
        return punch(network: network, prefixLength: prefixLength, excludedHost: hostValue)
            .map { block, len in "\(formatIPv4(block))/\(len)" }
    }

    // MARK: - Core algorithm

    /// Recursive block-halving punch: at each level, split the current block
    /// in half; the half NOT containing `excludedHost` is emitted whole,
    /// the half that DOES contain it is recursed into — until a /32 is
    /// reached, which is dropped (it IS the excluded host). Standard
    /// technique, produces at most (32 - prefixLength) blocks.
    static func punch(network: UInt32, prefixLength: Int, excludedHost: UInt32) -> [(UInt32, Int)] {
        guard prefixLength < 32 else {
            return network == excludedHost ? [] : [(network, 32)]
        }
        let childPrefixLength = prefixLength + 1
        let halfSize: UInt32 = 1 << (32 - childPrefixLength)
        let lowerNetwork = network
        let upperNetwork = network | halfSize

        if excludedHost < upperNetwork {
            // Host is in the lower half — keep the upper half whole, recurse lower.
            return [(upperNetwork, childPrefixLength)]
                + punch(network: lowerNetwork, prefixLength: childPrefixLength, excludedHost: excludedHost)
        } else {
            // Host is in the upper half — keep the lower half whole, recurse upper.
            return [(lowerNetwork, childPrefixLength)]
                + punch(network: upperNetwork, prefixLength: childPrefixLength, excludedHost: excludedHost)
        }
    }

    // MARK: - IPv4 string <-> UInt32

    static func parseIPv4Address(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    static func parseIPv4Cidr(_ text: String) -> (network: UInt32, prefixLength: Int)? {
        let halves = text.split(separator: "/")
        guard halves.count == 2,
              let address = parseIPv4Address(String(halves[0])),
              let prefixLength = Int(halves[1]),
              (0...32).contains(prefixLength)
        else { return nil }
        let mask: UInt32 = prefixLength == 0 ? 0 : (~UInt32(0)) << (32 - prefixLength)
        return (address & mask, prefixLength)
    }

    static func isAddress(_ address: UInt32, within network: UInt32, prefixLength: Int) -> Bool {
        let mask: UInt32 = prefixLength == 0 ? 0 : (~UInt32(0)) << (32 - prefixLength)
        return (address & mask) == network
    }

    static func formatIPv4(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}

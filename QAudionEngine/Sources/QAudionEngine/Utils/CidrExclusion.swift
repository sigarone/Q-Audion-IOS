import Foundation
import Network

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

    // MARK: - W-VPNV6PUNCH (2026-08-30) — IPv6 hole punching

    /// IPv6 twin of ``excludingHost(from:excludedHost:)``: splits an IPv6
    /// CIDR block into the minimal set of blocks covering everything except
    /// one /128 host. Same safe-fallback contract — any parse failure, or a
    /// host outside the covering block, returns `[coveringCidr]` unchanged
    /// (the host stays tunneled; never a wider hole than intended).
    ///
    /// Exists because the call-media punch was IPv4-only while
    /// turn.bcrypto.com now publishes an AAAA: an ICE pair that selects the
    /// IPv6 address under the WireGuard VPN silently kept the call media
    /// inside the tunnel — the exact latency the punch feature was built to
    /// remove. Parsing and formatting go through Network.framework's
    /// `IPv6Address` (canonical compressed text both ways); only the block
    /// arithmetic is done by hand, on the 16 raw bytes.
    public static func excludingIPv6Host(from coveringCidr: String, excludedHost: String) -> [String] {
        guard
            let (network, prefixLength) = parseIPv6Cidr(coveringCidr),
            let hostAddr = IPv6Address(excludedHost)
        else { return [coveringCidr] }
        let host = [UInt8](hostAddr.rawValue)
        guard ipv6HasPrefix(host, network: network, prefixLength: prefixLength) else {
            return [coveringCidr]
        }
        return punch6(network: network, prefixLength: prefixLength, excludedHost: host)
            .compactMap { block, len in
                guard let text = IPv6Address(Data(block))?.debugDescription else { return nil }
                return "\(text)/\(len)"
            }
    }

    /// Core split, IPv6 flavour: walk from `prefixLength` toward /128; at
    /// each level keep the half that does NOT contain the excluded host and
    /// descend into the half that does. Yields exactly `128 - prefixLength`
    /// blocks (128 for a `::/0` covering block) — well inside what
    /// WireGuard's allowedIPs and NEPacketTunnel's includedRoutes handle.
    static func punch6(network: [UInt8], prefixLength: Int, excludedHost: [UInt8]) -> [([UInt8], Int)] {
        var blocks: [([UInt8], Int)] = []
        var net = network
        var bit = prefixLength
        while bit < 128 {
            let byteIndex = bit / 8
            let mask: UInt8 = 0x80 >> UInt8(bit % 8)
            if (excludedHost[byteIndex] & mask) != 0 {
                // Host descends into the 1-half; the 0-half (current net,
                // deciding bit clear) is the kept sibling.
                blocks.append((net, bit + 1))
                net[byteIndex] |= mask
            } else {
                var sibling = net
                sibling[byteIndex] |= mask
                blocks.append((sibling, bit + 1))
            }
            bit += 1
        }
        return blocks
    }

    static func parseIPv6Cidr(_ text: String) -> (network: [UInt8], prefixLength: Int)? {
        let halves = text.split(separator: "/", maxSplits: 1)
        guard halves.count == 2,
              let addr = IPv6Address(String(halves[0])),
              let prefixLength = Int(halves[1]),
              (0...128).contains(prefixLength)
        else { return nil }
        var bytes = [UInt8](addr.rawValue)
        guard bytes.count == 16 else { return nil }
        // Canonicalize: zero every bit past the prefix, so a sloppy input
        // like "2a02::1/64" behaves as its network address.
        for bit in prefixLength..<128 {
            bytes[bit / 8] &= ~(0x80 >> UInt8(bit % 8))
        }
        return (bytes, prefixLength)
    }

    static func ipv6HasPrefix(_ host: [UInt8], network: [UInt8], prefixLength: Int) -> Bool {
        guard host.count == 16, network.count == 16 else { return false }
        for bit in 0..<prefixLength {
            let byteIndex = bit / 8
            let mask: UInt8 = 0x80 >> UInt8(bit % 8)
            if (host[byteIndex] & mask) != (network[byteIndex] & mask) { return false }
        }
        return true
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

import Foundation

/// CANONICAL, TESTED COPY: `QAudionEngine/Sources/QAudionEngine/Utils/CidrExclusion.swift`
/// (see that file's kdoc for the full rationale and `CidrExclusionTests.swift`
/// for coverage). Duplicated here byte-for-byte because the `QAudionPacketTunnel`
/// extension target has no `QAudionEngine` product dependency wired in the
/// Xcode project today, and this session had no way to add one (no local
/// Xcode/Swift toolchain to add + verify a `.pbxproj` target-membership edit
/// without risking a corrupted project file) — disclosed limitation, not a
/// silent gap. If either copy changes, update both by hand.
enum CidrExclusion {

    static func excludingHost(from coveringCidr: String, excludedHost: String) -> [String] {
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

    static func punch(network: UInt32, prefixLength: Int, excludedHost: UInt32) -> [(UInt32, Int)] {
        guard prefixLength < 32 else {
            return network == excludedHost ? [] : [(network, 32)]
        }
        let childPrefixLength = prefixLength + 1
        let halfSize: UInt32 = 1 << (32 - childPrefixLength)
        let lowerNetwork = network
        let upperNetwork = network | halfSize

        if excludedHost < upperNetwork {
            return [(upperNetwork, childPrefixLength)]
                + punch(network: lowerNetwork, prefixLength: childPrefixLength, excludedHost: excludedHost)
        } else {
            return [(lowerNetwork, childPrefixLength)]
                + punch(network: upperNetwork, prefixLength: childPrefixLength, excludedHost: excludedHost)
        }
    }

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

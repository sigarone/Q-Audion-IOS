import XCTest
@testable import QAudionEngine

/// Tests for [CidrExclusion], the VPN call-media-gate route-punching algorithm
/// (mirrors Android's `07c517b9a` VPN call-state gate — see that file's kdoc
/// for why iOS needs this instead of a per-app exclusion API).
final class CidrExclusionTests: XCTestCase {

    // MARK: - Brute-force correctness on small blocks

    /// Enumerates every address in a small covering block, computes the
    /// expected set (block minus the excluded host), and asserts the
    /// punched CIDR list's address union is EXACTLY that set — not a
    /// superset (would leak the excluded host back into the tunnel) and not
    /// a subset (would tunnel-exclude addresses that were never asked for).
    private func assertExactCoverage(coveringCidr: String, excludedHost: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let (network, prefixLength) = CidrExclusion.parseIPv4Cidr(coveringCidr) else {
            XCTFail("bad test fixture CIDR", file: file, line: line)
            return
        }
        let blockSize: UInt32 = prefixLength == 32 ? 1 : (1 << (32 - prefixLength))
        let expectedAddresses = Set((0..<blockSize).map { network + $0 })
            .subtracting([CidrExclusion.parseIPv4Address(excludedHost)!])

        let punched = CidrExclusion.excludingHost(from: coveringCidr, excludedHost: excludedHost)
        var actualAddresses = Set<UInt32>()
        for cidr in punched {
            guard let (net, len) = CidrExclusion.parseIPv4Cidr(cidr) else {
                XCTFail("punch produced unparseable CIDR \(cidr)", file: file, line: line)
                return
            }
            let size: UInt32 = len == 32 ? 1 : (1 << (32 - len))
            for offset in 0..<size {
                let addr = net + offset
                XCTAssertFalse(actualAddresses.contains(addr), "overlapping punched blocks at \(CidrExclusion.formatIPv4(addr))", file: file, line: line)
                actualAddresses.insert(addr)
            }
        }
        XCTAssertEqual(actualAddresses, expectedAddresses, file: file, line: line)
    }

    func test_excludes_middle_host_from_a_slash29() {
        assertExactCoverage(coveringCidr: "10.0.0.0/29", excludedHost: "10.0.0.5")
    }

    func test_excludes_first_host_in_block() {
        assertExactCoverage(coveringCidr: "192.168.1.0/28", excludedHost: "192.168.1.0")
    }

    func test_excludes_last_host_in_block() {
        assertExactCoverage(coveringCidr: "192.168.1.0/28", excludedHost: "192.168.1.15")
    }

    func test_excludes_from_slash30_smallest_useful_block() {
        assertExactCoverage(coveringCidr: "203.0.113.0/30", excludedHost: "203.0.113.2")
    }

    // MARK: - Full-tunnel punch (the real call-site shape)

    func test_full_tunnel_punch_produces_32_blocks_and_excludes_exactly_the_host() {
        let punched = CidrExclusion.excludingHost(from: "0.0.0.0/0", excludedHost: "77.42.121.13")
        XCTAssertEqual(punched.count, 32, "a /0 punch should yield exactly 32 blocks (one per bit level)")

        for cidr in punched {
            guard let (network, prefixLength) = CidrExclusion.parseIPv4Cidr(cidr) else {
                XCTFail("unparseable CIDR \(cidr)")
                continue
            }
            let hostValue = CidrExclusion.parseIPv4Address("77.42.121.13")!
            XCTAssertFalse(
                CidrExclusion.isAddress(hostValue, within: network, prefixLength: prefixLength),
                "\(cidr) still contains the host it was supposed to exclude"
            )
        }

        // Spot-check a real, unrelated address stays fully routable — e.g.
        // the signaling server itself must still resolve to SOME punched
        // block (only the excluded host loses coverage).
        let unrelated = CidrExclusion.parseIPv4Address("1.2.3.4")!
        let stillCovered = punched.contains { cidr in
            guard let (network, prefixLength) = CidrExclusion.parseIPv4Cidr(cidr) else { return false }
            return CidrExclusion.isAddress(unrelated, within: network, prefixLength: prefixLength)
        }
        XCTAssertTrue(stillCovered, "an unrelated address must still be covered by the punched route set")
    }

    // MARK: - Safe no-op fallbacks

    func test_host_outside_covering_block_is_a_noop() {
        let result = CidrExclusion.excludingHost(from: "10.0.0.0/24", excludedHost: "192.168.1.1")
        XCTAssertEqual(result, ["10.0.0.0/24"])
    }

    func test_invalid_host_string_is_a_noop() {
        let result = CidrExclusion.excludingHost(from: "0.0.0.0/0", excludedHost: "not-an-ip")
        XCTAssertEqual(result, ["0.0.0.0/0"])
    }

    func test_invalid_cidr_string_is_a_noop() {
        let result = CidrExclusion.excludingHost(from: "garbage", excludedHost: "1.2.3.4")
        XCTAssertEqual(result, ["garbage"])
    }

    func test_excluding_the_entire_slash32_block_itself_yields_nothing() {
        let result = CidrExclusion.excludingHost(from: "1.2.3.4/32", excludedHost: "1.2.3.4")
        XCTAssertEqual(result, [])
    }
}

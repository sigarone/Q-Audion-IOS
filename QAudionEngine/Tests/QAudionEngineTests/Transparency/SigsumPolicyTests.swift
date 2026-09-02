import XCTest
@testable import QAudionEngine

/// TRUST-1 residual. Covers the two hardcoded named policies
/// (`sigsum-test-2025-3`, `sigsum-generic-2025-1`) and
/// `SigsumPolicy.quorumSatisfied`'s recursive group evaluation.
///
/// ⚠️ Requires `swift test`. Authored on win32 — NOT executed in this
/// session; the GitHub Actions macOS runner is the gate.
final class SigsumPolicyTests: XCTestCase {

    // MARK: - Hardcoded key material sanity (every key is a raw 32-byte Ed25519 pubkey)

    func test_bothPolicies_everyKeyIsThirtyTwoBytes() {
        for policy in [SigsumPolicy.sigsumTest2025_3, SigsumPolicy.sigsumGeneric2025_1] {
            for log in policy.logs {
                XCTAssertEqual(log.publicKey.count, 32, "\(policy.name)/\(log.name)")
            }
            for witness in policy.witnesses {
                XCTAssertEqual(witness.publicKey.count, 32, "\(policy.name)/\(witness.name)")
            }
        }
    }

    func test_bothPolicies_noDuplicateKeysWithinLogsOrWitnesses() {
        for policy in [SigsumPolicy.sigsumTest2025_3, SigsumPolicy.sigsumGeneric2025_1] {
            XCTAssertEqual(Set(policy.logs.map { $0.publicKey }).count, policy.logs.count, policy.name)
            XCTAssertEqual(Set(policy.witnesses.map { $0.publicKey }).count, policy.witnesses.count, policy.name)
        }
    }

    // MARK: - sigsum-test-2025-3: log/witness resolution by key hash

    func test_testPolicy_resolvesBarreleyeByKeyHash() {
        let barreleyeKeyHash = SigsumCrypto.sha256(SigsumHex.decode("4644af2abd40f4895a003bca350f9d5912ab301a49c77f13e5b6d905c20a5fe6")!)
        let resolved = SigsumPolicy.sigsumTest2025_3.log(withKeyHash: barreleyeKeyHash)
        XCTAssertEqual(resolved?.name, "test.sigsum.org/barreleye")
    }

    func test_testPolicy_unknownKeyHashResolvesToNil() {
        XCTAssertNil(SigsumPolicy.sigsumTest2025_3.log(withKeyHash: Data(repeating: 0xFF, count: 32)))
        XCTAssertNil(SigsumPolicy.sigsumTest2025_3.witness(withKeyHash: Data(repeating: 0xFF, count: 32)))
    }

    // MARK: - sigsum-test-2025-3 quorum: 4-of-6 top level, one member itself a nested 2-of-3

    func test_testPolicy_quorum_allEightRealWitnesses_satisfied() {
        // The exact set independently verified live against
        // test.sigsum.org/barreleye in SigsumProtocolTests/SigsumMerkleTests
        // — every witness this policy knows about had a valid cosignature.
        let allNames: Set<String> = [
            "poc.sigsum.org/nisse", "rgdd.se/poc-witness", "witness1.smartit.nu/witness1",
            "witness.navigli.sunlight.geomys.org", "remora.n621.de", "witness.stagemole.eu",
            "tillitis.se/test-witness-1", "transparency.dev/DEV:witness-little-garden",
        ]
        XCTAssertEqual(allNames, Set(SigsumPolicy.sigsumTest2025_3.witnesses.map { $0.name }), "sanity: fixture set must equal the full policy witness list")
        XCTAssertTrue(SigsumPolicy.sigsumTest2025_3.quorumSatisfied(by: allNames))
    }

    func test_testPolicy_quorum_nestedGroupAloneIsNotEnough() {
        // glasklar-test-witnesses (all 3, satisfying its own 2-of-3) counts
        // as exactly ONE satisfied member of the 6-member top-level group —
        // 1 < 4, must fail.
        let onlyNestedGroup: Set<String> = ["poc.sigsum.org/nisse", "rgdd.se/poc-witness", "witness1.smartit.nu/witness1"]
        XCTAssertFalse(SigsumPolicy.sigsumTest2025_3.quorumSatisfied(by: onlyNestedGroup))
    }

    func test_testPolicy_quorum_fourOfSixExactlyAtThreshold_satisfied() {
        // The nested group with only 2-of-3 (still satisfies its own
        // threshold) plus 3 more of the flat top-level members = 4 total
        // satisfied top-level members, exactly at the threshold.
        let names: Set<String> = [
            "poc.sigsum.org/nisse", "rgdd.se/poc-witness", // 2 of glasklar-test-witnesses (its own threshold)
            "remora.n621.de", "witness.stagemole.eu", "tillitis.se/test-witness-1",
        ]
        XCTAssertTrue(SigsumPolicy.sigsumTest2025_3.quorumSatisfied(by: names))
    }

    func test_testPolicy_quorum_threeOfSixJustBelowThreshold_notSatisfied() {
        let names: Set<String> = ["remora.n621.de", "witness.stagemole.eu", "tillitis.se/test-witness-1"]
        XCTAssertFalse(SigsumPolicy.sigsumTest2025_3.quorumSatisfied(by: names))
    }

    func test_testPolicy_quorum_nestedGroupBelowItsOwnThreshold_doesNotCount() {
        // Only ONE of glasklar-test-witnesses' 3 members — the nested group
        // itself is NOT satisfied (needs 2), so it contributes 0 toward the
        // top level, even combined with 3 other real top-level members.
        let names: Set<String> = ["poc.sigsum.org/nisse", "remora.n621.de", "witness.stagemole.eu", "tillitis.se/test-witness-1"]
        XCTAssertFalse(SigsumPolicy.sigsumTest2025_3.quorumSatisfied(by: names))
    }

    func test_testPolicy_quorum_emptySet_notSatisfied() {
        XCTAssertFalse(SigsumPolicy.sigsumTest2025_3.quorumSatisfied(by: []))
    }

    func test_testPolicy_quorum_unknownNamesIgnored() {
        // Names not present anywhere in the policy must simply not count —
        // they must never crash or be treated as satisfying anything.
        let names: Set<String> = ["not-a-real-witness", "also-not-real"]
        XCTAssertFalse(SigsumPolicy.sigsumTest2025_3.quorumSatisfied(by: names))
    }

    // MARK: - sigsum-generic-2025-1: flat 2-of-3

    func test_genericPolicy_quorum_twoOfThree_satisfied() {
        XCTAssertTrue(SigsumPolicy.sigsumGeneric2025_1.quorumSatisfied(by: ["witness.glasklar.is", "witness.mullvad.net"]))
    }

    func test_genericPolicy_quorum_oneOfThree_notSatisfied() {
        XCTAssertFalse(SigsumPolicy.sigsumGeneric2025_1.quorumSatisfied(by: ["witness.glasklar.is"]))
    }

    func test_genericPolicy_quorum_allThree_satisfied() {
        XCTAssertTrue(SigsumPolicy.sigsumGeneric2025_1.quorumSatisfied(by: ["witness.glasklar.is", "witness.mullvad.net", "tillitis.se/tillitis-witness-1"]))
    }

    func test_genericPolicy_resolvesSeasalpAndGinkgoByKeyHash() {
        let seasalpKeyHash = SigsumCrypto.sha256(SigsumHex.decode("0ec7e16843119b120377a73913ac6acbc2d03d82432e2c36b841b09a95841f25")!)
        let ginkgoKeyHash = SigsumCrypto.sha256(SigsumHex.decode("f00c159663d09bbda6131ee1816863b6adcacfe80b0b288000b11aba8fe38314")!)
        XCTAssertEqual(SigsumPolicy.sigsumGeneric2025_1.log(withKeyHash: seasalpKeyHash)?.name, "seasalp.glasklar.is")
        XCTAssertEqual(SigsumPolicy.sigsumGeneric2025_1.log(withKeyHash: ginkgoKeyHash)?.name, "ginkgo.tlog.mullvad.net")
    }

    // MARK: - Group evaluator does not infinitely recurse on a malformed policy

    func test_quorumSatisfied_missingQuorumGroup_returnsFalseNotCrash() {
        let broken = SigsumPolicy(name: "broken", logs: [], witnesses: [], groups: [], quorumGroupName: "does-not-exist")
        XCTAssertFalse(broken.quorumSatisfied(by: ["anything"]))
    }

    func test_quorumSatisfied_selfReferencingGroup_returnsFalseNotHang() {
        // Deliberately malformed (would never come from a real policy file,
        // whose grammar disallows forward references) — the depth guard in
        // `SigsumPolicy.evaluate` must still terminate.
        let cyclic = SigsumQuorumGroup(name: "cyclic", threshold: 1, members: [.group("cyclic")])
        let broken = SigsumPolicy(name: "broken", logs: [], witnesses: [], groups: [cyclic], quorumGroupName: "cyclic")
        XCTAssertFalse(broken.quorumSatisfied(by: []))
    }
}

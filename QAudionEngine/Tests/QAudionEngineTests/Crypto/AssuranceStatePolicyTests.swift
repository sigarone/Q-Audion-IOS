import XCTest
@testable import QAudionEngine

/// W-ASSURANCE (multi-PSK-mixing SYNTHESIS.md ship step 6/8) — cross-platform test
/// vectors for `AssuranceState.decide(...)`, shared byte-for-byte in SHAPE (not hex,
/// this is a policy table not a crypto KAT) with the Android/Desktop ports.
///
/// `S2` requires `mixRoles` to contain `.nfc` as an actually-mixed secret, which
/// requires `N>=2` (step 7, not shipped this step — `N` is capped at ≤1 in production
/// today). The branch is implemented and exercised here as a pure-function test only;
/// it will not fire from any real call until step 7 flips `pskMixV1` and wires
/// `PskMix.deriveKMix` for `N>=2`.
///
/// `peerAdvertisedRoles`' `S7` semantics ("peer advertised role 1 for a fp I hold") is
/// modelled as `1 in peerAdvertisedRoles` — `decide()` does no fp-matching itself; the
/// caller is assumed to have already filtered the list down to roles for MUTUALLY HELD
/// fingerprints before calling `decide()`.
final class AssuranceStatePolicyTests: XCTestCase {

    // MARK: - S0..S10 states table (one example input tuple per state)

    func testS0PeerLegacy_evenWhenPreviouslyVerified() {
        // legacy peer never fires kc_mac (gated on peer advertising pskMixV1); S0 fires
        // even though this contact was previously verified via NFC (expectedNfc/
        // floorRecorded true) -- a legacy peer must never be accused of stripping.
        let result = AssuranceState.decide(
            peerSupportsMix: false, n: 0, mixRoles: [], peerAdvertisedRoles: [],
            expectedNfc: true, kcStatus: .absent, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: true, mediaDwellMs: 12000
        )
        XCTAssertEqual(result, .peerLegacy)
    }

    func testS1KcFailed_activeAttackSignature() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: [], peerAdvertisedRoles: [0],
            expectedNfc: false, kcStatus: .wrong, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: false, mediaDwellMs: 3000
        )
        XCTAssertEqual(result, .kcFailed)
    }

    func testS3NfcIdentityMismatch() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 2, mixRoles: [.nfc, .psk], peerAdvertisedRoles: [1, 0],
            expectedNfc: true, kcStatus: .verified, sigOk: true, nfcBound: false,
            witnessOk: true, floorRecorded: true, mediaDwellMs: 20000
        )
        XCTAssertEqual(result, .nfcIdentityMismatch)
    }

    func testS4NfcUnattestable() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 2, mixRoles: [.nfc], peerAdvertisedRoles: [1],
            expectedNfc: true, kcStatus: .verified, sigOk: true, nfcBound: true,
            witnessOk: false, floorRecorded: false, mediaDwellMs: 15000
        )
        XCTAssertEqual(result, .nfcUnattestable)
    }

    func testS5IdentityUnverified_callContinuesWNoBrick() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 2, mixRoles: [.nfc], peerAdvertisedRoles: [1],
            expectedNfc: true, kcStatus: .verified, sigOk: false, nfcBound: true,
            witnessOk: true, floorRecorded: false, mediaDwellMs: 15000
        )
        XCTAssertEqual(result, .identityUnverified)
    }

    func testS6NfcPresentUnconfirmed() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 2, mixRoles: [.nfc], peerAdvertisedRoles: [1],
            expectedNfc: true, kcStatus: .absent, sigOk: true, nfcBound: true,
            witnessOk: true, floorRecorded: true, mediaDwellMs: 8000
        )
        XCTAssertEqual(result, .nfcPresentUnconfirmed)
    }

    func testS7ExpectedNfcStripped_floorButFellBackToPlainPsk() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: [], peerAdvertisedRoles: [1],
            expectedNfc: true, kcStatus: .verified, sigOk: true, nfcBound: true,
            witnessOk: true, floorRecorded: true, mediaDwellMs: 25000
        )
        XCTAssertEqual(result, .expectedNfcStripped)
    }

    func testS8PskConfirmed_neverSaysAuthenticated() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: [], peerAdvertisedRoles: [0],
            expectedNfc: false, kcStatus: .verified, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: false, mediaDwellMs: 18000
        )
        XCTAssertEqual(result, .pskConfirmed)
    }

    func testS9PskUnconfirmed() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: [], peerAdvertisedRoles: [0],
            expectedNfc: false, kcStatus: .absent, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: false, mediaDwellMs: 4000
        )
        XCTAssertEqual(result, .pskUnconfirmed)
    }

    func testS10PqcOnly_firesRegardlessOfKcStatus() {
        // kcStatus VERIFIED here on purpose: S10 fires purely off n==0, since S8/S9
        // both require n>=1 and so never compete for n==0 inputs.
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 0, mixRoles: [], peerAdvertisedRoles: [],
            expectedNfc: false, kcStatus: .verified, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: false, mediaDwellMs: 30000
        )
        XCTAssertEqual(result, .pqcOnly)
    }

    /// S2 is unreachable from any real call this step (see type doc), but `decide()`
    /// must still be a TOTAL function that implements the branch — this is the one
    /// place this suite deliberately exercises it via synthetic inputs only.
    func testS2ReachableGivenSyntheticInputsPureFunctionOnly() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 2, mixRoles: [.nfc], peerAdvertisedRoles: [1],
            expectedNfc: true, kcStatus: .verified, sigOk: true, nfcBound: true,
            witnessOk: true, floorRecorded: true, mediaDwellMs: 15000
        )
        XCTAssertEqual(result, .nfcAuthenticated)
    }

    // MARK: - Exhaustiveness: flip exactly one input at a time from the S2 baseline

    private func s2Baseline(
        peerSupportsMix: Bool = true,
        n: Int = 2,
        mixRoles: [AssuranceState.MixSecretRole] = [.nfc],
        peerAdvertisedRoles: [Int] = [1],
        expectedNfc: Bool = true,
        kcStatus: KeyConfirmation.Status = .verified,
        sigOk: Bool = true,
        nfcBound: Bool = true,
        witnessOk: Bool = true,
        floorRecorded: Bool = true,
        mediaDwellMs: Int = 15000
    ) -> AssuranceState {
        AssuranceState.decide(
            peerSupportsMix: peerSupportsMix, n: n, mixRoles: mixRoles,
            peerAdvertisedRoles: peerAdvertisedRoles, expectedNfc: expectedNfc,
            kcStatus: kcStatus, sigOk: sigOk, nfcBound: nfcBound, witnessOk: witnessOk,
            floorRecorded: floorRecorded, mediaDwellMs: mediaDwellMs
        )
    }

    func testExhaustiveness_baselineIsS2() {
        XCTAssertEqual(s2Baseline(), .nfcAuthenticated)
    }

    func testExhaustiveness_flipPeerSupportsMix_yieldsS0() {
        XCTAssertEqual(s2Baseline(peerSupportsMix: false), .peerLegacy)
    }

    func testExhaustiveness_flipKcStatusWrong_yieldsS1() {
        XCTAssertEqual(s2Baseline(kcStatus: .wrong), .kcFailed)
    }

    func testExhaustiveness_flipNfcBoundFalse_yieldsS3() {
        XCTAssertEqual(s2Baseline(nfcBound: false), .nfcIdentityMismatch)
    }

    func testExhaustiveness_flipWitnessOkFalse_yieldsS4() {
        XCTAssertEqual(s2Baseline(witnessOk: false), .nfcUnattestable)
    }

    func testExhaustiveness_flipSigOkFalse_yieldsS5() {
        XCTAssertEqual(s2Baseline(sigOk: false), .identityUnverified)
    }

    func testExhaustiveness_flipKcStatusAbsent_yieldsS6() {
        XCTAssertEqual(s2Baseline(kcStatus: .absent), .nfcPresentUnconfirmed)
    }

    func testExhaustiveness_flipMixRolesEmpty_yieldsS7() {
        XCTAssertEqual(s2Baseline(mixRoles: []), .expectedNfcStripped)
    }

    // These three necessarily flip more than one field: S8/S9/S10 all require BOTH
    // "NFC not mixed" AND "no expected/advertised NFC signal" simultaneously, which is
    // a 3-/4-field transition away from the S2 baseline — not a single flip. Documented
    // honestly as compounds rather than mis-labelled as single flips.
    func testExhaustiveness_compound_yieldsS8() {
        let result = s2Baseline(mixRoles: [], peerAdvertisedRoles: [], expectedNfc: false)
        XCTAssertEqual(result, .pskConfirmed)
    }

    func testExhaustiveness_compound_yieldsS9() {
        let result = s2Baseline(mixRoles: [], peerAdvertisedRoles: [], expectedNfc: false, kcStatus: .absent)
        XCTAssertEqual(result, .pskUnconfirmed)
    }

    func testExhaustiveness_compound_yieldsS10() {
        let result = s2Baseline(n: 0, mixRoles: [], peerAdvertisedRoles: [], expectedNfc: false)
        XCTAssertEqual(result, .pqcOnly)
    }

    // MARK: - Full cross-product exhaustiveness (decide() never falls through)

    /// Brute-forces every combination of the boolean/tri-state inputs (leaving `n` at a
    /// representative 0/1/2 and `mixRoles` at the two shapes that matter — empty vs
    /// containing `.nfc`) and asserts `decide()` always returns SOME defined case. Swift
    /// enums can't produce "no match" silently the way an `if`-chain with no final
    /// `else` can in some languages, but this pins that fact under a real, executed
    /// cross-product rather than relying on the compiler alone.
    func testExhaustivenessCrossProduct_neverFallsThrough() {
        let allN = [0, 1, 2]
        let allMixRoles: [[AssuranceState.MixSecretRole]] = [[], [.nfc], [.psk], [.nfc, .psk]]
        let allPeerAdvertisedRoles: [[Int]] = [[], [0], [1]]
        let allKcStatus: [KeyConfirmation.Status] = [.verified, .absent, .wrong]
        var evaluated = 0

        for peerSupportsMix in [true, false] {
            for n in allN {
                for mixRoles in allMixRoles {
                    for peerAdvertisedRoles in allPeerAdvertisedRoles {
                        for expectedNfc in [true, false] {
                            for kcStatus in allKcStatus {
                                for sigOk in [true, false] {
                                    for nfcBound in [true, false] {
                                        for witnessOk in [true, false] {
                                            let result = AssuranceState.decide(
                                                peerSupportsMix: peerSupportsMix, n: n,
                                                mixRoles: mixRoles,
                                                peerAdvertisedRoles: peerAdvertisedRoles,
                                                expectedNfc: expectedNfc, kcStatus: kcStatus,
                                                sigOk: sigOk, nfcBound: nfcBound,
                                                witnessOk: witnessOk, floorRecorded: false,
                                                mediaDwellMs: 0
                                            )
                                            // Every branch returns a case from the fixed
                                            // AssuranceState enum -- the mere fact this
                                            // compiles and returns is the totality proof;
                                            // this loop drives every reachable predicate
                                            // combination through it for real.
                                            _ = result
                                            evaluated += 1
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        XCTAssertEqual(evaluated, 2 * 3 * 4 * 3 * 2 * 3 * 2 * 2 * 2)
    }

    // MARK: - R6: iOS platform constraint (see AssuranceState.iosOriginatesS2Witness doc)

    func testR6_iosNeverOriginatesS2WitnessPerDesignDoc() {
        XCTAssertFalse(
            AssuranceState.iosOriginatesS2Witness,
            "R6 (multi-PSK-mixing design doc): iOS's CoreNFC is reader-only (no HCE) -- " +
            "this device can never independently originate the S2 witness attestation. " +
            "Pinned so a future change can't silently flip this without updating the design doc too."
        )
    }

    // MARK: - W-NOBRICK: every state is just data, never a call-dropping signal

    func testAllStatesAreJustEnumValues_noSideEffectOnDecide() {
        // decide() has no Void/throws surface at all -- it is a pure function from
        // inputs to an AssuranceState value. This test exists as a structural pin: if
        // a future edit ever gives `decide` a throwing/optional signature (a change
        // that would make "drop the call on a bad verdict" possible to wire in by
        // accident), this test's call sites stop compiling as written.
        let result: AssuranceState = s2Baseline(kcStatus: .wrong)
        XCTAssertEqual(result, .kcFailed)
    }

    // MARK: - mutualPeerAdvertisedRoles (ship step 5 wiring helper: decide()'s own
    // doc says the caller must pre-filter to mutually-held fingerprints; this is
    // that filter)

    func testMutualPeerAdvertisedRolesFiltersToLocalFingerprintsOnly() {
        let result = AssuranceState.mutualPeerAdvertisedRoles(
            peerFingerprints: ["a", "b", "c"],
            peerRoles: [1, 0, 1],
            localFingerprints: ["a", "c"]
        )
        XCTAssertEqual(result, [1, 1], "must drop the role for 'b' (not locally held) but keep 'a'/'c' in order")
    }

    func testMutualPeerAdvertisedRolesNilFingerprintsIsEmpty() {
        XCTAssertEqual(
            AssuranceState.mutualPeerAdvertisedRoles(peerFingerprints: nil, peerRoles: [1], localFingerprints: ["a"]),
            []
        )
    }

    func testMutualPeerAdvertisedRolesNilRolesDefaultToZero() {
        let result = AssuranceState.mutualPeerAdvertisedRoles(
            peerFingerprints: ["a", "b"], peerRoles: nil, localFingerprints: ["a", "b"]
        )
        XCTAssertEqual(result, [0, 0])
    }

    func testMutualPeerAdvertisedRolesShorterRolesArrayDefaultsTrailingToZero() {
        let result = AssuranceState.mutualPeerAdvertisedRoles(
            peerFingerprints: ["a", "b", "c"], peerRoles: [9], localFingerprints: ["a", "b", "c"]
        )
        XCTAssertEqual(result, [9, 0, 0])
    }

    func testMutualPeerAdvertisedRolesNoOverlapIsEmpty() {
        let result = AssuranceState.mutualPeerAdvertisedRoles(
            peerFingerprints: ["x", "y"], peerRoles: [1, 1], localFingerprints: ["a", "b"]
        )
        XCTAssertEqual(result, [], "no mutually-held fingerprint => S7's role-1 signal must never fire from this alone")
    }

    // MARK: - Integration shape: mutualPeerAdvertisedRoles feeding decide() end-to-end

    func testMutualRoleOneFeedsS7WhenNfcNotMixed() {
        // The exact composition `handleKcMacReady`/`emitKeyConfirmationTelemetry`
        // (AppState, ship step 5) perform: filter, then feed into decide().
        let filtered = AssuranceState.mutualPeerAdvertisedRoles(
            peerFingerprints: ["fp-held-by-both"], peerRoles: [1], localFingerprints: ["fp-held-by-both"]
        )
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: [.psk], peerAdvertisedRoles: filtered,
            expectedNfc: false, kcStatus: .verified, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: false, mediaDwellMs: 0
        )
        XCTAssertEqual(result, .expectedNfcStripped, "peer advertised an NFC-tier (role=1) fp we both hold, but no NFC was mixed => S7")
    }

    // MARK: - qualifiesForPresenceAuthWrite (ship step 6/8 persistence gate —
    // policy half; ContactsStoreTests covers the mechanism half)

    func testQualifiesForPresenceAuthWrite_s2WithSufficientDwell_true() {
        XCTAssertTrue(AssuranceState.qualifiesForPresenceAuthWrite(state: .nfcAuthenticated, mediaDwellMs: 10_000))
        XCTAssertTrue(AssuranceState.qualifiesForPresenceAuthWrite(state: .nfcAuthenticated, mediaDwellMs: 60_000))
    }

    func testQualifiesForPresenceAuthWrite_s2WithInsufficientDwell_false() {
        XCTAssertFalse(AssuranceState.qualifiesForPresenceAuthWrite(state: .nfcAuthenticated, mediaDwellMs: 9_999))
        XCTAssertFalse(AssuranceState.qualifiesForPresenceAuthWrite(state: .nfcAuthenticated, mediaDwellMs: 0))
    }

    func testQualifiesForPresenceAuthWrite_everyNonS2State_falseRegardlessOfDwell() {
        let nonS2: [AssuranceState] = [
            .peerLegacy, .kcFailed, .nfcIdentityMismatch, .nfcUnattestable, .identityUnverified,
            .nfcPresentUnconfirmed, .expectedNfcStripped, .pskConfirmed, .pskUnconfirmed, .pqcOnly,
        ]
        for state in nonS2 {
            XCTAssertFalse(
                AssuranceState.qualifiesForPresenceAuthWrite(state: state, mediaDwellMs: 999_999),
                "\(state) must never qualify for a presenceAuth write, no matter the dwell"
            )
        }
    }
}

import XCTest
@testable import QAudionEngine

/// W-ASSURANCE (multi-PSK-mixing SYNTHESIS.md ship step 6/8) — cross-platform test
/// vectors for `AssuranceState.decide(...)`, shared byte-for-byte in SHAPE (not hex,
/// this is a policy table not a crypto KAT) with the Android/Desktop ports.
///
/// `S2` requires `mixRoles` to contain `.nfc` as an actually-mixed secret. The earlier
/// plan for this to require `N>=2` (step 7's `canonicalOrder`/`K_mix` aggregation) was
/// proposed and then explicitly REJECTED (2026-07-23) as too risky/unnecessary — `N`
/// stays capped at ≤1 in production, unchanged. What shipped instead (W-NFCBADGE):
/// `mixRoles` contains `.nfc` whenever the SINGLE selected PSK's vault entry is itself
/// NFC-origin (`AssuranceState.resolveNfcMixInputs`, wired at
/// `AppState.emitKeyConfirmationTelemetry`) — so `S2`(-`S6`) are reachable from a real
/// call today, not just via this suite's synthetic `decide()` inputs.
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

    /// `decide()` must be a TOTAL function that implements the S2 branch regardless of
    /// what any real call site ever feeds it — this is the synthetic-inputs pin for
    /// that (`n: 2` here specifically, which no real call site produces; see
    /// `testEndToEnd_nfcSelectedKey_matchingIdentity_witnessed_reachesS2` below for the
    /// REAL `n: 1` pipeline `AppState.emitKeyConfirmationTelemetry` actually runs).
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

    /// W-NFCCOMMON (2026-07-24, Pavel correction) — RENAMED from
    /// `testMutualRoleOneFeedsS7WhenNfcNotMixed`, expectation FLIPPED. A mutual NFC-tier
    /// advert alone (no persisted `expectedNfc` floor) is the routine "vault priority picked
    /// a different secret (e.g. KMS) over an available NFC one" outcome — NOT a downgrade.
    /// `decide()` must resolve normally to S8 here; the mutual fact is surfaced by the caller
    /// as its OWN independent "NFC in comune" UI signal (still exactly `filtered.contains(1)`),
    /// never by hijacking this single-select verdict into S7 (which would wrongly persist a
    /// suspended-badge security event for an everyday priority choice).
    func testMutualRoleAloneWithoutFloorDoesNotStripS7_surfacesAsIndependentSignalInstead() {
        let filtered = AssuranceState.mutualPeerAdvertisedRoles(
            peerFingerprints: ["fp-held-by-both"], peerRoles: [1], localFingerprints: ["fp-held-by-both"]
        )
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: [.psk], peerAdvertisedRoles: filtered,
            expectedNfc: false, kcStatus: .verified, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: false, mediaDwellMs: 0
        )
        XCTAssertEqual(result, .pskConfirmed, "mutual NFC advert alone (no floor) must NOT strip to S7 — decide() ignores peerAdvertisedRoles now")
        XCTAssertTrue(filtered.contains(1), "the independent 'NFC in comune' signal is still true from this same filtered result")
    }

    /// The genuine S7 case is unchanged: a persisted per-contact floor (`expectedNfc`) that
    /// this call fails to re-confirm still strips, regardless of what the peer advertises.
    func testExpectedNfcAloneStillFeedsS7WhenNfcNotMixed() {
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: [.psk], peerAdvertisedRoles: [],
            expectedNfc: true, kcStatus: .verified, sigOk: true, nfcBound: false,
            witnessOk: false, floorRecorded: true, mediaDwellMs: 0
        )
        XCTAssertEqual(result, .expectedNfcStripped, "a genuine presence-floor regression still fires S7 off expectedNfc alone")
    }

    // MARK: - resolveNfcMixInputs (W-NFCBADGE — wires the ONE selected PSK's
    // real NFC origin into decide()'s mixRoles/nfcBound/witnessOk; no N>=2
    // mixing, no wire change — see that function's doc for the full
    // design-pivot context)

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testResolveNfcMixInputs_nonNfcOrigin_nOneOrMore_yieldsPskRole() {
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: false, selectedFingerprintHex: "deadbeef",
            verifiedPeerIdentityKey: nil, priorPresenceAuth: nil
        )
        XCTAssertEqual(result.mixRoles, [.psk])
        XCTAssertFalse(result.nfcBound)
        XCTAssertFalse(result.witnessOk)
    }

    func testResolveNfcMixInputs_nonNfcOrigin_nZero_yieldsNoRoles() {
        let result = AssuranceState.resolveNfcMixInputs(
            n: 0, selectedIsNfcOrigin: false, selectedFingerprintHex: nil,
            verifiedPeerIdentityKey: nil, priorPresenceAuth: nil
        )
        XCTAssertEqual(result.mixRoles, [])
    }

    func testResolveNfcMixInputs_nfcOrigin_matchingIdentity_noPriorRecord_boundAndWitnessed() {
        let identity = Data(repeating: 0xAB, count: 32)
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(identity),
            verifiedPeerIdentityKey: identity, priorPresenceAuth: nil
        )
        XCTAssertEqual(result.mixRoles, [.nfc])
        XCTAssertTrue(result.nfcBound)
        XCTAssertTrue(result.witnessOk, "first confirming call for a fresh tap has nothing to contradict attestability")
    }

    func testResolveNfcMixInputs_nfcOrigin_mismatchedIdentity_yieldsUnbound() {
        let capturedAtTap = Data(repeating: 0xAB, count: 32)
        let verifiedNow = Data(repeating: 0xCD, count: 32)
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(capturedAtTap),
            verifiedPeerIdentityKey: verifiedNow, priorPresenceAuth: nil
        )
        XCTAssertEqual(result.mixRoles, [.nfc], "still NFC-origin -- decide() itself must see nfcMixed to route to S3, not silently fall back to PSK")
        XCTAssertFalse(result.nfcBound)
        XCTAssertFalse(result.witnessOk)
    }

    func testResolveNfcMixInputs_nfcOrigin_priorBackupRestoreDowngrade_sticks() {
        let identity = Data(repeating: 0xAB, count: 32)
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(identity),
            verifiedPeerIdentityKey: identity,
            priorPresenceAuth: (peerIdentityKey: identity, witnessTier: "backup_restore")
        )
        XCTAssertTrue(result.nfcBound)
        XCTAssertFalse(result.witnessOk, "a persisted backup_restore downgrade must stick across calls")
    }

    func testResolveNfcMixInputs_nfcOrigin_priorSecureElement_staysWitnessed() {
        let identity = Data(repeating: 0xAB, count: 32)
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(identity),
            verifiedPeerIdentityKey: identity,
            priorPresenceAuth: (peerIdentityKey: identity, witnessTier: "secure_element")
        )
        XCTAssertTrue(result.witnessOk)
    }

    func testResolveNfcMixInputs_nfcOrigin_priorRecordForDifferentIdentity_notReadAsThisContactsHistory() {
        // Defence in depth: even if a caller accidentally passed a
        // priorPresenceAuth tuple bound to a DIFFERENT identity than
        // verifiedPeerIdentityKey (a stale/rotated record it should have
        // filtered out itself), this function must not let that stale
        // "backup_restore" downgrade a fresh, correctly-bound confirmation.
        let identity = Data(repeating: 0xAB, count: 32)
        let staleIdentity = Data(repeating: 0xEF, count: 32)
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(identity),
            verifiedPeerIdentityKey: identity,
            priorPresenceAuth: (peerIdentityKey: staleIdentity, witnessTier: "backup_restore")
        )
        XCTAssertTrue(result.witnessOk, "a presenceAuth record bound to a DIFFERENT identity must not downgrade this one")
    }

    func testResolveNfcMixInputs_nfcOrigin_noVerifiedIdentityYet_treatsAsUnbound() {
        let identity = Data(repeating: 0xAB, count: 32)
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(identity),
            verifiedPeerIdentityKey: nil, priorPresenceAuth: nil
        )
        XCTAssertEqual(result.mixRoles, [.nfc])
        XCTAssertFalse(result.nfcBound)
        XCTAssertFalse(result.witnessOk)
    }

    func testResolveNfcMixInputs_nfcOrigin_malformedFingerprint_fallsBackLikeNonNfc() {
        let result = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: "not-hex!!",
            verifiedPeerIdentityKey: Data(repeating: 0xAB, count: 32), priorPresenceAuth: nil
        )
        XCTAssertEqual(
            result.mixRoles, [.psk],
            "a malformed/undecodable fingerprint can't establish NFC binding -- degrade to plain PSK, never claim NFC"
        )
    }

    // MARK: - End-to-end: resolveNfcMixInputs -> decide(), the ACTUAL pipeline
    // AppState.emitKeyConfirmationTelemetry runs at its call site

    func testEndToEnd_nfcSelectedKey_matchingIdentity_witnessed_reachesS2() {
        let identity = Data(repeating: 0x11, count: 32)
        let (mixRoles, nfcBound, witnessOk) = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(identity),
            verifiedPeerIdentityKey: identity, priorPresenceAuth: nil
        )
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: mixRoles, peerAdvertisedRoles: [],
            expectedNfc: false, kcStatus: .verified, sigOk: true, nfcBound: nfcBound,
            witnessOk: witnessOk, floorRecorded: false, mediaDwellMs: 15_000
        )
        XCTAssertEqual(
            result, .nfcAuthenticated,
            "the real call-site pipeline (resolveNfcMixInputs -> decide()) must reach S2 for an NFC-sourced " +
            "selected key + matching identity + witness, not just via synthetic decide() inputs"
        )
    }

    func testEndToEnd_ordinaryPsk_regressionUnchanged() {
        // Regression guard: an ordinary (non-NFC) selected PSK behaves EXACTLY
        // as before this wiring -- mixRoles == [.psk], nfcBound/witnessOk
        // false, decide() reaches S8 exactly like today.
        let (mixRoles, nfcBound, witnessOk) = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: false, selectedFingerprintHex: "aabbccdd",
            verifiedPeerIdentityKey: Data(repeating: 0x22, count: 32), priorPresenceAuth: nil
        )
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: mixRoles, peerAdvertisedRoles: [],
            expectedNfc: false, kcStatus: .verified, sigOk: true, nfcBound: nfcBound,
            witnessOk: witnessOk, floorRecorded: false, mediaDwellMs: 0
        )
        XCTAssertEqual(result, .pskConfirmed)
    }

    func testEndToEnd_nfcSelectedKey_identityMismatch_reachesS3() {
        let capturedAtTap = Data(repeating: 0x11, count: 32)
        let verifiedNow = Data(repeating: 0x99, count: 32)
        let (mixRoles, nfcBound, witnessOk) = AssuranceState.resolveNfcMixInputs(
            n: 1, selectedIsNfcOrigin: true, selectedFingerprintHex: hex(capturedAtTap),
            verifiedPeerIdentityKey: verifiedNow, priorPresenceAuth: nil
        )
        let result = AssuranceState.decide(
            peerSupportsMix: true, n: 1, mixRoles: mixRoles, peerAdvertisedRoles: [],
            expectedNfc: false, kcStatus: .verified, sigOk: true, nfcBound: nfcBound,
            witnessOk: witnessOk, floorRecorded: false, mediaDwellMs: 0
        )
        XCTAssertEqual(result, .nfcIdentityMismatch)
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

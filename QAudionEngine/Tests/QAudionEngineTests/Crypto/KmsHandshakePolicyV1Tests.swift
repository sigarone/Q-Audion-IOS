import XCTest
@testable import QAudionEngine

/// KMS-rotation-v2 Phase-1 — D2 negotiation + D3 grace + D4 require-hw-only abort.
/// Pure decision logic; fully host-runnable.
final class KmsHandshakePolicyV1Tests: XCTestCase {

    private typealias P = KmsHandshakePolicyV1
    private typealias KC = SovereignKeyVault.KeyClass

    // MARK: - D2 advertise order (hw_only first)

    func testAdvertiseOrderPutsHwOnlyFirstThenSharedThenSwOnly() {
        let eligible: [(fingerprint: String, keyClass: KC)] = [
            ("shared-A",  .shared),
            ("swonly-B",  .swOnly),
            ("hwonly-C",  .hwOnly),
            ("shared-D",  .shared),
            ("hwonly-E",  .hwOnly),
        ]
        let order = P.advertiseOrder(eligible: eligible)
        // hw_only first (stable: C before E), then shared (A before D), then sw_only.
        XCTAssertEqual(order, ["hwonly-C", "hwonly-E", "shared-A", "shared-D", "swonly-B"])
    }

    func testAdvertiseOrderEmptyIsEmpty() {
        XCTAssertEqual(P.advertiseOrder(eligible: []), [])
    }

    // MARK: - D2 responder selection (caller priority order)

    func testSelectFingerprintPicksFirstAdvertisedHeld() {
        let advertised = ["hwonly-C", "shared-A", "swonly-B"]
        // Holds shared-A + swonly-B but NOT hwonly-C → picks shared-A (first held).
        XCTAssertEqual(P.selectFingerprint(advertised: advertised,
                                           locallyHeld: ["shared-A", "swonly-B"]), "shared-A")
    }

    func testSelectFingerprintEmptyIntersectionIsNil() {
        XCTAssertNil(P.selectFingerprint(advertised: ["x", "y"], locallyHeld: ["z"]))
    }

    // MARK: - D3 grace migration

    func testSignedVerifiedProceeds() {
        XCTAssertEqual(
            P.evaluate(signaturePresent: true, signatureVerified: true, requireSigned: true,
                       contactHasHwOnlyKey: false, negotiatedFingerprint: "shared-A",
                       expectedHwOnlyFingerprint: nil),
            .proceed(selectedFingerprint: "shared-A"))
    }

    func testSignedButBadAlwaysAborts() {
        // even with require_signed OFF, a present-but-invalid sig is fatal.
        XCTAssertEqual(
            P.evaluate(signaturePresent: true, signatureVerified: false, requireSigned: false,
                       contactHasHwOnlyKey: false, negotiatedFingerprint: nil,
                       expectedHwOnlyFingerprint: nil),
            .abortVerifyFailed)
    }

    func testUnsignedLegacyDuringGraceWarns() {
        XCTAssertEqual(
            P.evaluate(signaturePresent: false, signatureVerified: false, requireSigned: false,
                       contactHasHwOnlyKey: false, negotiatedFingerprint: nil,
                       expectedHwOnlyFingerprint: nil),
            .proceedWarnLegacy(selectedFingerprint: nil))
    }

    func testUnsignedWithEnforcementOnAborts() {
        XCTAssertEqual(
            P.evaluate(signaturePresent: false, signatureVerified: false, requireSigned: true,
                       contactHasHwOnlyKey: false, negotiatedFingerprint: nil,
                       expectedHwOnlyFingerprint: nil),
            .abortVerifyFailed)
    }

    // MARK: - D4 require-hw-only abort (the strip defence)

    func testHwOnlyContactWithStrippedFpAborts() {
        // Contact holds hw_only K but negotiation yielded null (MITM strip).
        XCTAssertEqual(
            P.evaluate(signaturePresent: false, signatureVerified: false, requireSigned: false,
                       contactHasHwOnlyKey: true, negotiatedFingerprint: nil,
                       expectedHwOnlyFingerprint: "hwonly-C"),
            .abortHwOnlyRequired)
    }

    func testHwOnlyContactWithDifferentFpAborts() {
        // Negotiation landed on a NON-hw_only fp → downgrade → abort.
        XCTAssertEqual(
            P.evaluate(signaturePresent: true, signatureVerified: true, requireSigned: false,
                       contactHasHwOnlyKey: true, negotiatedFingerprint: "shared-A",
                       expectedHwOnlyFingerprint: "hwonly-C"),
            .abortHwOnlyRequired)
    }

    func testHwOnlyContactWithCorrectFpProceeds() {
        XCTAssertEqual(
            P.evaluate(signaturePresent: true, signatureVerified: true, requireSigned: false,
                       contactHasHwOnlyKey: true, negotiatedFingerprint: "hwonly-C",
                       expectedHwOnlyFingerprint: "hwonly-C"),
            .proceed(selectedFingerprint: "hwonly-C"))
    }

    /// hw_only carve-out is evaluated BEFORE the grace path: a hw_only contact on
    /// an UNSIGNED bundle still proceeds ONLY when the hw_only mix is present, and
    /// it does so via `.proceed` (NOT WarnLegacy) because the mix is the defence.
    func testHwOnlyContactUnsignedButCorrectFpProceedsNotWarnLegacy() {
        XCTAssertEqual(
            P.evaluate(signaturePresent: false, signatureVerified: false, requireSigned: false,
                       contactHasHwOnlyKey: true, negotiatedFingerprint: "hwonly-C",
                       expectedHwOnlyFingerprint: "hwonly-C"),
            .proceed(selectedFingerprint: "hwonly-C"))
    }

    /// A hw_only contact that strips the fp aborts EVEN with a valid signature
    /// over the (stripped) bundle — the policy requires the actual mix, not just
    /// an authenticated downgrade. (Belt-and-braces over the C signature, which
    /// would itself catch a strip of a SIGNED OFFER; this covers the case where
    /// the peer legitimately signed a no-PSK bundle but we hold a hw_only K.)
    func testHwOnlyContactSignedNullSelectionStillAborts() {
        XCTAssertEqual(
            P.evaluate(signaturePresent: true, signatureVerified: true, requireSigned: true,
                       contactHasHwOnlyKey: true, negotiatedFingerprint: nil,
                       expectedHwOnlyFingerprint: "hwonly-C"),
            .abortHwOnlyRequired)
    }
}

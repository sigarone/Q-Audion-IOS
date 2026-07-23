import XCTest
@testable import QAudionEngine

/// W-ASSURANCE (ship step 6) — `AssuranceStateUI.present(...)`'s copy/style
/// mapping. Pins:
///   - every state maps to a NON-EMPTY message and the documented `Style`.
///   - the "never share a widget" / "never say authenticated for PSK-only"
///     constraints the design brief calls out explicitly (S8/S9 never say
///     "authenticated"; S10 never names a key).
///   - S0's compound `expectedNfc`-appended clause.
final class AssuranceStateUITests: XCTestCase {

    // MARK: - One example per state (style + sasRequired)

    func testS0PeerLegacy_infoStyle_sasRequired_noExpectedNfcClause() {
        let p = AssuranceStateUI.present(state: .peerLegacy, expectedNfc: false)
        XCTAssertEqual(p.style, .info)
        XCTAssertTrue(p.sasRequired)
        XCTAssertFalse(p.message.isEmpty)
    }

    func testS0PeerLegacy_expectedNfcTrue_appendsExtraClause() {
        let base = AssuranceStateUI.present(state: .peerLegacy, expectedNfc: false)
        let withExpected = AssuranceStateUI.present(state: .peerLegacy, expectedNfc: true)
        XCTAssertTrue(withExpected.message.count > base.message.count,
                      "expectedNfc=true must APPEND to the base legacy-peer notice, not replace it")
        XCTAssertTrue(withExpected.message.contains("non supporta la conferma di presenza fisica"))
    }

    func testS1KcFailed_warningStyle_sasRequired() {
        let p = AssuranceStateUI.present(state: .kcFailed)
        XCTAssertEqual(p.style, .warning)
        XCTAssertTrue(p.sasRequired)
    }

    func testS2NfcAuthenticated_badgeStyle_sasNotRequired_namesSecretLabel() {
        let p = AssuranceStateUI.present(state: .nfcAuthenticated, secretLabel: "Alice")
        XCTAssertEqual(p.style, .badge)
        XCTAssertFalse(p.sasRequired, "S2 is the highest trust tier -- no SAS demand on top of it")
        XCTAssertTrue(p.message.contains("Alice"))
        XCTAssertTrue(p.isPhysicalPresenceProof, "S2 is the ONLY state the view should render with extra prominence")
    }

    func testS3NfcIdentityMismatch_warningStyle_neverABadge() {
        let p = AssuranceStateUI.present(state: .nfcIdentityMismatch)
        XCTAssertEqual(p.style, .warning)
        XCTAssertNotEqual(p.style, .badge, "S3 must never render as a badge (design brief: 'warning never a badge')")
        XCTAssertTrue(p.sasRequired)
        XCTAssertEqual(p.message, "Questa chiave NFC era stata stabilita con un'altra identità.")
    }

    func testS4NfcUnattestable_exactCopy() {
        let p = AssuranceStateUI.present(state: .nfcUnattestable)
        XCTAssertEqual(p.style, .warning)
        XCTAssertEqual(
            p.message,
            "Chiave ripristinata da backup: la verifica di persona non è attestabile su questo dispositivo."
        )
    }

    func testS5IdentityUnverified_warningNotBadge_callContinues() {
        let p = AssuranceStateUI.present(state: .identityUnverified)
        XCTAssertEqual(p.style, .warning)
        XCTAssertTrue(p.sasRequired)
    }

    func testS6NfcPresentUnconfirmed_exactCopy() {
        let p = AssuranceStateUI.present(state: .nfcPresentUnconfirmed)
        XCTAssertEqual(
            p.message,
            "Chiave di presenza fisica presente, non confermata su questa chiamata."
        )
        XCTAssertTrue(p.sasRequired)
    }

    func testS7ExpectedNfcStripped_exactCopy_sasDemandedRegardless() {
        let p = AssuranceStateUI.present(state: .expectedNfcStripped)
        XCTAssertEqual(
            p.message,
            "La chiave di presenza fisica di questo contatto non è stata usata su questa chiamata."
        )
        XCTAssertTrue(p.sasRequired)
    }

    func testS8PskConfirmed_neverSaysAuthenticated_namesSecretLabel() {
        let p = AssuranceStateUI.present(state: .pskConfirmed, secretLabel: "Bob")
        XCTAssertEqual(p.style, .badge)
        XCTAssertFalse(p.sasRequired)
        XCTAssertTrue(p.message.contains("Bob"))
        XCTAssertFalse(
            p.message.lowercased().contains("authenticated"),
            "design brief: S8 must NEVER use the word 'authenticated'"
        )
        XCTAssertFalse(p.message.lowercased().contains("autenticat"),
                        "nor its Italian cognate ('autenticato'/'autenticata')")
    }

    func testS9PskUnconfirmed_sameWordingAsS8PlusNonConfermata() {
        let confirmed = AssuranceStateUI.present(state: .pskConfirmed, secretLabel: "Carol")
        let unconfirmed = AssuranceStateUI.present(state: .pskUnconfirmed, secretLabel: "Carol")
        XCTAssertTrue(unconfirmed.message.hasPrefix(confirmed.message))
        XCTAssertTrue(unconfirmed.message.contains("non confermata"))
        XCTAssertTrue(unconfirmed.sasRequired)
    }

    func testS10PqcOnly_exactCopy_neverNamesAKey() {
        let p = AssuranceStateUI.present(state: .pqcOnly, secretLabel: "SHOULD-NEVER-APPEAR")
        XCTAssertEqual(p.message, "Solo PQC (ML-KEM-1024 + X25519)")
        XCTAssertFalse(
            p.message.contains("SHOULD-NEVER-APPEAR"),
            "design brief: S10 MUST NOT name any key -- secretLabel must be ignored entirely"
        )
        XCTAssertTrue(p.sasRequired)
    }

    // MARK: - Exhaustiveness / structural pins

    func testEveryStateProducesANonEmptyMessage() {
        let allStates: [AssuranceState] = [
            .peerLegacy, .kcFailed, .nfcAuthenticated, .nfcIdentityMismatch, .nfcUnattestable,
            .identityUnverified, .nfcPresentUnconfirmed, .expectedNfcStripped, .pskConfirmed,
            .pskUnconfirmed, .pqcOnly,
        ]
        for state in allStates {
            let p = AssuranceStateUI.present(state: state)
            XCTAssertFalse(p.message.isEmpty, "\(state) produced an empty message")
        }
        XCTAssertEqual(allStates.count, 11, "one entry per S0..S10 -- keep this list in sync with AssuranceState")
    }

    /// W-NFCBADGE — `isPhysicalPresenceProof` must be `true` for S2 and ONLY S2.
    /// The view uses this flag (not a raw `AssuranceState` switch) to decide
    /// whether to render the extra-prominent NFC badge treatment, so a false
    /// positive on any other state would make an ordinary PSK/PQC call look
    /// like it proved physical presence.
    func testIsPhysicalPresenceProof_trueOnlyForS2() {
        let allStates: [AssuranceState] = [
            .peerLegacy, .kcFailed, .nfcAuthenticated, .nfcIdentityMismatch, .nfcUnattestable,
            .identityUnverified, .nfcPresentUnconfirmed, .expectedNfcStripped, .pskConfirmed,
            .pskUnconfirmed, .pqcOnly,
        ]
        for state in allStates {
            let p = AssuranceStateUI.present(state: state)
            if state == .nfcAuthenticated {
                XCTAssertTrue(p.isPhysicalPresenceProof, "\(state) must set isPhysicalPresenceProof")
            } else {
                XCTAssertFalse(p.isPhysicalPresenceProof, "\(state) must NOT set isPhysicalPresenceProof")
            }
        }
    }

    /// W-NOBRICK structural pin: `Presentation` carries no throwing/void
    /// surface that could be (mis)used to gate a call -- it is pure display
    /// data, same discipline as `AssuranceState.decide()` itself.
    func testPresentationIsPureDisplayData_noSideEffectSurface() {
        let p1 = AssuranceStateUI.present(state: .kcFailed)
        let p2 = AssuranceStateUI.present(state: .kcFailed)
        XCTAssertEqual(p1, p2, "present() must be a pure function of its inputs")
    }
}

import XCTest
import SwiftUI
import UIKit
@testable import QAudionApp

/// Design system, the accessibility settings of the user, and the decisions behind what the call screens print:
///  - the text follows the text size chosen in Settings (Dynamic Type), up to one declared cap, and does not change
///    at the default size;
///  - floating surfaces drop the translucent material for an opaque color when "Reduce Transparency" is on;
///  - the security badge, the handshake log of the outgoing screen and the "DEMO" badges print only what the call
///    reports: each of them reads from a pure function, and these cases call those functions.
///
/// Every case calls real code with real inputs; none reads a source file or the string catalog. Wired into CI: on
/// the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class DesignSystemAccessibilityTests: XCTestCase {

    // MARK: - Roles: default metrics and text style family

    private struct RoleSpec {
        let name: String
        let size: CGFloat
        let weight: Font.Weight
        let lineHeight: CGFloat
        let tracking: CGFloat
        let family: QAudionTypography.Family
    }

    /// The table at the default text size. Pinned in full: scaling must not change a single value of it.
    private let expectedRoles: [RoleSpec] = [
        RoleSpec(name: "displayLarge", size: 57, weight: .regular, lineHeight: 64, tracking: -0.25, family: .display),
        RoleSpec(name: "displayMedium", size: 45, weight: .regular, lineHeight: 52, tracking: 0.0, family: .display),
        RoleSpec(name: "displaySmall", size: 36, weight: .regular, lineHeight: 44, tracking: 0.0, family: .display),
        RoleSpec(name: "headlineLarge", size: 32, weight: .bold, lineHeight: 40, tracking: 0.0, family: .headline),
        RoleSpec(name: "headlineMedium", size: 28, weight: .bold, lineHeight: 36, tracking: 0.0, family: .headline),
        RoleSpec(name: "headlineSmall", size: 24, weight: .medium, lineHeight: 32, tracking: 0.0, family: .headline),
        RoleSpec(name: "titleLarge", size: 22, weight: .medium, lineHeight: 28, tracking: 0.0, family: .title),
        RoleSpec(name: "titleMedium", size: 16, weight: .medium, lineHeight: 24, tracking: 0.15, family: .title),
        RoleSpec(name: "titleSmall", size: 14, weight: .medium, lineHeight: 20, tracking: 0.10, family: .title),
        RoleSpec(name: "bodyLarge", size: 16, weight: .regular, lineHeight: 24, tracking: 0.50, family: .body),
        RoleSpec(name: "bodyMedium", size: 14, weight: .regular, lineHeight: 20, tracking: 0.25, family: .body),
        RoleSpec(name: "bodySmall", size: 12, weight: .regular, lineHeight: 16, tracking: 0.40, family: .body),
        RoleSpec(name: "labelLarge", size: 14, weight: .medium, lineHeight: 20, tracking: 0.10, family: .label),
        RoleSpec(name: "labelMedium", size: 12, weight: .medium, lineHeight: 16, tracking: 0.50, family: .label),
        RoleSpec(name: "labelSmall", size: 11, weight: .medium, lineHeight: 16, tracking: 0.50, family: .label)
    ]

    func testEveryRoleKeepsItsDefaultMetricsAndItsTextStyleFamily() {
        let actual = QAudionTypography.standard.roles
        XCTAssertEqual(actual.map { $0.name }, expectedRoles.map { $0.name })
        for (spec, role) in zip(expectedRoles, actual) {
            XCTAssertEqual(role.style.size, spec.size, spec.name)
            XCTAssertEqual(role.style.weight, spec.weight, spec.name)
            XCTAssertEqual(role.style.lineHeight, spec.lineHeight, spec.name)
            XCTAssertEqual(role.style.tracking, spec.tracking, spec.name)
            XCTAssertEqual(role.style.family, spec.family, spec.name)
        }
    }

    /// display -> largeTitle, headline -> title, title -> headline, body -> body, label -> caption.
    func testTheFamiliesFollowTheSystemTextStylesOfTheirKind() {
        XCTAssertEqual(QAudionTypography.Family.display.textStyle, UIFont.TextStyle.largeTitle)
        XCTAssertEqual(QAudionTypography.Family.headline.textStyle, UIFont.TextStyle.title1)
        XCTAssertEqual(QAudionTypography.Family.title.textStyle, UIFont.TextStyle.headline)
        XCTAssertEqual(QAudionTypography.Family.body.textStyle, UIFont.TextStyle.body)
        XCTAssertEqual(QAudionTypography.Family.label.textStyle, UIFont.TextStyle.caption1)
    }

    /// The cap is declared once, here and in `QAudionTypography.maxDynamicTypeSize` only.
    func testTheCapIsAccessibility3() {
        XCTAssertEqual(QAudionTypography.maxDynamicTypeSize, DynamicTypeSize.accessibility3)
    }

    // MARK: - Scaling

    /// At the default size ("Large") nothing changes: the factor is exactly 1 and the whole table is the same value.
    func testTheDefaultSizeLeavesEveryRoleExactlyAsItIs() {
        for family in QAudionTypography.Family.allCases {
            XCTAssertEqual(QAudionTypography.scaleFactor(for: family, at: .large), 1, "\(family)")
        }
        XCTAssertEqual(QAudionTypography.standard.scaled(for: .large), QAudionTypography.standard)
        XCTAssertEqual(QAudionTypography.scaledSize(11, family: .label, at: .large), 11)
    }

    /// Smaller text size -> smaller text; a larger one never makes it smaller; the biggest accessibility sizes up to
    /// the cap make it clearly bigger.
    func testTextFollowsTheSizeTheUserPicks() {
        let sizes = DynamicTypeSize.allCases.sorted()
        for family in QAudionTypography.Family.allCases {
            XCTAssertLessThan(QAudionTypography.scaleFactor(for: family, at: .xSmall), 1, "\(family)")
            XCTAssertGreaterThan(QAudionTypography.scaleFactor(for: family, at: .accessibility3), 1, "\(family)")
            var previous: CGFloat = 0
            for size in sizes {
                let factor = QAudionTypography.scaleFactor(for: family, at: size)
                XCTAssertGreaterThanOrEqual(factor, previous, "\(family) at \(size)")
                previous = factor
            }
        }
    }

    /// Above the cap text stops growing.
    func testSizesAboveTheCapAreTheCap() {
        let cap = QAudionTypography.maxDynamicTypeSize
        for family in QAudionTypography.Family.allCases {
            let atCap = QAudionTypography.scaleFactor(for: family, at: cap)
            XCTAssertLessThanOrEqual(QAudionTypography.scaleFactor(for: family, at: .accessibility2), atCap, "\(family)")
            XCTAssertEqual(QAudionTypography.scaleFactor(for: family, at: .accessibility4), atCap, "\(family)")
            XCTAssertEqual(QAudionTypography.scaleFactor(for: family, at: .accessibility5), atCap, "\(family)")
        }
        // Body text is still growing right below the cap: the cap is where it stops, not an earlier plateau.
        XCTAssertLessThan(QAudionTypography.scaleFactor(for: .body, at: .accessibility2),
                          QAudionTypography.scaleFactor(for: .body, at: cap))
        XCTAssertEqual(QAudionTypography.standard.scaled(for: .accessibility5),
                       QAudionTypography.standard.scaled(for: cap))
    }

    /// A scaled role keeps its proportions: size, line height and tracking grow by the same factor, the weight and the
    /// family stay.
    func testAScaledRoleKeepsItsProportions() {
        let base = QAudionTypography.standard.labelLarge
        let factor = QAudionTypography.scaleFactor(for: base.family, at: .xxxLarge)
        XCTAssertGreaterThan(factor, 1)
        let scaled = base.scaled(for: .xxxLarge)
        XCTAssertEqual(scaled.size, base.size * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.lineHeight, base.lineHeight * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.tracking, base.tracking * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.lineSpacing, base.lineSpacing * factor, accuracy: 0.0001)
        XCTAssertEqual(scaled.weight, base.weight)
        XCTAssertEqual(scaled.family, base.family)
    }

    /// The helper for fixed point sizes (icons, cells of digits) uses the same curve as the roles.
    func testFixedPointSizesUseTheSameCurveAsTheRoles() {
        let factor = QAudionTypography.scaleFactor(for: .body, at: .accessibility1)
        XCTAssertEqual(QAudionTypography.scaledSize(16, family: .body, at: .accessibility1), 16 * factor, accuracy: 0.0001)
        XCTAssertEqual(QAudionTypography.scaledSize(16, family: .body, at: .accessibility5),
                       QAudionTypography.scaledSize(16, family: .body, at: QAudionTypography.maxDynamicTypeSize))
    }

    // MARK: - What the call screens print

    /// A call starts with a transitional key derived from the pairwise secret: it exists before any key exchange, so
    /// it is not the post-quantum key. The call screens present a key (its fingerprint, the algorithm name, the
    /// "post-quantum active" shield, its popup, the custody cell and verdict, the PQC chip of the video call) only
    /// once it is the ML-KEM one, and the third row of the handshake log is ticked only with that fingerprint.
    func testOnlyTheMlKemKeyIsShownAsTheKeyOfTheCall() {
        let key = Data([1, 2, 3, 4])
        XCTAssertNil(CallSessionKeyShown.realKey(key, source: .none))
        XCTAssertNil(CallSessionKeyShown.realKey(key, source: .psk), "the transitional key is shown as the ML-KEM key")
        XCTAssertEqual(CallSessionKeyShown.realKey(key, source: .mlKem), key)
        XCTAssertNil(CallSessionKeyShown.realKey(nil, source: .mlKem))
        XCTAssertNil(CallSessionKeyShown.realKey(Data(), source: .mlKem), "an empty key is not a key")
        // `isPresent` is the other question, "does the call hold any key": the transitional key counts.
        XCTAssertTrue(CallSessionKeyShown.isPresent(key), "the transitional key is a key")
        XCTAssertFalse(CallSessionKeyShown.isPresent(nil))
        XCTAssertFalse(CallSessionKeyShown.isPresent(Data()), "an empty key is not a key")

        XCTAssertFalse(OutgoingCallScreen.sessionKeyRowDone(state: .connected, hasFingerprint: false),
                       "the call is up but the key is still the transitional one")
        XCTAssertTrue(OutgoingCallScreen.sessionKeyRowDone(state: .connected, hasFingerprint: true))
        let notYetConnected: [OutgoingCallScreen.State] = [.dialing, .handshaking, .ended]
        for state in notYetConnected {
            XCTAssertFalse(OutgoingCallScreen.sessionKeyRowDone(state: state, hasFingerprint: true), "\(state)")
        }
    }

    /// The compact security badge never says "Sicuro" without a score: a call starts at level "green" with the -1 "no
    /// score yet" sentinel, and then the word says there is not enough data. With a real reading (0 included) the
    /// three words follow the level.
    func testTheSecurityBadgeSaysNothingOfSecurityWithoutAScore() {
        let noData = CallSecurityBadge.statusWord(level: "green", score: -1)
        XCTAssertFalse(noData.isEmpty)
        for word in ["Sicuro", "Attenzione", "Allarme"] {
            XCTAssertNotEqual(noData, word)
        }
        XCTAssertEqual(CallSecurityBadge.statusWord(level: "green", score: .nan), noData)
        XCTAssertEqual(CallSecurityBadge.statusWord(level: "red", score: -1), noData, "the level alone is not a reading")
        XCTAssertEqual(CallSecurityBadge.statusWord(level: "green", score: 0.9), "Sicuro")
        XCTAssertEqual(CallSecurityBadge.statusWord(level: "yellow", score: 0.4), "Attenzione")
        XCTAssertEqual(CallSecurityBadge.statusWord(level: "red", score: 0.1), "Allarme")
        XCTAssertEqual(CallSecurityBadge.statusWord(level: "red", score: 0), "Allarme", "0 is a real reading")
    }

    /// The details panel of the badge prints only what the call reports: the transport it is really on (it used to
    /// print a fixed "P2P Direct", relay included, and then "p2p" from a default before any path was reported), the
    /// ML-KEM algorithm text only with the ML-KEM key, and a dash for a signalling ping nobody measured (it used to
    /// print "0 ms", painted green).
    func testTheSecurityBadgeDetailsPrintOnlyWhatTheCallReports() {
        let dash = "\u{2014}"
        XCTAssertEqual(CallSecurityBadge.transportWord(backendType: "p2p"), "P2P")
        XCTAssertEqual(CallSecurityBadge.transportWord(backendType: "turn"), "TURN")
        XCTAssertEqual(CallSecurityBadge.transportWord(backendType: "relay"), "RELAY")
        XCTAssertEqual(CallSecurityBadge.transportWord(backendType: ""), dash, "an unknown path is not a transport")
        // The compact badge: the reported path as it is, a dash while none was reported.
        XCTAssertEqual(CallSecurityBadge.backendLabel(""), dash)
        XCTAssertEqual(CallSecurityBadge.backendLabel("turn"), "turn")

        let algo = "ML-KEM-1024 + AES-256-GCM"
        XCTAssertEqual(CallSecurityBadge.encryptionWord(algo: algo, hasMlKemKey: true), algo)
        XCTAssertEqual(CallSecurityBadge.encryptionWord(algo: algo, hasMlKemKey: false), dash,
                       "the ML-KEM text is announced before the ML-KEM key exists")

        XCTAssertEqual(CallSecurityBadge.pingWord(ms: 42), "42 ms")
        XCTAssertEqual(CallSecurityBadge.pingWord(ms: 0), dash, "0 is the unset value, not a measurement")
        XCTAssertEqual(CallSecurityBadge.pingWord(ms: -1), dash, "a negative value is no measurement either")
    }

    /// The popup of the post-quantum shield follows the shield: the shield is drawn in every state (grey when the
    /// exchange is not active), so its text must not say "active" under a grey shield. The popups of the other
    /// shields do not depend on it.
    func testThePostQuantumPopupReadsDifferentlyUnderAnActiveAndAGreyShield() {
        // The language of the phone running the test does not matter: only that the two texts differ.
        let active = InCallScreen.TrustBadgeInfo.pqc.body(pqcActive: true)
        let inactive = InCallScreen.TrustBadgeInfo.pqc.body(pqcActive: false)
        XCTAssertFalse(active.isEmpty)
        XCTAssertFalse(inactive.isEmpty)
        XCTAssertNotEqual(active, inactive, "the popup reads the same under an active and a grey shield")
        let others: [InCallScreen.TrustBadgeInfo] = [.voiceKey, .contactVoice, .nfc, .psk, .sas, .transport]
        for info in others {
            XCTAssertEqual(info.body(pqcActive: true), info.body(pqcActive: false), "\(info)")
        }
    }

    /// The "DEMO" badge follows "does the call hold any key", the transitional one included, as it always did: the
    /// key panel exists only for the real ML-KEM key, so on its own it would bring the badge back on a real call.
    /// The badge of the call screen shows only with neither a key panel nor a key.
    func testTheDemoBadgeStaysOffAsSoonAsAnyKeyExists() {
        XCTAssertTrue(InCallScreen.demoBadgeShown(keyInfoPresent: false, sessionKeyPresent: false))
        XCTAssertFalse(InCallScreen.demoBadgeShown(keyInfoPresent: false, sessionKeyPresent: true),
                       "the transitional key a real call starts with brings the DEMO badge back")
        XCTAssertFalse(InCallScreen.demoBadgeShown(keyInfoPresent: true, sessionKeyPresent: false),
                       "a screen built with only a key panel shows the badge")
        XCTAssertFalse(InCallScreen.demoBadgeShown(keyInfoPresent: true, sessionKeyPresent: true))
    }

    /// The PSK row of the security badge stands on one verified fact: a pre-shared key was mixed into this call's
    /// session key, the same fact as the PSK chip and the PSK shield of the call screen. The name and fingerprint of a
    /// key are printed only with the fact, and the row shows a dash otherwise.
    func testThePskRowPrintsAKeyOnlyWhenOneWasMixedIn() {
        let dash = "\u{2014}"
        XCTAssertEqual(CallSecurityBadge.pskWord(mixed: false, name: "Yubi5", fingerprint: "a83c-9f12"), dash,
                       "a name and a fingerprint without the fact are shown as a key in use")
        XCTAssertEqual(CallSecurityBadge.pskWord(mixed: false, name: "", fingerprint: ""), dash)
        XCTAssertEqual(CallSecurityBadge.pskWord(mixed: true, name: "Yubi5", fingerprint: "a83c-9f12"),
                       "Yubi5  \u{2022}  a83c-9f12")
        XCTAssertEqual(CallSecurityBadge.pskWord(mixed: true, name: "", fingerprint: "a83c-9f12"), "a83c-9f12")
        XCTAssertEqual(CallSecurityBadge.pskWord(mixed: true, name: "Yubi5", fingerprint: ""), "Yubi5")
        XCTAssertEqual(CallSecurityBadge.pskWord(mixed: true, name: "", fingerprint: ""), dash,
                       "a key with no known name or fingerprint prints nothing but the dash")
    }

    /// Each row of the outgoing handshake log is ticked on its own reading. "PSK matched from vault" says a key was
    /// found in the vault, so it ticks only when the method label of that key exists (and not from the call state: a
    /// call with no pre-shared key leaves it open); the first row follows the call reaching ringing, the third needs
    /// the fingerprint of the real key (see the first case of this section).
    func testTheHandshakeRowsOfTheOutgoingScreenTickOnTheirOwnReading() {
        XCTAssertFalse(OutgoingCallScreen.pskRowDone(pskMethodLabel: nil), "no key matched, row ticked")
        XCTAssertFalse(OutgoingCallScreen.pskRowDone(pskMethodLabel: ""), "an empty label is no match")
        XCTAssertTrue(OutgoingCallScreen.pskRowDone(pskMethodLabel: "NFC"))
        XCTAssertTrue(OutgoingCallScreen.pskRowDone(pskMethodLabel: "KMS"))

        let ticked: [OutgoingCallScreen.State] = [.handshaking, .connected, .rekeying]
        for state in ticked {
            XCTAssertTrue(OutgoingCallScreen.kemRowDone(state: state), "\(state)")
        }
        let open: [OutgoingCallScreen.State] = [.dialing, .ended]
        for state in open {
            XCTAssertFalse(OutgoingCallScreen.kemRowDone(state: state), "\(state)")
        }
    }

    // MARK: - Reduce Transparency

    func testReduceTransparencyPicksTheOpaqueBackdrop() {
        XCTAssertEqual(QAudionBackdrop.resolve(reduceTransparency: true), .opaque)
        XCTAssertEqual(QAudionBackdrop.resolve(reduceTransparency: false), .material)
    }
}

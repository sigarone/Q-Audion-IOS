import XCTest
#if canImport(Security)
import Security
#endif
@testable import QAudionEngine

/// W-KCAFTERUNLOCK (2026-09-01) — pins the pure decision behind the Keychain
/// accessibility class of every vault and the reading of -25308.
///
/// Regression coverage for the rule that identity / session PSKs / ratchet
/// state are written `AfterFirstUnlockThisDeviceOnly`, so a VoIP-push wake on a
/// locked phone can read them, and that a locked read (-25308) is never
/// classified as "absent". No Keychain is touched here, so this runs on the CI
/// simulator; the real-Keychain half lives in
/// `KeychainAccessibilityMigrationTests`.
final class KeychainAccessibilityPolicyTests: XCTestCase {

    private typealias Policy = KeychainAccessibilityPolicy

    // MARK: - Kill switches ship ON

    func testKillSwitchesDefaultToTheNewBehaviour() {
        XCTAssertTrue(Policy.backgroundKeyAccessEnabled, "rollback is flipping this to false")
        XCTAssertTrue(Policy.lockedReadIsTransientEnabled, "rollback is flipping this to false")
    }

    // MARK: - Class per category

    // THE BUG: the three categories a push wake reads must survive a locked phone.
    func testBackgroundCategoriesAreAfterFirstUnlockThisDeviceOnly() {
        XCTAssertEqual(Policy.accessClass(for: .sovereignIdentity), .afterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(Policy.accessClass(for: .sessionPsk), .afterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(Policy.accessClass(for: .ratchetState), .afterFirstUnlockThisDeviceOnly)
    }

    func testUiOnlyStaysWhenUnlockedThisDeviceOnly() {
        XCTAssertEqual(Policy.accessClass(for: .uiOnly), .whenUnlockedThisDeviceOnly)
    }

    /// Every category resolves to a class this policy owns — never `.other`,
    /// which has no constant to write and would make `SecItemAdd` fail.
    func testEveryCategoryResolvesToAWritableClass() {
        for category in Policy.ItemCategory.allCases {
            XCTAssertNotEqual(Policy.accessClass(for: category), .other, "\(category)")
        }
    }

    // MARK: - In-place upgrade decision

    func testLegacyItemInABackgroundCategoryIsUpgraded() {
        for category: Policy.ItemCategory in [.sovereignIdentity, .sessionPsk, .ratchetState] {
            XCTAssertEqual(
                Policy.migrationTarget(category: category, currentClass: .whenUnlockedThisDeviceOnly, requiresUserPresence: false),
                .afterFirstUnlockThisDeviceOnly, "\(category)")
        }
    }

    /// Idempotence: once on the target class there is nothing to do, so a read
    /// costs no `SecItemUpdate`.
    func testAlreadyUpgradedItemIsLeftAlone() {
        XCTAssertNil(Policy.migrationTarget(
            category: .sessionPsk, currentClass: .afterFirstUnlockThisDeviceOnly, requiresUserPresence: false))
    }

    /// Biometric key protection ON: the item carries a `.userPresence` access
    /// control, which is the user's choice and cannot be rewritten in place.
    func testUserPresenceProtectedItemIsNeverTouched() {
        XCTAssertNil(Policy.migrationTarget(
            category: .sessionPsk, currentClass: .whenUnlockedThisDeviceOnly, requiresUserPresence: true))
        XCTAssertNil(Policy.migrationTarget(
            category: .sessionPsk, currentClass: .afterFirstUnlockThisDeviceOnly, requiresUserPresence: true))
    }

    /// The non-interactive read decides: only a successful one shows the item needs no user.
    func testOnlyASuccessfulNonInteractiveReadShowsNoUserPresence() {
        XCTAssertFalse(Policy.requiresUserPresence(probeStatus: 0))
        // -25308 the system needs the user (or the phone is locked), -25293 authentication failed,
        // -128 cancelled, -25300 gone, -4 no way to read without asking: all leave the item as it is.
        for status: OSStatus in [-25308, -25293, -128, -25300, -4, -34018, -50] {
            XCTAssertTrue(Policy.requiresUserPresence(probeStatus: status), "\(status)")
        }
    }

    /// The composition the read path runs: a legacy plain item moves, a legacy item that needs the user stays.
    func testLegacyItemMovesOnlyWhenTheNonInteractiveReadSucceeded() {
        XCTAssertEqual(
            Policy.migrationTarget(
                category: .sessionPsk, currentClass: .whenUnlockedThisDeviceOnly,
                requiresUserPresence: Policy.requiresUserPresence(probeStatus: 0)),
            .afterFirstUnlockThisDeviceOnly)
        XCTAssertNil(Policy.migrationTarget(
            category: .sessionPsk, currentClass: .whenUnlockedThisDeviceOnly,
            requiresUserPresence: Policy.requiresUserPresence(probeStatus: -25308)))
    }

    func testUiOnlyNeverMigrates() {
        XCTAssertNil(Policy.migrationTarget(
            category: .uiOnly, currentClass: .whenUnlockedThisDeviceOnly, requiresUserPresence: false))
    }

    /// A class this codebase never wrote, or one the read did not report, is
    /// left untouched rather than guessed at.
    func testUnknownOrMissingCurrentClassIsLeftAlone() {
        XCTAssertNil(Policy.migrationTarget(category: .ratchetState, currentClass: .other, requiresUserPresence: false))
        XCTAssertNil(Policy.migrationTarget(category: .ratchetState, currentClass: nil, requiresUserPresence: false))
    }

    // MARK: - Read classification

    func testSuccessAndNotFoundClassifyAsBefore() {
        XCTAssertEqual(Policy.classifyRead(status: 0), .found)
        XCTAssertEqual(Policy.classifyRead(status: -25300), .absent)
    }

    // THE BUG, read side: -25308 is "locked", never "absent".
    func testInteractionNotAllowedIsDeviceLockedNotAbsent() {
        XCTAssertEqual(Policy.classifyRead(status: -25308), .deviceLocked)
        XCTAssertNotEqual(Policy.classifyRead(status: -25308), .absent)
    }

    /// -34018 (`errSecMissingEntitlement`, the simulator test-bundle case) and
    /// any other status stay generic failures — only the locked case is typed.
    func testOtherStatusesStayGenericFailures() {
        XCTAssertEqual(Policy.classifyRead(status: -34018), .failed(-34018))
        XCTAssertEqual(Policy.classifyRead(status: -50), .failed(-50))
    }

    /// Explicit statement of the invariant that broke: the two outcomes a
    /// caller might act destructively on must never collapse into one.
    func testLockedAndAbsentAndFailedNeverCollapse() {
        let locked = Policy.classifyRead(status: -25308)
        let absent = Policy.classifyRead(status: -25300)
        let failed = Policy.classifyRead(status: -34018)
        XCTAssertNotEqual(locked, absent)
        XCTAssertNotEqual(locked, failed)
        XCTAssertNotEqual(absent, failed)
    }

    // MARK: - Bridging to the Security framework

    #if canImport(Security)
    /// The literal statuses the pure part reasons about are the framework's.
    func testStatusConstantsMatchTheSecurityFramework() {
        XCTAssertEqual(Policy.deviceLockedStatus, errSecInteractionNotAllowed)
        XCTAssertEqual(Policy.itemNotFoundStatus, errSecItemNotFound)
        XCTAssertEqual(Policy.successStatus, errSecSuccess)
    }

    /// The attribute a `kSecReturnAttributes` read hands back is a CFString;
    /// both the bridged `String` and the raw constant must parse.
    func testAttributeParsingRoundTripsTheRealConstants() {
        XCTAssertEqual(
            Policy.accessClass(fromAttribute: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
            .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(
            Policy.accessClass(fromAttribute: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
            .afterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(
            Policy.accessClass(fromAttribute: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as Any),
            .whenUnlockedThisDeviceOnly)
        XCTAssertEqual(
            Policy.accessClass(fromAttribute: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as Any),
            .afterFirstUnlockThisDeviceOnly)
        // A class this codebase never wrote (not ThisDeviceOnly) is `.other`.
        XCTAssertEqual(Policy.accessClass(fromAttribute: kSecAttrAccessibleWhenUnlocked as String), .other)
        XCTAssertNil(Policy.accessClass(fromAttribute: nil))
        XCTAssertNil(Policy.accessClass(fromAttribute: 42))
    }

    /// What the write path puts in `SecItemAdd` is exactly the class decision.
    func testSecAttrForCategoriesMatchesTheClassDecision() {
        XCTAssertEqual(
            Policy.secAttrAccessible(for: .sovereignIdentity) as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(
            Policy.secAttrAccessible(for: .sessionPsk) as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(
            Policy.secAttrAccessible(for: .ratchetState) as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(
            Policy.secAttrAccessible(for: .uiOnly) as String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testMigrationTargetAlwaysHasAConstantToWrite() {
        let target = Policy.migrationTarget(
            category: .sessionPsk, currentClass: .whenUnlockedThisDeviceOnly, requiresUserPresence: false)
        XCTAssertNotNil(target)
        XCTAssertNotNil(target.flatMap { Policy.secAttrAccessible($0) })
        XCTAssertNil(Policy.secAttrAccessible(.other))
    }
    #endif
}

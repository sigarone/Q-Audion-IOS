import XCTest
@testable import QAudionApp
import QAudionEngine

/// How the security code shows on the call screen: a section of the column, never a prompt, and unconfirmed at the
/// start of every call.
final class SasCardPlacementTests: XCTestCase {

    func testTheCodeHasSixWords() {
        XCTAssertEqual(SasCardPlacement.wordCount, 6)
    }

    func testColumnKeepsOnlyASmallSpaceAtTheEnd() {
        // The dock is a safe-area inset: the column needs no fixed reserve for it.
        XCTAssertLessThan(SasCardPlacement.columnBottomSpacing, 40)
    }

    func testOnlyAnExplicitVerdictMakesTheCeremonyRedundant() {
        XCTAssertFalse(SasCardPlacement.isRedundant(sasRequired: nil))
        XCTAssertFalse(SasCardPlacement.isRedundant(sasRequired: true))
        XCTAssertTrue(SasCardPlacement.isRedundant(sasRequired: false))
    }

    func testNothingClaimsVerifiedBeforeTheVerdictArrives() {
        XCTAssertFalse(SasCardPlacement.showsVerified(sasVerified: true, verdictKnown: false))
        XCTAssertTrue(SasCardPlacement.showsVerified(sasVerified: true, verdictKnown: true))
        XCTAssertFalse(SasCardPlacement.showsVerified(sasVerified: false, verdictKnown: true))
    }

    // MARK: - A confirmation never carries over to a later call

    private let key = Data(repeating: 7, count: 32)

    private func stored(words: [String], key: Data) -> SasBinding {
        SasBinding(sasFingerprint: SasVerificationStore.fingerprint(forWords: words),
                   identityTag: SasVerificationStore.identityTag(forPinnedKey: key))
    }

    private func isVerified(_ binding: SasBinding, words: [String], key: Data) -> Bool {
        binding.matches(sasFingerprint: SasVerificationStore.fingerprint(forWords: words),
                        identityTag: SasVerificationStore.identityTag(forPinnedKey: key))
    }

    private let earlierCall = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT"]
    private let newCall = ["GOLF", "HOTEL", "INDIA", "JULIET", "KILO", "LIMA"]

    func testAStoredConfirmationForTheSameKeyDoesNotMarkANewCallVerified() {
        let binding = stored(words: earlierCall, key: key)
        // The contact is still bound to the same pinned key (shown in the contact record) ...
        XCTAssertTrue(binding.appliesTo(currentIdentityTag: SasVerificationStore.identityTag(forPinnedKey: key)))
        // ... but the new call has other words, so the call does not read as verified.
        XCTAssertFalse(isVerified(binding, words: newCall, key: key))
    }

    func testConfirmingThisCallsWordsMarksItVerified() {
        XCTAssertTrue(isVerified(stored(words: newCall, key: key), words: newCall, key: key))
    }

    func testAConfirmationOfThisCallsWordsDoesNotSurviveAKeyChange() {
        let binding = stored(words: newCall, key: key)
        XCTAssertFalse(isVerified(binding, words: newCall, key: Data(repeating: 9, count: 32)))
    }
}

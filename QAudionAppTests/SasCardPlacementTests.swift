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

    // Whether a call reads as verified is decided by the identity shield (QAudionEngine, `IdentityShieldTests`), from the key the
    // call was authenticated by and the key-bound record: never by the words of the call and never by this placement type.
}

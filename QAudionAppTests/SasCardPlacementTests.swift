import XCTest
@testable import QAudionApp
import QAudionEngine

/// Where the security-code card sits on the call screen: with the six words ready and the confirmation outstanding it
/// is pinned above the control dock (words and confirm button visible without scrolling); before that the waiting line
/// stays in the column, and after the confirmation (or when it is redundant) the card goes back into the column.
final class SasCardPlacementTests: XCTestCase {

    private func pinned(_ words: Int, verified: Bool = false, redundant: Bool = false) -> Bool {
        SasCardPlacement.isPinned(sasWordCount: words, sasVerified: verified, sasCeremonyRedundant: redundant)
    }

    private func inColumn(_ words: Int, verified: Bool = false, redundant: Bool = false) -> Bool {
        SasCardPlacement.showsCardInColumn(sasWordCount: words, sasVerified: verified, sasCeremonyRedundant: redundant)
    }

    func testSixUnconfirmedWordsPinTheCard() {
        XCTAssertTrue(pinned(6))
        XCTAssertFalse(inColumn(6))
    }

    func testConfirmedCardGoesBackToTheColumn() {
        XCTAssertFalse(pinned(6, verified: true))
        XCTAssertTrue(inColumn(6, verified: true))
    }

    func testRedundantCardGoesBackToTheColumn() {
        XCTAssertFalse(pinned(6, redundant: true))
        XCTAssertTrue(inColumn(6, redundant: true))
        XCTAssertFalse(pinned(6, verified: true, redundant: true))
    }

    func testOtherWordCountsNeverPinNorShowTheCard() {
        for count in [0, 1, 5, 7] {
            XCTAssertFalse(pinned(count), "\(count)")
            XCTAssertFalse(inColumn(count), "\(count)")
        }
    }

    func testTheCardIsInExactlyOnePlaceWhenTheWordsAreReady() {
        for verified in [false, true] {
            for redundant in [false, true] {
                XCTAssertNotEqual(pinned(6, verified: verified, redundant: redundant),
                                  inColumn(6, verified: verified, redundant: redundant))
            }
        }
    }

    func testWaitingLineStaysInTheColumnOnlyWithoutWords() {
        XCTAssertTrue(SasCardPlacement.showsWaitingLine(sasWordCount: 0, sasWaiting: true))
        XCTAssertFalse(SasCardPlacement.showsWaitingLine(sasWordCount: 0, sasWaiting: false))
        XCTAssertFalse(SasCardPlacement.showsWaitingLine(sasWordCount: 6, sasWaiting: true))
    }

    func testHoldNoticeIsPinnedOnlyWithThePinnedCard() {
        func pins(_ words: Int, verified: Bool = false, redundant: Bool = false, awaiting: Bool) -> Bool {
            SasCardPlacement.pinsHoldNotice(sasWordCount: words, sasVerified: verified,
                                            sasCeremonyRedundant: redundant, awaitingConfirmation: awaiting)
        }
        XCTAssertTrue(pins(6, awaiting: true))
        XCTAssertFalse(pins(6, awaiting: false))
        XCTAssertFalse(pins(0, awaiting: true))
        XCTAssertFalse(pins(6, verified: true, awaiting: true))
        // A call held for confirmation keeps the card and its notice pinned even when the ceremony is redundant.
        XCTAssertTrue(pins(6, redundant: true, awaiting: true))
        XCTAssertFalse(pins(6, redundant: true, awaiting: false))
    }

    func testScrollableHeightFollowsTheWindowAndIsCapped() {
        // iPhone SE, iPhone Pro Max, iPad, a short Split View window, and an unknown height.
        XCTAssertEqual(SasCardPlacement.maxScrollableHeight(windowHeight: 667), 667 * 0.45, accuracy: 0.01)
        XCTAssertEqual(SasCardPlacement.maxScrollableHeight(windowHeight: 932), SasCardPlacement.maxPinnedHeight)
        XCTAssertEqual(SasCardPlacement.maxScrollableHeight(windowHeight: 1366), SasCardPlacement.maxPinnedHeight)
        XCTAssertEqual(SasCardPlacement.maxScrollableHeight(windowHeight: 400), 180, accuracy: 0.01)
        XCTAssertEqual(SasCardPlacement.maxScrollableHeight(windowHeight: 0), SasCardPlacement.maxPinnedHeight)
        for height in stride(from: CGFloat(300), through: 1400, by: 50) {
            XCTAssertLessThanOrEqual(SasCardPlacement.maxScrollableHeight(windowHeight: height), height * 0.45 + 0.01)
        }
    }

    func testPinnedAreaUsesTheDockInset() {
        XCTAssertEqual(SasCardPlacement.horizontalInset, 32)
    }

    func testColumnKeepsOnlyASmallSpaceAtTheEnd() {
        // The old fixed 170 pt reserve for the dock is gone: the dock is a safe-area inset now.
        XCTAssertLessThan(SasCardPlacement.columnBottomSpacing, 40)
    }

    func testRedundantCardStaysPinnedWhileTheCallIsHeldForConfirmation() {
        XCTAssertTrue(SasCardPlacement.isPinned(sasWordCount: 6, sasVerified: false, sasCeremonyRedundant: true,
                                                awaitingConfirmation: true))
        XCTAssertFalse(SasCardPlacement.showsCardInColumn(sasWordCount: 6, sasVerified: false, sasCeremonyRedundant: true,
                                                          awaitingConfirmation: true))
        XCTAssertFalse(SasCardPlacement.isPinned(sasWordCount: 6, sasVerified: false, sasCeremonyRedundant: true,
                                                 awaitingConfirmation: false))
        XCTAssertFalse(SasCardPlacement.isPinned(sasWordCount: 6, sasVerified: true, sasCeremonyRedundant: true,
                                                 awaitingConfirmation: true))
    }

    // MARK: - Which assurance states keep the card pinned

    private func pinnedFor(_ state: AssuranceState, awaiting: Bool = false) -> Bool {
        let presentation = AssuranceStateUI.present(state: state)
        return SasCardPlacement.isPinned(
            sasWordCount: 6, sasVerified: false,
            sasCeremonyRedundant: SasCardPlacement.isRedundant(sasRequired: presentation.sasRequired),
            awaitingConfirmation: awaiting)
    }

    func testConfirmedPreSharedKeyDoesNotPinTheCard() {
        XCTAssertFalse(pinnedFor(.pskConfirmed))
        XCTAssertFalse(pinnedFor(.nfcAuthenticated))
    }

    func testStatesThatNeedTheCodeKeepItPinned() {
        for state in [AssuranceState.pqcOnly, .identityUnverified, .kcFailed, .pskUnconfirmed, .peerLegacy] {
            XCTAssertTrue(pinnedFor(state), "\(state)")
        }
    }

    func testHeldCallKeepsTheCardPinnedInEveryState() {
        XCTAssertTrue(pinnedFor(.pskConfirmed, awaiting: true))
        XCTAssertTrue(pinnedFor(.nfcAuthenticated, awaiting: true))
        XCTAssertTrue(pinnedFor(.pqcOnly, awaiting: true))
    }

    func testStateNotComputedYetKeepsTheCardPinned() {
        XCTAssertFalse(SasCardPlacement.isRedundant(sasRequired: nil))
        XCTAssertTrue(SasCardPlacement.isRedundant(sasRequired: false))
        XCTAssertFalse(SasCardPlacement.isRedundant(sasRequired: true))
        XCTAssertTrue(pinned(6, redundant: SasCardPlacement.isRedundant(sasRequired: nil)))
    }
}

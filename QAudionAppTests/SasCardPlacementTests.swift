import XCTest
@testable import QAudionApp
import QAudionEngine

/// When the security-code card shows on the call screen: only when a comparison is really needed, pinned above the
/// control dock. Never as a routine element at answer (unknown or redundant assurance state), never once confirmed.
final class SasCardPlacementTests: XCTestCase {

    private func needed(_ required: Bool?, awaiting: Bool = false, notice: Bool = false) -> Bool {
        SasCardPlacement.isVerificationNeeded(sasRequired: required, awaitingConfirmation: awaiting, identityNotice: notice)
    }

    private func pinned(_ words: Int, verified: Bool = false, needed: Bool) -> Bool {
        SasCardPlacement.isPinned(sasWordCount: words, sasVerified: verified, verificationNeeded: needed)
    }

    func testAnUnknownAssuranceStateDoesNotNeedTheCode() {
        XCTAssertFalse(needed(nil))
        XCTAssertFalse(pinned(6, needed: needed(nil)))
    }

    func testARedundantCeremonyDoesNotNeedTheCode() {
        XCTAssertFalse(needed(false))
        XCTAssertFalse(pinned(6, needed: needed(false)))
    }

    func testARequiredCeremonyPinsTheCardUntilConfirmed() {
        XCTAssertTrue(needed(true))
        XCTAssertTrue(pinned(6, needed: needed(true)))
        XCTAssertFalse(pinned(6, verified: true, needed: needed(true)))
    }

    func testAHeldCallAndIdentityNoticesAlwaysNeedTheCode() {
        for required in [nil, false, true] as [Bool?] {
            XCTAssertTrue(needed(required, awaiting: true))
            XCTAssertTrue(needed(required, notice: true))
        }
        XCTAssertTrue(pinned(6, needed: needed(false, awaiting: true)))
        XCTAssertTrue(pinned(6, needed: needed(nil, notice: true)))
    }

    func testOtherWordCountsNeverPinTheCard() {
        for count in [0, 1, 5, 7] {
            XCTAssertFalse(pinned(count, needed: true), "\(count)")
        }
    }

    func testWaitingLineShowsOnlyWithoutWordsAndWhenNeeded() {
        func waiting(_ words: Int, _ waiting: Bool, _ needed: Bool) -> Bool {
            SasCardPlacement.showsWaitingLine(sasWordCount: words, sasWaiting: waiting, verificationNeeded: needed)
        }
        XCTAssertTrue(waiting(0, true, true))
        XCTAssertFalse(waiting(0, true, false))
        XCTAssertFalse(waiting(0, false, true))
        XCTAssertFalse(waiting(6, true, true))
    }

    func testHoldNoticeIsPinnedOnlyWithThePinnedCard() {
        func pins(_ words: Int, verified: Bool = false, needed: Bool = true, awaiting: Bool) -> Bool {
            SasCardPlacement.pinsHoldNotice(sasWordCount: words, sasVerified: verified,
                                            verificationNeeded: needed, awaitingConfirmation: awaiting)
        }
        XCTAssertTrue(pins(6, awaiting: true))
        XCTAssertFalse(pins(6, awaiting: false))
        XCTAssertFalse(pins(0, awaiting: true))
        XCTAssertFalse(pins(6, verified: true, awaiting: true))
        XCTAssertFalse(pins(6, needed: false, awaiting: true))
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

    // MARK: - Which assurance states keep the card pinned

    private func pinnedFor(_ state: AssuranceState, awaiting: Bool = false) -> Bool {
        let presentation = AssuranceStateUI.present(state: state)
        return pinned(6, needed: needed(presentation.sasRequired, awaiting: awaiting))
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

    // MARK: - Every assurance state, one verdict

    private static let everyState: [AssuranceState] = [
        .peerLegacy, .kcFailed, .nfcAuthenticated, .nfcIdentityMismatch, .nfcUnattestable, .identityUnverified,
        .nfcPresentUnconfirmed, .expectedNfcStripped, .pskConfirmed, .pskUnconfirmed, .pqcOnly,
    ]

    /// Fails to compile when a state is added to `AssuranceState` and not to `everyState`.
    private func isListed(_ state: AssuranceState) -> Bool {
        switch state {
        case .peerLegacy, .kcFailed, .nfcAuthenticated, .nfcIdentityMismatch, .nfcUnattestable, .identityUnverified,
             .nfcPresentUnconfirmed, .expectedNfcStripped, .pskConfirmed, .pskUnconfirmed, .pqcOnly:
            return Self.everyState.contains(state)
        }
    }

    func testEveryStateIsListed() {
        XCTAssertTrue(Self.everyState.allSatisfy(isListed))
        XCTAssertEqual(Set(Self.everyState.map { "\($0)" }).count, Self.everyState.count)
    }

    func testVerificationNeededMatchesSasRequiredForEveryState() {
        for state in Self.everyState {
            let required = AssuranceStateUI.present(state: state).sasRequired
            XCTAssertEqual(needed(required), required, "\(state)")
            XCTAssertEqual(pinned(6, needed: needed(required)), required, "\(state)")
        }
    }

    func testHeldCallAndIdentityNoticeNeedTheCardInEveryState() {
        for state in Self.everyState {
            let required = AssuranceStateUI.present(state: state).sasRequired
            XCTAssertTrue(needed(required, awaiting: true), "\(state)")
            XCTAssertTrue(needed(required, notice: true), "\(state)")
        }
        XCTAssertFalse(needed(nil))
    }

    func testNothingClaimsVerifiedBeforeTheVerdictArrives() {
        XCTAssertFalse(SasCardPlacement.showsVerified(sasVerified: true, verdictKnown: false))
        XCTAssertTrue(SasCardPlacement.showsVerified(sasVerified: true, verdictKnown: true))
        XCTAssertFalse(SasCardPlacement.showsVerified(sasVerified: false, verdictKnown: true))
    }
}

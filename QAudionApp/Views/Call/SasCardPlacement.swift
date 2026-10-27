import CoreGraphics

/// Where the security-code card sits on the call screen.
///
/// While the six words are ready and the confirmation is still outstanding, the card (and the hold notice that goes with
/// it) is drawn above the control dock, outside the scrolling column, so the words and the confirm button are on screen
/// at once and never under the dock. Before the words arrive there is nothing to confirm and the waiting line stays in
/// the column; once the code is confirmed (or is redundant because the contact was authenticated in person) the card
/// goes back into the column and no longer takes room from the call.
enum SasCardPlacement {

    /// The number of words in a security code.
    static let wordCount = 6

    /// Absolute ceiling for the scrollable part of the pinned area.
    static let maxPinnedHeight: CGFloat = 320

    /// Share of the window height the scrollable part of the pinned area may use.
    static let maxPinnedHeightFraction: CGFloat = 0.45

    /// Horizontal inset of the pinned area, equal to the dock's (16 outer + 16 inner padding).
    static let horizontalInset: CGFloat = 32

    /// Room kept at the end of the scrolling column. The dock and the pinned card are laid out by the safe area, so only
    /// a small breathing space is needed.
    static let columnBottomSpacing: CGFloat = 16

    /// True when the card is pinned above the dock: the words are ready and the code is not yet confirmed. Confirmed
    /// cards live in the scrolling column; a redundant card does too, unless the call is held waiting for the
    /// confirmation, in which case the confirm action must stay in view.
    static func isPinned(sasWordCount: Int, sasVerified: Bool, sasCeremonyRedundant: Bool,
                         awaitingConfirmation: Bool = false) -> Bool {
        sasWordCount == wordCount && !sasVerified && (!sasCeremonyRedundant || awaitingConfirmation)
    }

    /// True when the card is drawn in the scrolling column (words ready but not pinned).
    static func showsCardInColumn(sasWordCount: Int, sasVerified: Bool, sasCeremonyRedundant: Bool,
                                  awaitingConfirmation: Bool = false) -> Bool {
        sasWordCount == wordCount
            && !isPinned(sasWordCount: sasWordCount, sasVerified: sasVerified, sasCeremonyRedundant: sasCeremonyRedundant,
                         awaitingConfirmation: awaitingConfirmation)
    }

    /// True when the waiting line (no words yet) stays in the scrolling column.
    static func showsWaitingLine(sasWordCount: Int, sasWaiting: Bool) -> Bool {
        sasWordCount != wordCount && sasWaiting
    }

    /// True when the hold notice is drawn with the pinned card; otherwise it stays in the column.
    static func pinsHoldNotice(sasWordCount: Int, sasVerified: Bool, sasCeremonyRedundant: Bool,
                               awaitingConfirmation: Bool) -> Bool {
        awaitingConfirmation
            && isPinned(sasWordCount: sasWordCount, sasVerified: sasVerified, sasCeremonyRedundant: sasCeremonyRedundant,
                        awaitingConfirmation: awaitingConfirmation)
    }

    /// The height limit of the scrollable part of the pinned area (notice, header, words) for a window of the given
    /// height. The confirm button sits outside it and is always visible.
    static func maxScrollableHeight(windowHeight: CGFloat) -> CGFloat {
        guard windowHeight > 0 else { return maxPinnedHeight }
        return min(windowHeight * maxPinnedHeightFraction, maxPinnedHeight)
    }
}

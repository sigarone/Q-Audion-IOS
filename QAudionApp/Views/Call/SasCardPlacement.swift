import CoreGraphics

/// When and where the security-code card shows on the call screen.
///
/// The card is not part of a routine call. It appears only when a comparison is really needed: the call is held waiting
/// for the confirmation, the identity check raised a notice, or the call's assurance state says the code is required and
/// the contact's code was not confirmed before. While the assurance state is not known yet, and when it says the code
/// is redundant, nothing is drawn (no flash at answer). The code stays reachable on demand from the security sheet.
/// When it is needed, the card (and the hold notice that goes with it) is drawn above the control dock, outside the
/// scrolling column, so the words and the confirm button are on screen at once and never under the dock.
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

    /// True when the call's assurance state says the code comparison is not needed (an in-person authenticated or a
    /// confirmed pre-shared-key contact). While the state is not computed yet (`nil`) the code stays required.
    static func isRedundant(sasRequired: Bool?) -> Bool {
        sasRequired == false
    }

    /// True when a comparison is really needed. `sasRequired` is the assurance state's verdict (`nil` while it is not
    /// computed yet, which is not a reason to show the card). A call held for the confirmation, or one with an identity
    /// notice, always needs it.
    static func isVerificationNeeded(sasRequired: Bool?, awaitingConfirmation: Bool, identityNotice: Bool) -> Bool {
        awaitingConfirmation || identityNotice || sasRequired == true
    }

    /// True when the card is pinned above the dock: the words are ready, the code is not confirmed and a comparison is
    /// needed. In every other case the card is not drawn on the call screen.
    static func isPinned(sasWordCount: Int, sasVerified: Bool, verificationNeeded: Bool) -> Bool {
        sasWordCount == wordCount && !sasVerified && verificationNeeded
    }

    /// True when the waiting line (no words yet) shows in the scrolling column: only when a comparison is needed.
    static func showsWaitingLine(sasWordCount: Int, sasWaiting: Bool, verificationNeeded: Bool) -> Bool {
        sasWordCount != wordCount && sasWaiting && verificationNeeded
    }

    /// True when the hold notice is drawn with the pinned card; otherwise it stays in the column.
    static func pinsHoldNotice(sasWordCount: Int, sasVerified: Bool, verificationNeeded: Bool,
                               awaitingConfirmation: Bool) -> Bool {
        awaitingConfirmation
            && isPinned(sasWordCount: sasWordCount, sasVerified: sasVerified, verificationNeeded: verificationNeeded)
    }

    /// The height limit of the scrollable part of the pinned area (notice, header, words) for a window of the given
    /// height. The confirm button sits outside it and is always visible.
    static func maxScrollableHeight(windowHeight: CGFloat) -> CGFloat {
        guard windowHeight > 0 else { return maxPinnedHeight }
        return min(windowHeight * maxPinnedHeightFraction, maxPinnedHeight)
    }
}

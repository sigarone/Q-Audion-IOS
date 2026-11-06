import CoreGraphics

/// How the security code shows on the call screen.
///
/// The code is a section of the scrolling column, like the other sections of the call: the words and the confirm
/// button are always there once the code exists (a waiting line stands in until then), whatever the assurance state.
/// Nothing pops up at answer and nothing demands an action. The code starts every call unconfirmed: only a
/// confirmation of this call's own words marks it confirmed.
enum SasCardPlacement {

    /// The number of words in a security code.
    static let wordCount = 6

    /// Room kept at the end of the scrolling column. The dock is laid out by the safe area, so only a small breathing
    /// space is needed.
    static let columnBottomSpacing: CGFloat = 16

    /// True when the call's assurance state says the code comparison is not needed (an in-person authenticated or a
    /// confirmed pre-shared-key contact). The section stays complete and usable; only its weight is reduced. While
    /// the state is not computed yet (`nil`) the code is not redundant.
    static func isRedundant(sasRequired: Bool?) -> Bool {
        sasRequired == false
    }

    /// True when the screen may say the code is confirmed: this call's words were confirmed AND this call's assurance
    /// verdict has arrived. While the verdict is still `nil` nothing on the call screen claims a verification.
    static func showsVerified(sasVerified: Bool, verdictKnown: Bool) -> Bool {
        sasVerified && verdictKnown
    }
}

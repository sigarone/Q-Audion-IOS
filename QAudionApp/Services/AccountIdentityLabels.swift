import Foundation

/// The one place that decides how the logged-in account is written on a
/// "this is you" surface.
///
/// Three screens need the same two lines — the Chats-tab header, the iPad
/// sidebar header and the Settings hero card — and before this existed each
/// derived them independently, which is how they came to disagree: the
/// sidebar printed the extension as the primary line with the brand under
/// it, while the hero printed the extension as the name and a truncated
/// userId as the handle. Computing it once means a change to the fallback
/// chain lands on every surface at the same time.
///
/// The chain, matching shipped Android: display name → `#<extension>` →
/// phone → a prompt to complete the profile. Whatever gets promoted to the
/// primary line is never repeated on the secondary line. Nothing derived
/// from the userId appears at any position — not the whole UUID, not a
/// truncated one.
enum AccountIdentityLabels {
    struct Labels {
        /// The large line: name if there is one, otherwise the best
        /// identifier available.
        let primary: String
        /// The small monospace line: whichever of `#<ext>` / phone was not
        /// promoted, joined by " · ". Empty when there is nothing left to
        /// say, in which case the caller draws no second line at all.
        let secondary: String
        /// The display name alone, nil when unset. Feed this (with a "Q"
        /// fallback) to `QAudionAvatar(displayName:)` rather than `primary`:
        /// the avatar derives its initials from what it is handed, so
        /// `primary` would draw a "P" for "Profilo da completare".
        let nameLabel: String?
    }

    // CLAUDE.md sec 16 — never take `AppState` as a direct parameter type:
    // Swift 6's Sendable inference over AppState's ~17000-line surface can
    // silently break "Build IPA" with no actionable diagnostic. Two
    // primitive values in, no AppState reference in the signature at all.
    @MainActor
    static func make(currentUserDialExtension: String?, accountAvatarName: String?) -> Labels {
        var extLabel: String? = {
            guard let raw = currentUserDialExtension, !raw.isEmpty else { return nil }
            let formatted = DisplayName.formatExtension(raw)
            return formatted.isEmpty ? nil : "#" + formatted
        }()
        let phoneLabel = AppState.locallyConfiguredPhone()
        let nameLabel = accountAvatarName

        // W-CALLERIDSELF — matching Android parity fix. The caller-id
        // picker (AccountSettingsScreen "CALLER-ID" section) has only two
        // rows: "la mia estensione" (clears LocalCallerIdSettings back to
        // nil) or a specific phone number (stores it). Unlike Android's
        // three-way `localPublicPhone` ("" / extension digits / phone are
        // three DISTINCT stored strings), iOS collapses "never touched
        // this picker" and "explicitly chose the extension row" into the
        // same nil value — there is no way to tell them apart from
        // UserDefaults alone. So we only suppress the extension when the
        // user has explicitly stored a phone as their caller-id; nil keeps
        // showing both, exactly like before this fix, for every account
        // that has never opened the picker.
        if LocalCallerIdSettings.phoneNumber() != nil {
            extLabel = nil
        }

        let primary = nameLabel ?? extLabel ?? phoneLabel ?? "Profilo da completare"
        let secondary = [extLabel, phoneLabel]
            .compactMap { $0 }
            .filter { $0 != primary }
            .joined(separator: " · ")
        return Labels(primary: primary, secondary: secondary, nameLabel: nameLabel)
    }
}

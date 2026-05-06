import SwiftUI

/// View modifier that injects the Q-Audion design-system environment
/// values (color scheme + extras + typography) into a view subtree.
/// Mirrors the Kotlin `QAudionTheme(darkTheme:)` composable.
///
/// Usage:
/// ```swift
/// SomeView()
///     .qAudionTheme(dark: true)
/// ```
///
/// Once applied, descendants can read tokens via:
/// ```swift
/// @Environment(\.qaudionScheme) var scheme
/// @Environment(\.qaudionExtras) var extras
/// @Environment(\.qaudionType) var type
/// ```
public struct QAudionThemeModifier: ViewModifier {
    public let dark: Bool

    public init(dark: Bool = true) {
        self.dark = dark
    }

    public func body(content: Content) -> some View {
        content
            .environment(\.qaudionScheme, dark ? .dark : .light)
            .environment(\.qaudionExtras, dark ? .dark : .light)
            .environment(\.qaudionType, .standard)
            .preferredColorScheme(dark ? .dark : .light)
    }
}

public extension View {
    /// Apply the Q-Audion design system. Default is dark scheme to match
    /// the Android app's preferred mode (the brand spec is dark-first).
    func qAudionTheme(dark: Bool = true) -> some View {
        modifier(QAudionThemeModifier(dark: dark))
    }
}

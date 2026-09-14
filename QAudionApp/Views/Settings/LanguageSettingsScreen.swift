import SwiftUI

/// "Lingua" settings sub-screen — lets the user pick an app-language
/// override without touching iOS's own per-app-language picker. Mirrors
/// the plain section+row shape of `AboutSettingsScreen`/
/// `NotificationsSettingsScreen`; no `SettingsRow` here since every row
/// IS the terminal action (a checkmark replaces the usual chevron), not
/// a `NavigationLink` destination.
///
/// No `AppState` dependency — `AppLanguageManager` is the only source of
/// truth, per CLAUDE.md §16.
struct LanguageSettingsScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    @State private var overrideCode: String? = AppLanguageManager.currentOverride

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader("LINGUA")
                    VStack(spacing: 8) {
                        systemRow(selected: overrideCode == nil) {
                            select(nil)
                        }
                        ForEach(AppLanguageManager.supportedLanguages, id: \.code) { language in
                            languageRow(nativeName: language.nativeName,
                                        selected: overrideCode == language.code) {
                                select(language.code)
                            }
                        }
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle("Lingua")
    }

    private func select(_ code: String?) {
        overrideCode = code
        AppLanguageManager.setOverride(code)
    }

    /// "Follow system" row — a real `Text` literal so it auto-localizes
    /// once the String Catalog is populated (see the caller's caveat).
    private func systemRow(selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text("Segui lingua di sistema")
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(scheme.primary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Native language names are proper nouns — `Text(String)`, never
    /// `LocalizedStringKey`, so they never get run through translation.
    private func languageRow(nativeName: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(nativeName)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(scheme.primary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(scheme.surfaceVariant.opacity(0.4))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        LanguageSettingsScreen()
    }
    .qAudionTheme(dark: true)
}

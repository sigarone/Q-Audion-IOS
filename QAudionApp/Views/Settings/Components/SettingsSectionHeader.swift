import SwiftUI

/// Section header used inside the new `SettingsScreen` root and any
/// page that mimics it (ProfileScreen, KeyManagementScreen, etc.).
/// 1:1 port of Android `SettingsSectionHeader` from
/// `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// Visual:
///   - uppercase text, monospace `labelSmall`, 1.5sp tracking
///   - color = `scheme.primary`
///   - 16pt leading padding, 20pt top, 6pt bottom
struct SettingsSectionHeader: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .qaudionStyle(type.labelSmall)
            .tracking(1.5)
            .foregroundStyle(scheme.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 0) {
        SettingsSectionHeader("ACCOUNT")
        SettingsSectionHeader("SICUREZZA")
        SettingsSectionHeader("PRIVACY")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(Color.black)
    .qAudionTheme(dark: true)
}

import SwiftUI

/// Toggle row used inside `SettingsScreen` and any sub-screen that
/// adopts the design tokens. 1:1 port of Android `SettingsToggleRow`
/// from `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// Same shell as `SettingsRow` but the trailing element is a SwiftUI
/// `Toggle`, tinted to `scheme.primary`. The leading icon is fixed to
/// the shield (Android source hard-codes Material `Shield`); we mirror
/// it with `shield.fill`.
struct SettingsToggleRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.fill")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .qaudionStyle(type.bodyMedium)
                    .foregroundStyle(scheme.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(scheme.primary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
    }
}

private struct ToggleRowPreview: View {
    @State var deepfake = true
    @State var rekey = true
    @State var padding = false

    var body: some View {
        VStack(spacing: 8) {
            SettingsToggleRow(title: "Deepfake Guard",
                              subtitle: "Rifiuta automaticamente voci sintetizzate",
                              isOn: $deepfake)
            SettingsToggleRow(title: "Re-keying adattivo",
                              subtitle: "Rinnova chiavi al variare della confidence",
                              isOn: $rekey)
            SettingsToggleRow(title: "Adaptive Padding CBR",
                              subtitle: "Maschera i pattern di traffico",
                              isOn: $padding)
        }
        .padding()
        .background(Color.black)
        .qAudionTheme(dark: true)
    }
}

#Preview { ToggleRowPreview() }

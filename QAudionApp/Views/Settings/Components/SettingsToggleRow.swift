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
                // W-TOGGLEROW-TAP: the row below carries its own
                // .onTapGesture so the WHOLE row is a single hit target,
                // not just this small control. A native Toggle has its
                // own tap/drag recognizer that does not reliably cede to
                // an ancestor .onTapGesture (unlike Button, which does) —
                // without this, tapping exactly on the switch thumb could
                // fire both the Toggle's own flip AND the row's, toggling
                // isOn twice (a no-op flicker). Disabling hit-testing here
                // makes the row's tap the single source of truth; the
                // Toggle still renders its live isOn state correctly, it
                // just never receives touches directly.
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isOn.toggle()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "Attivo" : "Disattivo")
    }
}

// 2026-08-10 settings cleanup: this preview used to showcase "Deepfake Guard",
// "Re-keying adattivo" and "Adaptive Padding CBR". None of the three is (or may
// become) a user control: the first two are the Android toggles found to be
// inert, and constant-size CBR padding is the traffic-analysis property the
// design proves — it must never be user-disableable, not even in appearance.
// The sample rows now mirror controls that really exist on iOS, so nobody
// copy-pastes a promise the app cannot keep.
private struct ToggleRowPreview: View {
    @State var readReceipts = true
    @State var screenshotProtection = true
    @State var appLock = false

    var body: some View {
        VStack(spacing: 8) {
            SettingsToggleRow(title: "Conferme di lettura",
                              subtitle: "Notifica al mittente quando hai letto",
                              isOn: $readReceipts)
            SettingsToggleRow(title: "Protezione screenshot",
                              subtitle: "Oscura il contenuto nell'anteprima app",
                              isOn: $screenshotProtection)
            SettingsToggleRow(title: "Blocco app",
                              subtitle: "Richiede Face ID / Touch ID al rientro",
                              isOn: $appLock)
        }
        .padding()
        .background(Color.black)
        .qAudionTheme(dark: true)
    }
}

#Preview { ToggleRowPreview() }

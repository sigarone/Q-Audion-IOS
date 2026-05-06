import SwiftUI

/// Horizontal strip of security status chips rendered just below the
/// `ProfileHeroCard` on the Settings root. 1:1 port of Android
/// `SecurityChips` from
/// `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// Default chips (matches Android root):
///   - "PSK"        — `extras.success`
///   - "PQC"        — `extras.pqcAccent`
///   - "VOICE"      — `extras.success`
///   - "OTA"        — `extras.trustEnterprise`
///
/// Each chip is a capsule, monospace `labelSmall`, 1.0sp tracking,
/// 1pt border at `accent @ 0.45α`, padding 8pt h / 2pt v. Pass
/// `chips: nil` to use the canonical 4-chip default; supply a custom
/// list to override.
struct SecurityChipsRow: View {
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    struct Chip: Equatable {
        let label: String
        let accent: Color
    }

    let chips: [Chip]?

    init(chips: [Chip]? = nil) {
        self.chips = chips
    }

    var body: some View {
        let resolved = chips ?? defaultChips()
        HStack(spacing: 6) {
            ForEach(0..<resolved.count, id: \.self) { i in
                let c = resolved[i]
                Text(c.label)
                    .qaudionStyle(type.labelSmall)
                    .tracking(1.0)
                    .foregroundStyle(c.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(c.accent.opacity(0.45), lineWidth: 1)
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func defaultChips() -> [Chip] {
        [
            .init(label: "PSK",   accent: extras.success),
            .init(label: "PQC",   accent: extras.pqcAccent),
            .init(label: "VOICE", accent: extras.success),
            .init(label: "OTA",   accent: extras.trustEnterprise)
        ]
    }
}

#Preview {
    VStack(alignment: .leading) {
        SecurityChipsRow()
        Spacer()
    }
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity)
    .background(Color.black)
    .qAudionTheme(dark: true)
}

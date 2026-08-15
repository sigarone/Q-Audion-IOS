import SwiftUI

/// Horizontal strip of security status chips rendered just below the
/// `ProfileHeroCard` on the Settings root. 1:1 port of Android
/// `SecurityChips` from
/// `qaudion-android-new/feature/feature-settings/.../SettingsUi.kt`.
///
/// Default chips (matches Android root):
///   - "PSK HW-BOUND"  — `extras.success`
///   - "VOICE n/n"     — `extras.success`
///   - "OTA <version>" — `extras.trustEnterprise`
///
/// The PQC chip that used to sit second is gone: post-quantum key agreement
/// is on for every account, so a badge announcing it distinguished no user
/// from any other. The three that remain each say something with a value in
/// it, which is the difference between a status chip and decoration.
///
/// Each chip is a capsule, monospace `labelSmall`, 1.0sp tracking,
/// 1pt border at `accent @ 0.45α`, padding 8pt h / 2pt v. Pass
/// `chips: nil` to use the canonical default; supply a custom
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
        // Horizontally scrollable because the OTA chip now carries a version
        // string instead of three letters, and a fixed HStack would push the
        // last capsule off a narrow phone — where a pill's rounded clip turns
        // "OTA" into something unreadable rather than simply truncating.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<resolved.count, id: \.self) { i in
                    let c = resolved[i]
                    Text(c.label)
                        .qaudionStyle(type.labelSmall)
                        .tracking(1.0)
                        .foregroundStyle(c.accent)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule().stroke(c.accent.opacity(0.45), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }

    private func defaultChips() -> [Chip] {
        [
            .init(label: "PSK HW-BOUND", accent: extras.success),
            .init(label: "VOICE 5/5",    accent: extras.success),
            .init(label: "OTA \(Self.buildString)", accent: extras.trustEnterprise)
        ]
    }

    /// The running bundle's marketing version — the one value on this strip
    /// that genuinely differs between two installs.
    static var buildString: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
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

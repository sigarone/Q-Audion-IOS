import SwiftUI
import QAudionEngine

/// Horizontal strip of security status chips rendered just below the
/// `ProfileHeroCard` on the Settings root. 1:1 port of the Android
/// `SecurityChips` component.
///
/// Default chips:
///   - "VOICE <state>" — the owner voice-key state, from the same source as the Voice-as-Key row below
///     (`OwnerVoiceLearner.Status`): grey before anything is learned, purple while it learns, green once it is on
///   - "OTA <version>" — `extras.trustEnterprise`
///
/// Two chips that used to sit here said nothing about the account. "PSK HW-BOUND" was a fixed claim with no source, and
/// "VOICE 5/5" was a fixed text drawn green for everyone, whatever the state of the learning. The PQC chip is gone for the
/// same reason: post-quantum key agreement is on for every account. What remains says something with a value in it, which
/// is the difference between a status chip and decoration.
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
    /// The state of the owner's voice key; nil while it is still being read (no voice chip is drawn until it is known).
    let voiceKeyStatus: OwnerVoiceLearner.Status?

    init(chips: [Chip]? = nil, voiceKeyStatus: OwnerVoiceLearner.Status? = nil) {
        self.chips = chips
        self.voiceKeyStatus = voiceKeyStatus
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
        var chips: [Chip] = []
        if let voice = voiceChip(for: voiceKeyStatus) { chips.append(voice) }
        chips.append(.init(label: "OTA \(Self.buildString)", accent: extras.trustEnterprise))
        return chips
    }

    /// The voice-key chip for the state the Voice-as-Key row shows. Green only once the voice key is on.
    func voiceChip(for status: OwnerVoiceLearner.Status?) -> Chip? {
        guard let status else { return nil }
        switch status {
        case .notStarted:
            return .init(label: "VOICE 0%", accent: extras.neutral)
        case .learning(let percent, _, _):
            return .init(label: "VOICE \(percent)%", accent: extras.toVerify)
        case .active, .refined:
            return .init(label: "VOICE ON", accent: extras.success)
        }
    }

    /// The running bundle's marketing version — the one value on this strip
    /// that genuinely differs between two installs.
    static var buildString: String {
        AppVersionInfo.marketing()
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

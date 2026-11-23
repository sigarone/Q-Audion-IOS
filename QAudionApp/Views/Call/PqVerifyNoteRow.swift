import SwiftUI

/// A neutral grey note of the call screen: the post-quantum check of this call's handshake signature did not complete within the
/// late-check window. Never a warning (no red or amber, no warning icon), and it asks for nothing: no code to compare, no button.
struct PqVerifyNoteRow: View {
    /// Drawn on the video call surface (white on the picture) instead of the call screen's own colour tokens.
    var onVideo: Bool = false

    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    /// With the note up and the identity already verified there is nothing to confirm: the call screen draws no confirm button.
    static func hidesSasConfirm(noteShown: Bool, identityVerified: Bool) -> Bool {
        noteShown && identityVerified
    }

    static var text: String {
        String(localized: "in_call.pq_verify_note",
               defaultValue: "Verifica post-quantistica non completata in questa chiamata.",
               comment: "Call screen, neutral grey note: the check of the second (post-quantum) signature of the handshake did not complete during this call. Not a warning.")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .qaudionScaledFont(size: 13, weight: .regular, maxSize: .xLarge)
                .foregroundStyle(tint)
            Group {
                if onVideo {
                    Text(Self.text).font(.system(size: 12))
                } else {
                    Text(Self.text).qaudionStyle(type.labelMedium)
                }
            }
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(Self.text))
    }

    private var tint: Color {
        onVideo ? Color.white.opacity(0.75) : scheme.onSurfaceVariant
    }
}

import SwiftUI

/// W309: shared tap-to-copy row component. Extracted from the
/// per-file helpers in W297 (AboutSettingsScreen) + W307
/// (AccountSettingsScreen) + W308 (BackupSettingsScreen).
///
/// Visual: identical to a stock `kvRow` (label on left, value on
/// right, monospace caption font for the value, surfaceVariant
/// rounded background) plus a trailing `doc.on.clipboard` icon at
/// reduced opacity to telegraph the gesture.
///
/// Interaction: tap anywhere on the row → `UIPasteboard.general.string =
/// value` + `HapticFeedback.messageSent()` for tactile confirmation.
///
/// Reads scheme + type from the surrounding `qaudionScheme` /
/// `qaudionType` environment so it inherits the dark/light theme
/// + typography automatically — no per-call-site styling needed.
public struct TapCopyRow: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType)   private var type

    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurface)
            Spacer()
            Text(value)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(scheme.onSurfaceVariant.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(scheme.surfaceVariant.opacity(0.4))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: copyToPasteboard)
    }

    /// W309: extracted to a method to keep the .onTapGesture closure
    /// body trivial — see CLAUDE.md §13. UIPasteboard + Haptic both
    /// happen here.
    private func copyToPasteboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        HapticFeedback.messageSent()
        #endif
    }
}

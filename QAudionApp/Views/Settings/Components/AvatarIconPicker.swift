import SwiftUI

/// W-AVATARCHARALIGN (2026-08-13) — full replacement, not a re-skin.
///
/// This used to offer 24 curated SF Symbols (a dog, a cat, a flame, a
/// key…) stored as a separate `sficon://<name>` pseudo-URL avatar "kind"
/// that every other avatar-rendering call site had to special-case.
/// Reported live: the set didn't match Android at all and read as
/// arbitrary. Android's actual equivalent — "Scegli un personaggio" in
/// `ProfileScreen.kt`'s `MCP_LOCAL_ICONS` grid — is 8 illustrated
/// character avatars, and critically is architecturally simpler: picking
/// one just renders it to PNG bytes and uploads it through the SAME path
/// as a real photo. No separate "icon" avatar kind exists on Android at
/// all.
///
/// This port matches BOTH the visual set (the identical PNGs, copied into
/// this catalog) and the mechanism (`onSelect` now hands back a `UIImage`
/// for the caller to pass straight into `uploadAvatar`, not a symbol name
/// for a bespoke storage path). `QAudionAvatar`'s `sficon://` rendering
/// added alongside this stays in place read-only, so anyone who already
/// picked an old SF Symbol keeps seeing it until they pick a character
/// here — this view can no longer produce a new one.
struct AvatarIconPicker: View {
    let onSelect: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionScheme) private var scheme

    /// Same 8 characters, same order, as Android's `MCP_LOCAL_ICONS`.
    private let characters: [String] = [
        "AvatarCharManBeard", "AvatarCharWomanHair", "AvatarCharPersonCap",
        "AvatarCharWomanBob", "AvatarCharManHeadset", "AvatarCharPersonHoodie",
        "AvatarCharElderly", "AvatarCharYoungBeanie"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(characters, id: \.self) { name in
                        characterButton(name)
                    }
                }
                .padding(16)
            }
            .background(scheme.background.ignoresSafeArea())
            .navigationTitle("Scegli un personaggio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func characterButton(_ name: String) -> some View {
        Button {
            // A missing asset (typo, catalog not synced) must not crash a
            // profile-settings sheet — silently no-op the tap instead.
            guard let uiImage = UIImage(named: name) else { return }
            onSelect(uiImage)
            dismiss()
        } label: {
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(Circle().stroke(scheme.outline.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

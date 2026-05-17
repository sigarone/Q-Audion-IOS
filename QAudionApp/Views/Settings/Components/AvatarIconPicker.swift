import SwiftUI

/// W445: Avatar icon picker sheet — system SF Symbols icons as avatar
/// alternatives. Mirrors Android's MCP_LOCAL_ICONS grid in ProfileScreen.kt.
/// Presented as a `.medium` detent sheet from AccountSettingsScreen.
struct AvatarIconPicker: View {
    let onSelect: (String) -> Void  // selected SF Symbol name
    @Environment(\.dismiss) private var dismiss
    @Environment(\.qaudionScheme) private var scheme

    // 24 curated SF Symbols that work well as avatars.
    private let icons: [String] = [
        "person.fill", "person.crop.circle.fill", "figure.wave",
        "cat.fill", "dog.fill", "hare.fill", "tortoise.fill", "bird.fill",
        "fish.fill", "ant.fill", "ladybug.fill", "leaf.fill",
        "flame.fill", "bolt.fill", "star.fill", "moon.fill",
        "sun.max.fill", "cloud.fill", "snowflake", "drop.fill",
        "heart.fill", "shield.fill", "lock.fill", "key.fill"
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(icons, id: \.self) { icon in
                        iconButton(icon)
                    }
                }
                .padding(16)
            }
            .background(scheme.background.ignoresSafeArea())
            .navigationTitle("Scegli icona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func iconButton(_ icon: String) -> some View {
        Button {
            onSelect(icon)
            dismiss()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(scheme.primary)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(scheme.primary.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon)
    }
}

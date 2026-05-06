import SwiftUI

/// Q-Audion top bar. 1:1 port of Android `QAudionTopBar` from
/// `qaudion-android-new/core/core-ui/.../components/QAudionTopBar.kt`.
///
/// - Title slot: plain `String` (rendered with `titleLarge`).
/// - Optional `onBack` callback: when non-nil renders a leading
///   chevron-left button mirroring Material's `ArrowBack` icon.
/// - Trailing `actions` view-builder for any right-side icons / menus.
/// - Container colour from `surface`, content colour from `onSurface`.
/// - Fixed height ≈ 56pt (Material small TopAppBar baseline).
public struct QAudionTopBar<Actions: View>: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let title: String
    let onBack: (() -> Void)?
    let actions: Actions

    public init(title: String,
                onBack: (() -> Void)? = nil,
                @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.onBack = onBack
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(scheme.onSurface)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Back")
            } else {
                Spacer().frame(width: 8)
            }

            Text(title)
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            actions
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .background(scheme.surface)
    }
}

#Preview {
    VStack(spacing: 0) {
        QAudionTopBar(title: "Chats", onBack: nil) {
            Image(systemName: "square.and.pencil")
                .font(.title3)
        }
        QAudionTopBar(title: "Settings", onBack: {}) {
            EmptyView()
        }
        Spacer()
    }
    .qAudionTheme(dark: true)
}

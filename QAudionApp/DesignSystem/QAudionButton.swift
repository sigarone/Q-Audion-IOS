import SwiftUI

/// Q-Audion button. 1:1 port of Android `QAudionButton` /
/// `QAudionButtonVariant` from
/// `qaudion-android-new/core/core-ui/.../components/QAudionButton.kt`.
///
/// 4 variants (Primary / Secondary / Destructive / Text). Pill shape
/// (Capsule) matching Material 3 default `RoundedCornerShape(50%)`.
/// Min height 40, horizontal padding 24, label = `labelLarge` style.
/// `loading` toggle disables the button and renders a circular progress
/// indicator + the label, mirroring Material's behaviour.
public enum QAudionButtonVariant {
    case primary       // filled, container = primary, content = onPrimary
    case secondary     // outlined, content = primary, default outline
    case destructive   // filled, container = error, content = onError
    case text          // text-only, content = primary, no fill, no border
}

public struct QAudionButton: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.isEnabled) private var systemEnabled

    let action: () -> Void
    let label: String
    let variant: QAudionButtonVariant
    let loading: Bool
    let enabled: Bool

    public init(action: @escaping () -> Void,
                label: String,
                variant: QAudionButtonVariant = .primary,
                loading: Bool = false,
                enabled: Bool = true) {
        self.action = action
        self.label = label
        self.variant = variant
        self.loading = loading
        self.enabled = enabled
    }

    /// Effective enabled state — Android disables when `loading == true`.
    private var isEnabled: Bool { enabled && !loading && systemEnabled }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(contentColor)
                }
                Text(label)
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(contentColor)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .padding(.horizontal, 24)
            .background(backgroundFill)
            .overlay(borderOverlay)
            .clipShape(Capsule())
            .opacity(isEnabled ? 1.0 : 0.45)
        }
        .disabled(!isEnabled)
    }

    // MARK: - Per-variant styling

    private var contentColor: Color {
        switch variant {
        case .primary:     return scheme.onPrimary
        case .secondary:   return scheme.primary
        case .destructive: return scheme.onError
        case .text:        return scheme.primary
        }
    }

    @ViewBuilder
    private var backgroundFill: some View {
        switch variant {
        case .primary:     Capsule().fill(scheme.primary)
        case .destructive: Capsule().fill(scheme.error)
        case .secondary, .text:
            Capsule().fill(.clear)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if variant == .secondary {
            Capsule().stroke(scheme.outline, lineWidth: 1)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        QAudionButton(action: {}, label: "Primary action", variant: .primary)
        QAudionButton(action: {}, label: "Secondary action", variant: .secondary)
        QAudionButton(action: {}, label: "Destructive", variant: .destructive)
        QAudionButton(action: {}, label: "Text only", variant: .text)
        QAudionButton(action: {}, label: "Loading…", variant: .primary, loading: true)
        QAudionButton(action: {}, label: "Disabled", variant: .primary, enabled: false)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .qAudionTheme(dark: true)
}

import SwiftUI

/// Large round in-call action button. 1:1 port of Android
/// `qaudion-android-new/feature/feature-call/.../components/CircularAction.kt`.
///
/// Renders a circle of the requested diameter with the SF Symbol icon
/// centred. Background is fully customisable so the same widget covers
/// every call-screen role: hangup (riskHigh, 72), accept (success, 72),
/// mute toggle (warning when active / surfaceVariant when inactive, 48),
/// audio-route cycler, video toggle, etc.
///
/// Optional caption label below the button ("Attiva / Muto / Termina"
/// style labels). When `caption == nil` the button is a single circle,
/// no extra layout.
struct CircularAction: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type

    let icon: String
    let action: () -> Void
    let diameter: CGFloat
    let background: Color
    let iconColor: Color
    let caption: String?
    let captionColor: Color?
    let isDisabled: Bool

    init(icon: String,
         action: @escaping () -> Void,
         diameter: CGFloat = 56,
         background: Color,
         iconColor: Color = .white,
         caption: String? = nil,
         captionColor: Color? = nil,
         isDisabled: Bool = false) {
        self.icon = icon
        self.action = action
        self.diameter = diameter
        self.background = background
        self.iconColor = iconColor
        self.caption = caption
        self.captionColor = captionColor
        self.isDisabled = isDisabled
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: { if !isDisabled { action() } }) {
                Circle()
                    .fill(background)
                    .frame(width: diameter, height: diameter)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: diameter * 0.40, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                    .opacity(isDisabled ? 0.45 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            if let caption {
                Text(caption)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(captionColor ?? scheme.onSurfaceVariant)
            }
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        CircularAction(icon: "phone.down.fill", action: {},
                       diameter: 72, background: .red,
                       caption: "Termina", captionColor: .red)
        CircularAction(icon: "mic.fill", action: {},
                       diameter: 56, background: .gray.opacity(0.3),
                       caption: "Muto")
        CircularAction(icon: "phone.fill", action: {},
                       diameter: 72, background: .green,
                       caption: "Accetta", captionColor: .green)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .qAudionTheme(dark: true)
}

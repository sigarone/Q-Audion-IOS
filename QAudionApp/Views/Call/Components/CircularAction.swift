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
    /// Entitlements Task 5 (mirrors Android review fix I1 #3,
    /// `CircularAction.kt`) — `true` (the pre-existing, always-unlocked
    /// behavior) for every call site except InCallScreen's
    /// "add participant" and "upgrade to video" buttons, which pass the
    /// real `Capability.callsGroup`/`.callsVideo` state. This component is
    /// shared across every in-call action (mute, speaker, camera toggle,
    /// hangup, voice-enhance, screen-share, accept/decline…) — none of
    /// those pass anything but the default, so they render byte-identical
    /// to before this parameter existed.
    let unlocked: Bool
    /// Required (not `(() -> Void)?` defaulting to `action`) for the same
    /// reason Android's `GatedActionButton`/`GatedActionButton.kt` makes
    /// this a required param: a future caller passing `unlocked` without
    /// `onLockedClick` must not have a LOCKED tap silently perform the
    /// real action. Defaults to a no-op only because `unlocked` itself
    /// defaults to `true`, in which case this closure is never consulted.
    let onLockedClick: () -> Void

    init(icon: String,
         action: @escaping () -> Void,
         diameter: CGFloat = 56,
         background: Color,
         iconColor: Color = .white,
         caption: String? = nil,
         captionColor: Color? = nil,
         isDisabled: Bool = false,
         unlocked: Bool = true,
         onLockedClick: @escaping () -> Void = {}) {
        self.icon = icon
        self.action = action
        self.diameter = diameter
        self.background = background
        self.iconColor = iconColor
        self.caption = caption
        self.captionColor = captionColor
        self.isDisabled = isDisabled
        self.unlocked = unlocked
        self.onLockedClick = onLockedClick
    }

    var body: some View {
        VStack(spacing: 6) {
            Button(action: {
                guard !isDisabled else { return }
                if unlocked { action() } else { onLockedClick() }
            }) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(background)
                        .frame(width: diameter, height: diameter)
                        .overlay {
                            Image(systemName: icon)
                                .font(.system(size: diameter * 0.40, weight: .semibold))
                                .foregroundStyle(iconColor)
                        }
                        .opacity(isDisabled || !unlocked ? 0.45 : 1.0)
                    // Entitlements Task 5 — the lock badge sits OUTSIDE the
                    // circle's own clip (this ZStack is not itself clipped),
                    // same reasoning as Android's CircularAction.kt fix: a
                    // badge aligned to a square's corner mostly falls
                    // outside an inscribed circle, so clipping the badge
                    // together with the circle would render it invisible.
                    if !unlocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                            .accessibilityLabel("Richiede account Pro")
                    }
                }
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

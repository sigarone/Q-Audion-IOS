import SwiftUI

/// W-HBTELEM (2026-09-21) — the small "Disturbo" pill on the 1:1 in-call screen.
///
/// The call-quality analysis of 2026-09-20 could not tie a single counter to what a person
/// heard, because nobody had recorded WHEN they heard it. Tapping this marks that instant:
/// the caller (`LiveInCallScreen`) emits `call.disturbance.marker` through the same telemetry
/// emitter as every other call event. Nothing is sent from here and nothing is asked of the
/// user beyond one tap.
///
/// Look: it reuses `MetaPill`, the call screen's own small status pill, and sits in the
/// transport row next to the diagnostics button, so it adds no new visual language. Feedback
/// is a light haptic and a two-second confirmation (the pill turns green with a check); it
/// never blocks and never shows a dialog. The one-marker-per-second debounce lives in the
/// emitter (`CallMediaTelemetry.recordDisturbanceMarker`), so it holds however this is used.
struct DisturbanceMarkButton: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras

    /// Called on every tap. Emits the marker.
    let action: () -> Void

    @State private var confirmed: Bool = false
    @State private var tapCount: Int = 0

    private static let confirmationSeconds: Double = 2.0

    var body: some View {
        Button(action: handleTap) {
            MetaPill(Self.pillText(confirmed: confirmed),
                     accent: confirmed ? extras.success : scheme.onSurfaceVariant,
                     filled: confirmed)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityText())
    }

    private func handleTap() {
        HapticFeedback.callMarker()
        action()
        confirmed = true
        tapCount += 1
        let token: Int = tapCount
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationSeconds) {
            if tapCount == token {
                confirmed = false
            }
        }
    }

    // String building lives outside the ViewBuilder (CLAUDE.md lesson 13).

    private static func pillText(confirmed: Bool) -> String {
        let label: String = String(
            localized: "in_call.disturbance_button",
            defaultValue: "Disturbo",
            comment: "In-call transport row — small pill the user taps to mark the instant an audio glitch was heard (a telemetry marker for the maintainer). Keep it one short word."
        )
        if confirmed {
            return "\u{2713} " + label
        }
        return label
    }

    private static func accessibilityText() -> String {
        return String(
            localized: "in_call.disturbance_button_a11y",
            defaultValue: "Segnala disturbo audio",
            comment: "VoiceOver label of the in-call \"Disturbo\" pill — reports that an audio glitch was just heard."
        )
    }
}

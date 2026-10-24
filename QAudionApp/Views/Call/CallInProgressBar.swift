import SwiftUI

/// The "call in progress" bar: shown on top of the ordinary screens of the app while a call is reduced
/// (`CallMinimizePolicy.surface`). It carries who is on the call, how long it has lasted and a "return to call" label,
/// and the whole bar is one button that brings the call screen back.
///
/// It has no hang-up control on purpose: hanging up stays on the call screen. It is a window onto the call, never a
/// handle on it. It takes plain values and closures (not `AppState`) so it stays a thin view.
///
/// Text follows the size the user chose (Dynamic Type); at the accessibility sizes the row becomes a column so nothing is
/// cut off. VoiceOver reads the bar as one button: title, name, time, "return to call".
struct CallInProgressBar: View {
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 18

    /// The person on the call. nil or empty hides the name line (the bar then says only "call in progress").
    let contactName: String?
    /// How long the call has lasted, in seconds; read again on every tick of the one-second clock.
    let elapsedSeconds: () -> TimeInterval
    /// The bar was tapped.
    let onReturn: () -> Void

    var body: some View {
        Button(action: onReturn) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                barContent(duration: CallElapsedText.format(seconds: elapsedSeconds()))
            }
        }
        .buttonStyle(CallBarPressStyle())
        // The colour reaches up under the status bar; the content below stays inside the safe area.
        .background(extras.success, ignoresSafeAreaEdges: .top)
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private func barContent(duration: String) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            stackedContent(duration: duration)
        } else {
            rowContent(duration: duration)
        }
    }

    /// Icon, title and name on the left, the time and the "return to call" label on the right.
    private func rowContent(duration: String) -> some View {
        HStack(spacing: 10) {
            phoneIcon
            VStack(alignment: .leading, spacing: 0) {
                titleText.lineLimit(1)
                nameText.lineLimit(1)
            }
            Spacer(minLength: 0)
            durationText(duration)
            returnText.lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .foregroundStyle(extras.onSuccess)
        .contentShape(Rectangle())
    }

    /// The same texts one under the other, for the accessibility text sizes.
    private func stackedContent(duration: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                phoneIcon
                titleText
            }
            nameText
            durationText(duration)
            returnText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .foregroundStyle(extras.onSuccess)
        .contentShape(Rectangle())
    }

    private var phoneIcon: some View {
        Image(systemName: "phone.fill")
            .font(.system(size: iconSize))
            .accessibilityHidden(true)
    }

    private var titleText: some View {
        Text("Chiamata in corso")
            .font(.subheadline.weight(.semibold))
    }

    @ViewBuilder
    private var nameText: some View {
        if let name = contactName, !name.isEmpty {
            Text(verbatim: name)
                .font(.caption)
        }
    }

    private func durationText(_ duration: String) -> some View {
        Text(verbatim: duration)
            .font(.subheadline.monospacedDigit())
    }

    private var returnText: some View {
        Text("Torna alla chiamata")
            .font(.subheadline.weight(.semibold))
    }
}

/// A light press feedback for the whole bar.
private struct CallBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The button that reduces the call screen to the bar: a chevron in a 44 pt circle, top right of the call screen.
struct MinimizeCallButton: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(scheme.onSurface)
                .frame(width: 44, height: 44)
                .qaudionGlassSurface(in: Circle(), interactive: true,
                                     fallback: scheme.surface.opacity(reduceTransparency ? 1 : 0.85))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Riduci la chiamata"))
    }
}

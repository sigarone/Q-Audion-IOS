import SwiftUI

// Small styling helpers shared by the voice-analysis views of the call screen
// (ribbon gauges, voice check card, voice-biometrics rows).

extension VoiceTone {
    /// The design-system colour for this role.
    func color(scheme: QAudionColorScheme, extras: QAudionColorsExtra) -> Color {
        switch self {
        case .success:  return extras.success
        case .warning:  return extras.warning
        case .riskHigh: return extras.riskHigh
        case .neutral:  return scheme.onSurfaceVariant
        }
    }
}

/// A monospaced system font whose size follows the reader's Dynamic Type
/// setting. `size` is the size at the default setting; `style` is the text
/// style it scales like.
struct ScaledMonoFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: .monospaced))
    }
}

extension View {
    /// Monospaced text that scales with Dynamic Type. Apply Text-only
    /// modifiers (such as `tracking`) before this one.
    func scaledMono(_ size: CGFloat,
                    weight: Font.Weight = .medium,
                    relativeTo style: Font.TextStyle = .caption) -> some View {
        modifier(ScaledMonoFont(size: size, weight: weight, relativeTo: style))
    }
}

/// The small green dot at the head of the custody card: it breathes between
/// full and a third of its opacity (1.1 s each way), and stands still, fully
/// lit, when Reduce Motion is on.
struct VoiceCustodyPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity((reduceMotion || !dimmed) ? 1.0 : 0.35)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .accessibilityHidden(true)
    }
}

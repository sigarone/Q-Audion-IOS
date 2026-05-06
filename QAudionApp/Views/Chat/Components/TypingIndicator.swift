import SwiftUI

/// 3-dot typing indicator. 1:1 port of Android
/// `qaudion-android-new/feature/feature-chat/.../components/TypingIndicator.kt`.
///
/// Three 6pt circles, 4pt spacing, color = `scheme.primary`. Each dot
/// animates its alpha 0.3↔1.0 via an infinite reverse animation, with
/// a stagger of 0 / 180 / 360 ms so the 3 dots are out-of-phase
/// ("pulse wave" feel rather than synchronized blink).
///
/// SwiftUI uses `Animation.easeInOut(duration: 0.72).repeatForever(autoreverses: true)`
/// to mirror Compose's `infiniteRepeatable(tween 720, RepeatMode.Reverse)`,
/// and offsets the start of each dot's animation by the corresponding
/// stagger via `.delay(_:)` on the `withAnimation` block driven by
/// `.onAppear`.
struct TypingIndicator: View {
    @Environment(\.qaudionScheme) private var scheme
    @State private var phaseStart: Date? = nil

    private let dotSize: CGFloat = 6
    private let dotSpacing: CGFloat = 4
    private let staggerMs: [Int] = [0, 180, 360]
    private let halfPeriod: TimeInterval = 0.72

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(scheme.primary)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(alpha(for: i))
            }
        }
        .onAppear {
            phaseStart = Date()
            // Force a TimelineView-style refresh by triggering a state
            // change via the system clock. We use a `withAnimation`
            // block on .onAppear to install the infinite repeating
            // animation; SwiftUI re-evaluates `alpha(for:)` against
            // the current Date on every frame because we depend on
            // `phaseStart` via TimelineView below.
        }
        // Use a TimelineView so we re-render at ~30 fps while the
        // indicator is on screen — this keeps the alpha lerp continuous
        // even though we're computing it from a Date rather than from
        // an `@State` Double driven by `withAnimation`.
        .background(
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                Color.clear
                    .preference(key: TypingTickKey.self,
                                value: context.date.timeIntervalSinceReferenceDate)
            }
        )
        .onPreferenceChange(TypingTickKey.self) { _ in
            // No-op; the preference change forces the body to re-evaluate.
            // The actual alpha is computed in `alpha(for:)` from `phaseStart`
            // and the current wall clock.
        }
    }

    /// Compute the dot's current alpha.
    /// Returns a value in [0.3, 1.0] using a triangle wave (linear
    /// interpolation) with a 720ms half-period and the per-dot stagger.
    private func alpha(for index: Int) -> Double {
        guard let start = phaseStart else { return 0.3 }
        let stagger = TimeInterval(staggerMs[index]) / 1000.0
        let elapsed = max(0, Date().timeIntervalSince(start) - stagger)
        let phase = elapsed.truncatingRemainder(dividingBy: 2 * halfPeriod) / halfPeriod
        // Triangle wave: 0..1..0 across the full period.
        let v = phase < 1.0 ? phase : (2.0 - phase)
        return 0.3 + 0.7 * v
    }
}

private struct TypingTickKey: PreferenceKey {
    static let defaultValue: TimeInterval = 0
    static func reduce(value: inout TimeInterval, nextValue: () -> TimeInterval) {
        value = nextValue()
    }
}

#Preview {
    VStack {
        TypingIndicator()
            .padding()
        Spacer()
    }
    .qAudionTheme(dark: true)
}

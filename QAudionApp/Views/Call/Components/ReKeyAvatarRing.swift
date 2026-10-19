import SwiftUI

/// What the ring around the contact avatar draws for the re-key countdown.
struct ReKeyRingState: Equatable {
    /// Share of the arc still drawn, 0...1. The arc starts at 12 o'clock and runs clockwise, so a smaller value means
    /// its moving end has retreated towards 12 o'clock.
    let fraction: Double
    /// Text of the pill sitting on the ring at 6 o'clock; nil = no pill (there is no re-key timer).
    let label: String?
    /// Whole seconds until the next re-key; nil while a re-key is running or when there is no timer.
    let secondsLeft: Int?
}

/// Pure decisions behind the ring: no SwiftUI in here, so the clamping and the text are covered by unit tests.
enum ReKeyRingModel {
    /// - Parameters:
    ///   - remainingSeconds: seconds left in the current re-key period.
    ///   - totalSeconds: length of the current re-key period; `<= 0` = no timer (not connected yet).
    ///   - isReKeying: a re-key round is running right now.
    static func state(remainingSeconds: Int, totalSeconds: Int, isReKeying: Bool) -> ReKeyRingState {
        guard totalSeconds > 0 else {
            return ReKeyRingState(fraction: 0, label: nil, secondsLeft: nil)
        }
        if isReKeying {
            return ReKeyRingState(fraction: 1, label: String(localized: "RE-KEY"), secondsLeft: nil)
        }
        let left = min(max(remainingSeconds, 0), totalSeconds)
        let secondsText = left.description + "s"
        return ReKeyRingState(fraction: Double(left) / Double(totalSeconds),
                              label: String(localized: "RE-KEY \(secondsText)"),
                              secondsLeft: left)
    }

    /// Whole seconds of a millisecond span, rounded up so the pill reads "1s" until the very end and never "0s" while
    /// time is still left; a negative span reads 0.
    static func wholeSeconds(milliseconds: Int64) -> Int {
        guard milliseconds > 0 else { return 0 }
        return Int((milliseconds + 999) / 1000)
    }
}

/// Re-key countdown drawn as a ring around the avatar of the in-call screen: a faint full-circle track with the
/// remaining share of the period on top, and a pill with the seconds left sitting on the ring at 6 o'clock.
///
/// The colour is the accent the old countdown dial already used (`scheme.primary`); it carries no trust, voice or
/// connection meaning. The pill is drawn centred on the ring line, so it overflows the frame by half its height;
/// the caller leaves room under the avatar for it.
struct ReKeyAvatarRing: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let remainingSeconds: Int
    let totalSeconds: Int
    let isReKeying: Bool
    let diameter: CGFloat
    let lineWidth: CGFloat

    init(remainingSeconds: Int,
         totalSeconds: Int,
         isReKeying: Bool = false,
         diameter: CGFloat = 144,
         lineWidth: CGFloat = 4) {
        self.remainingSeconds = remainingSeconds
        self.totalSeconds = totalSeconds
        self.isReKeying = isReKeying
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    var body: some View {
        let state = ReKeyRingModel.state(remainingSeconds: remainingSeconds,
                                         totalSeconds: totalSeconds,
                                         isReKeying: isReKeying)
        ZStack {
            Circle()
                .stroke(scheme.primary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(state.fraction))
                .stroke(scheme.primary,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // A round cap on an empty trim would still leave a dot at 12 o'clock.
                .opacity(state.fraction > 0 ? 1 : 0)
                .animation(fillAnimation, value: state.fraction)
            if let label = state.label {
                pill(label)
                    .offset(y: diameter / 2)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(state.label == nil)
        .accessibilityLabel(accessibilityText(state))
    }

    /// Short ease so the ring refills after a re-key and follows the one-second ticks; none with Reduce Motion.
    private var fillAnimation: Animation? {
        reduceMotion ? nil : Animation.easeInOut(duration: 0.6)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .scaledMono(11, weight: .semibold)
            .foregroundStyle(scheme.onSurface)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(scheme.surface))
            .overlay(Capsule().stroke(scheme.primary, lineWidth: 1.5))
    }

    private func accessibilityText(_ state: ReKeyRingState) -> Text {
        if let secondsLeft = state.secondsLeft {
            return Text("Prossimo re-key tra \(secondsLeft) secondi")
        }
        return Text("RE-KEY")
    }
}

import SwiftUI
import QAudionEngine

/// The "voice check" card of the call screen, under the voice ribbon.
///
/// It only ever shows state, never asks for a tap. In priority order:
///  - the brief confirmation (3.5 s) when the voice-learning session ends,
///    either "learned and verified" or "learning failed, will retry next call";
///  - the learning progress while the session runs;
///  - "waiting for voice data" until the first sample of the call exists;
///  - the verdict word with the live wave, coloured by the verdict of "is this
///    still the voice the call started with".
struct VoiceGuardCard: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let learningState: VoiceLearningSession.State?
    let confidenceHistory: [Float]
    let speakerChange: RemoteSpeakerChangeMonitor.Verdict

    @State private var banner: VoiceGuardBanner?
    @State private var bannerTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .caption) private var verdictColumnWidth: CGFloat = 92

    private var level: VoiceGuardLevel? {
        VoiceGuard.level(of: speakerChange.level)
    }

    private var cardContent: VoiceGuardContent {
        VoiceGuard.content(banner: banner,
                           learning: learningState,
                           hasHistory: !confidenceHistory.isEmpty,
                           level: level)
    }

    /// Colour role of the icon, and of the whole card while a banner shows.
    private var iconTone: VoiceTone {
        VoiceGuard.bannerTone(of: banner) ?? VoiceGuard.tone(of: level)
    }

    private func color(_ tone: VoiceTone) -> Color {
        tone.color(scheme: scheme, extras: extras)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color(iconTone))
                .accessibilityHidden(true)
            contentView
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .onChange(of: learningState) { newState in
            showBanner(for: newState)
        }
        .onDisappear {
            bannerTask?.cancel()
            bannerTask = nil
            banner = nil
        }
    }

    // MARK: Chrome

    private var iconName: String {
        switch VoiceGuard.icon(banner: banner, level: level) {
        case .check:      return "checkmark"
        case .warning:    return "exclamationmark.triangle"
        case .microphone: return "mic"
        }
    }

    private var backgroundColor: Color {
        if let tone = VoiceGuard.bannerTone(of: banner) {
            return color(tone).opacity(0.14)
        }
        return scheme.surface.opacity(reduceTransparency ? 1.0 : 0.55)
    }

    private var borderColor: Color {
        if let tone = VoiceGuard.bannerTone(of: banner) {
            return color(tone).opacity(0.4)
        }
        return scheme.outline.opacity(0.5)
    }

    // MARK: Content

    @ViewBuilder
    private var contentView: some View {
        switch cardContent {
        case .banner(let kind):
            bannerText(kind)
        case .learning(let progress):
            learningView(progress)
        case .waiting:
            waitingText
        case .verdict(let verdictLevel):
            verdictView(verdictLevel)
        }
    }

    private func bannerText(_ kind: VoiceGuardBanner) -> some View {
        let text: String
        switch kind {
        case .learned:
            text = String(localized: "in_call.voice_guard.learned",
                          defaultValue: "Voce appresa e verificata",
                          comment: "Call screen voice check card — shown briefly when the voice of the other person has been learned and verified")
        case .failed:
            text = String(localized: "in_call.voice_guard.learn_failed",
                          defaultValue: "Apprendimento non riuscito — riproverà alla prossima chiamata",
                          comment: "Call screen voice check card — shown briefly when learning the voice of the other person did not succeed; it will be retried on the next call")
        }
        return Text(text)
            .foregroundStyle(color(VoiceGuard.bannerTone(of: kind) ?? .neutral))
            .scaledMono(11, weight: .semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func learningView(_ progress: Float) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(localized: "in_call.voice_guard.learning",
                        defaultValue: "Riconoscimento vocale in corso…",
                        comment: "Call screen voice check card — shown while the voice of the other person is being learned"))
                .foregroundStyle(scheme.onSurface)
                .scaledMono(11, weight: .semibold)
            progressBar(progress)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(VoiceGuard.percentText(progress)))
    }

    private func progressBar(_ progress: Float) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(scheme.surfaceVariant)
                Capsule()
                    .fill(extras.pqcAccent)
                    .frame(width: geo.size.width * CGFloat(progress))
            }
        }
        .frame(height: 4)
    }

    private var waitingText: some View {
        Text(String(localized: "in_call.voice_guard.waiting",
                    defaultValue: "In attesa di dati vocali…",
                    comment: "Call screen voice check card — shown until the first voice sample of the call has been analysed"))
            .foregroundStyle(scheme.onSurfaceVariant)
            .scaledMono(11)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verdictView(_ verdictLevel: VoiceGuardLevel?) -> some View {
        let tone = VoiceGuard.tone(of: verdictLevel)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "in_call.voice_guard.title",
                            defaultValue: "Verifica vocale",
                            comment: "Call screen voice check card — small title above the verdict word"))
                    .tracking(0.4)
                    .foregroundStyle(scheme.onSurfaceVariant)
                    .scaledMono(11)
                    .lineLimit(2)
                Text(verdictWord(verdictLevel))
                    .foregroundStyle(color(tone))
                    .scaledMono(11, weight: .semibold)
                    .lineLimit(2)
            }
            .frame(width: verdictColumnWidth, alignment: .leading)
            VoiceGuardWaveView(history: confidenceHistory, color: color(tone))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .accessibilityLabel(Text(String(localized: "in_call.voice_guard.curve_a11y",
                                                defaultValue: "Andamento della verifica vocale in questa chiamata",
                                                comment: "Accessibility label of the live wave on the call screen voice check card")))
        }
    }

    private func verdictWord(_ verdictLevel: VoiceGuardLevel?) -> String {
        switch VoiceGuard.word(for: verdictLevel) {
        case .pending:
            return String(localized: "in_call.voice_guard.pending",
                          defaultValue: "Verifica in corso",
                          comment: "Call screen voice check card — verdict word while there is no verdict yet")
        case .verified:
            return String(localized: "in_call.voice_guard.verified",
                          defaultValue: "Voce riconosciuta",
                          comment: "Call screen voice check card — verdict word when the voice is still the one the call started with")
        case .caution:
            return String(localized: "in_call.voice_guard.caution",
                          defaultValue: "Verifica incerta",
                          comment: "Call screen voice check card — verdict word when the voice may have changed")
        case .highRisk:
            return String(localized: "in_call.voice_guard.highrisk",
                          defaultValue: "Anomalia rilevata",
                          comment: "Call screen voice check card — verdict word when the voice has changed")
        }
    }

    // MARK: Banner lifetime

    private func showBanner(for state: VoiceLearningSession.State?) {
        guard let kind = VoiceGuard.banner(for: state) else { return }
        banner = kind
        bannerTask?.cancel()
        bannerTask = Task { await dismissBannerAfterDelay() }
    }

    @MainActor
    private func dismissBannerAfterDelay() async {
        let nanoseconds = UInt64(VoiceGuard.bannerSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        if Task.isCancelled { return }
        banner = nil
    }
}

/// The single live trace of the card: the recent confidence samples, centred on
/// their mean and scaled by their own spread, so that a healthy steady call
/// shows a calm line and a real change shows as a visible swing. Fewer than two
/// samples draw a flat line.
struct VoiceGuardWaveView: View {
    let history: [Float]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: &ctx, size: size)
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let deviations = VoiceGuardWave.deviations(of: history)
        guard deviations.count >= 2 else {
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: midY))
            flat.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(flat, with: .color(color.opacity(0.35)), lineWidth: 1.5)
            return
        }
        let stepX = size.width / CGFloat(deviations.count - 1)
        var line = Path()
        for (index, deviation) in deviations.enumerated() {
            let point = CGPoint(x: CGFloat(index) * stepX,
                                y: midY - CGFloat(deviation) * midY * 0.85)
            if index == 0 {
                line.move(to: point)
            } else {
                line.addLine(to: point)
            }
        }
        ctx.stroke(line, with: .color(color), lineWidth: 2)
    }
}

import SwiftUI
import QAudionEngine

/// The "voice check" card of the call screen, under the voice ribbon.
///
/// It only ever shows state, never asks for a tap. In priority order:
///  - the brief confirmation (3.5 s) when the voice-learning session ends,
///    either "voice learned" or "learning failed, will retry next call";
///  - the learning progress while the session runs;
///  - the verdict word with the live wave and a short explanation under it,
///    coloured by the verdict of "is this still the voice the call started
///    with". There are exactly four words: "Voce coerente", "Da controllare",
///    "Anomalia" and "Dati insufficienti" (shown until there is enough to
///    compare, which includes the first seconds of the call, before the first
///    sample exists). None of them speaks of emotion, stress, health or coercion.
struct VoiceGuardCard: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let learningState: VoiceLearningSession.State?
    let confidenceHistory: [Float]
    let speakerChange: RemoteSpeakerChangeMonitor.Verdict

    @State private var banner: VoiceGuardBanner?
    @State private var bannerTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .caption) private var verdictColumnWidth: CGFloat = 110

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
            // Nothing to compare yet: the same "Dati insufficienti" word as a
            // verdict without a level, with a flat trace (no history to draw).
            verdictView(nil)
        case .verdict(let verdictLevel):
            verdictView(verdictLevel)
        }
    }

    private func bannerText(_ kind: VoiceGuardBanner) -> some View {
        let text: String
        switch kind {
        case .learned:
            text = String(localized: "in_call.voice_guard.learned",
                          defaultValue: "Voce appresa",
                          comment: "Call screen voice check card — shown briefly when the voice of the other person has been learned; it does not claim the voice was verified as genuine")
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

    private func verdictView(_ verdictLevel: VoiceGuardLevel?) -> some View {
        let tone = VoiceGuard.tone(of: verdictLevel)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
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
            Text(verdictNote(verdictLevel))
                .foregroundStyle(scheme.onSurfaceVariant)
                .scaledMono(11)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The four words of the verdict. `pending` is also what the card shows
    /// before the first voice sample of the call exists.
    private func verdictWord(_ verdictLevel: VoiceGuardLevel?) -> String {
        switch VoiceGuard.word(for: verdictLevel) {
        case .pending:
            return String(localized: "in_call.voice_guard.pending",
                          defaultValue: "Dati insufficienti",
                          comment: "Call screen voice check card — verdict word when there is not enough data to compare the voice yet")
        case .verified:
            return String(localized: "in_call.voice_guard.verified",
                          defaultValue: "Voce coerente",
                          comment: "Call screen voice check card — verdict word when the voice shows no unusual change from the one the call started with")
        case .caution:
            return String(localized: "in_call.voice_guard.caution",
                          defaultValue: "Da controllare",
                          comment: "Call screen voice check card — verdict word when the voice changed and the change is worth verifying")
        case .highRisk:
            return String(localized: "in_call.voice_guard.highrisk",
                          defaultValue: "Anomalia",
                          comment: "Call screen voice check card — verdict word when the voice changed in an unusual way")
        }
    }

    /// The short explanation under the verdict word. It says what the word
    /// means for the comparison and what to do; it never states a conclusion
    /// about emotion, stress, health or coercion.
    private func verdictNote(_ verdictLevel: VoiceGuardLevel?) -> String {
        switch VoiceGuard.word(for: verdictLevel) {
        case .pending:
            return String(localized: "in_call.voice_guard.pending_note",
                          defaultValue: "Non ci sono ancora abbastanza dati per confrontare la voce.",
                          comment: "Call screen voice check card — explanation under the verdict word when there is not enough data to compare the voice yet")
        case .verified:
            return String(localized: "in_call.voice_guard.verified_note",
                          defaultValue: "Nessun cambiamento insolito rispetto alla voce abituale della persona.",
                          comment: "Call screen voice check card — explanation under the verdict word when the voice shows no unusual change")
        case .caution:
            return String(localized: "in_call.voice_guard.caution_note",
                          defaultValue: "C'è un cambiamento da verificare, per esempio con il numero di sicurezza di 60 cifre.",
                          comment: "Call screen voice check card — explanation under the verdict word when the voice changed and the change should be verified, for example by comparing the 60-digit safety number")
        case .highRisk:
            return String(localized: "in_call.voice_guard.highrisk_note",
                          defaultValue: "La voce è cambiata in modo insolito: verifica l'identità della persona.",
                          comment: "Call screen voice check card — explanation under the verdict word when the voice changed in an unusual way: verify the identity of the person")
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

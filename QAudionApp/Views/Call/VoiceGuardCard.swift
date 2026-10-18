import SwiftUI
import QAudionEngine

/// The "voice check" card of the call screen, under the voice ribbon.
///
/// It only ever shows state, never asks for a tap. In priority order:
///  - the brief confirmation (3.5 s) when the voice-learning session ends,
///    either "voice learned" or "learning failed, will retry next call";
///  - the learning progress while the session runs (it starts on its own on a
///    call with a contact that has no stored voice template yet);
///  - the verdict word, with the wave and a short explanation under it,
///    coloured by the verdict.
///
/// The verdict is the answer of the speaker-change monitor
/// (`RemoteSpeakerChangeMonitor`, published as `AppState.speakerChangeVerdict`)
/// to "is the voice arriving from the far end still the one this call started
/// with". It compares the call with itself, not with an identity, and it is
/// informational: nothing is muted, blocked or ended by it. There are exactly
/// four words: "Voce coerente", "Da controllare", "Anomalia" and "Dati
/// insufficienti". None of them speaks of emotion, stress, health or coercion.
///
/// "Dati insufficienti" has two causes, not one:
///  - the monitor has no level yet. It needs a warm-up of voice scores
///    (`SpeakerChangeDetector.defaultWarmupSamples`, about one score every 3 s
///    of speech in the foreground and every 10 s in the background), which takes
///    tens of seconds, not the first few seconds of a call;
///  - the Guardian confidence history that draws the wave has no sample yet.
///    That is checked first (`VoiceGuard.content`): until the history has its
///    first sample the card says "Dati insufficienti" even if the monitor
///    already has a level.
///
/// "Da controllare" can also come from the far end's own report alone
/// (`RemoteSpeakerChangeMonitor.Verdict.peerReportedOnly`). A report from
/// outside this device never raises the verdict above that word, and the card
/// does not tell it apart from a change this device heard.
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
            // No Guardian history yet: the same "Dati insufficienti" word as a
            // verdict without a level, with a flat trace (no history to draw),
            // whatever level the speaker-change monitor already has.
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

    /// The four words of the verdict. `pending` is what the card shows when
    /// the monitor has no level yet, and also while the Guardian history that
    /// draws the wave is still empty (see the doc of the card).
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

/// The single live trace of the card: the recent Guardian confidence samples
/// (`AppState.voiceConfidenceHistory`, a different measurement from the scores
/// behind the verdict word), centred on their mean and divided by their own
/// largest distance from it, never by less than `VoiceGuardWave.minSpread`.
///
/// The trace shows the shape of the movement, not its size: a window that moves
/// by more than the floor always reaches the same full swing, whether it is
/// ordinary wobble or a real change, and only a window that moves by less than
/// the floor is drawn proportionally smaller. What carries the verdict is the
/// colour of the card, not the amplitude of the wave. Fewer than two finite
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

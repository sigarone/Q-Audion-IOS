import SwiftUI
import QAudionEngine

/// The "voice check" card of the call screen, under the voice ribbon.
///
/// An icon and ONE line of text, with no sentence of explanation under it;
/// tapping the card opens a small popup that says what is compared and that
/// it is a hint (`VoiceGuardCopy.infoBody`). The line is `VoiceGuardLine`, in
/// priority order:
///  - the bare waiting line, while there is neither a verdict level nor a
///    single Guardian confidence sample;
///  - otherwise the verdict line, with the wave under it at the full width of
///    the card, coloured by the verdict. The level, when known, always wins:
///    it is shown even while the confidence history is still empty.
///
/// The verdict is the answer of the speaker-change monitor
/// (`RemoteSpeakerChangeMonitor`, published as `AppState.speakerChangeVerdict`)
/// to "is the voice arriving from the far end still the one this call started
/// with". It compares the call with itself, not with an identity or with past
/// calls, and it is informational: nothing is muted, blocked or ended by it.
/// The lines are "Ascolto della voce in corso", "Nessun cambio di voce in
/// chiamata", "Possibile cambio di voce" and "Voce cambiata durante la
/// chiamata". None of them speaks of emotion, stress, health, sincerity or
/// coercion.
///
/// "Ascolto della voce in corso" means the monitor has no level yet. It needs
/// a warm-up of voice scores (`SpeakerChangeDetector.defaultWarmupSamples`,
/// about one score every 3 s of speech in the foreground and every 10 s in the
/// background), which takes tens of seconds, not the first few seconds of a
/// call. Once the Guardian confidence history has a sample the line is shown
/// with the wave; before that, alone.
///
/// What the far end reports about its own detector never reaches the card: it
/// concerns this device's user and is not authenticated as such, so the
/// verdict is built from the local detector alone.
struct VoiceGuardCard: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let confidenceHistory: [Float]
    let speakerChange: RemoteSpeakerChangeMonitor.Verdict
    /// The live spectrum of the far end (40 bands, 0...1), or nil before the
    /// first decoded frame. The wave draws it over `voiceReference`.
    var voiceSpectrum: [Float]? = nil
    /// The frozen opening spectrum of this call, or nil until it exists.
    var voiceReference: [Float]? = nil

    @State private var showingInfo = false

    private var level: VoiceGuardLevel? {
        VoiceGuard.level(ofVerdict: speakerChange)
    }

    private var cardContent: VoiceGuardContent {
        VoiceGuard.content(hasHistory: !confidenceHistory.isEmpty, level: level)
    }

    /// The line the card reads right now.
    private var line: VoiceGuardLine {
        VoiceGuard.line(for: cardContent)
    }

    /// Colour role of the icon.
    private var iconTone: VoiceTone {
        VoiceGuard.tone(of: level)
    }

    /// The picture the wave draws right now. The words read aloud for the wave
    /// follow it, so they cannot describe the other picture.
    private var wavePicture: VoiceWavePicture {
        VoiceGuardWave.picture(live: voiceSpectrum, reference: voiceReference)
    }

    private func color(_ tone: VoiceTone) -> Color {
        tone.color(scheme: scheme, extras: extras)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The icon and the one line, in one row.
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .qaudionScaledFont(size: 16, weight: .semibold, maxSize: .xLarge)
                    .foregroundStyle(color(iconTone))
                    .accessibilityHidden(true)
                contentView
            }
            waveRow
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
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { showingInfo = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showingInfo = true }
        .alert(Text(VoiceGuardCopy.title), isPresented: $showingInfo) {
            Button("Ho capito") { showingInfo = false }
        } message: {
            Text(VoiceGuardCopy.infoBody)
        }
    }

    // MARK: Chrome

    private var iconName: String {
        switch VoiceGuard.icon(level: level) {
        case .check:      return "checkmark"
        case .warning:    return "exclamationmark.triangle"
        case .microphone: return "mic"
        }
    }

    private var backgroundColor: Color {
        return scheme.surface.opacity(reduceTransparency ? 1.0 : 0.55)
    }

    private var borderColor: Color {
        return scheme.outline.opacity(0.5)
    }

    // MARK: Content

    @ViewBuilder
    private var contentView: some View {
        switch cardContent {
        case .waiting:
            // Neither a verdict level nor a Guardian sample yet: just the line, no wave.
            lineText(color: color(VoiceGuard.tone(ofLine: line)))
        case .verdict(let verdictLevel):
            // The line only; the wave is under the row (`waveRow`).
            lineText(color: color(VoiceGuard.tone(of: verdictLevel)))
        }
    }

    /// The one line, on one line: it scales down a little before it is cut
    /// with an ellipsis, and the popup carries the explanation. The words a
    /// screen reader says start with the title of the card.
    private func lineText(color lineColor: Color) -> some View {
        Text(VoiceGuardCopy.text(for: line))
            .foregroundStyle(lineColor)
            .scaledMono(11, weight: .semibold)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(Text(VoiceGuardCopy.spoken(for: line)))
    }

    /// The wave under the icon-and-line row, at the full width of the card and
    /// 30 pt high, only while the card shows a verdict (the wave itself is
    /// unchanged).
    @ViewBuilder
    private var waveRow: some View {
        if case .verdict(let verdictLevel) = cardContent {
            VoiceGuardWaveView(history: confidenceHistory,
                               live: voiceSpectrum,
                               reference: voiceReference,
                               color: color(VoiceGuard.tone(of: verdictLevel)))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .accessibilityLabel(Text(VoiceWaveCopy.accessibilityLabel(for: wavePicture)))
        }
    }

}

/// The per-band heights the overlay is drawn from. A plain class kept in
/// `@State` so the same buffer survives re-renders, while stepping it during the
/// draw never invalidates the view tree (same pattern as the spectrum analyser
/// of the ribbon).
private final class VoiceWaveDisplay {
    var levels = [Float](repeating: 0, count: VoiceReferenceEnvelope.bandCount)
    /// Uptime (seconds) when the levels were last brought forward; nil before
    /// the first time. The fall is measured from it, so it does not depend on
    /// how many draws happen.
    var steppedAt: TimeInterval?
}

/// The wave of the card. It has two pictures, chosen by
/// `VoiceGuardWave.overlaysReference`:
///
///  - once the reference of this call exists (the average of its opening
///    seconds, frozen), the live spectrum of the far end is drawn over it: the
///    reference as a filled symmetric wave, the live spectrum as an outline on
///    top. The same voice keeps the outline riding the fill; a different voice
///    pulls the two apart across whole regions of the spectrum. Both are real
///    measurements of this call and are scaled by the one peak of the two, so
///    they can coincide only when they really do;
///  - before that (the opening seconds, or after the reference was dropped), or
///    when the two spectra cannot be told apart (all zero), the trend of the
///    Guardian confidence score (`AppState.voiceConfidenceHistory`, a different
///    measurement from the scores behind the verdict line): the recent samples
///    centred on their mean and divided by their own largest distance from it,
///    never by less than `VoiceGuardWave.minSpread`. It shows the shape of the
///    movement, not its size. Fewer than two finite samples draw a flat line.
///
/// Either way the picture is a companion of the verdict, never the verdict: the
/// colour of the card carries it, not the shape of the wave.
struct VoiceGuardWaveView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let history: [Float]
    let live: [Float]?
    let reference: [Float]?
    let color: Color

    @State private var display = VoiceWaveDisplay()

    /// The live outline eases down between spectrum frames, so it needs a clock
    /// of its own at the rate the frames come (about 15 Hz): silence arrives as
    /// the same all-zero frame again and again, which would not redraw the wave.
    /// Paused for the trend, which changes only with new samples, and under
    /// Reduce Motion, where the outline moves only when a frame arrives (by the
    /// time that passed since the last draw, like everywhere else).
    private var clockPaused: Bool {
        reduceMotion || !VoiceGuardWave.overlaysReference(live: live, reference: reference)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: clockPaused)) { timeline in
            Canvas { ctx, size in
                // Read the timeline date so each tick is a real dependency of
                // this draw: the outline keeps easing down between frames. How
                // far it eases is measured on the clock inside `draw`, not
                // counted per tick.
                _ = timeline.date
                draw(ctx: &ctx, size: size)
            }
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        guard VoiceGuardWave.overlaysReference(live: live, reference: reference),
              let live = live, let reference = reference else {
            drawTrend(ctx: &ctx, size: size, midY: midY)
            return
        }
        let count = min(display.levels.count, live.count)
        // The fall of 0.78 is per spectrum frame (about 15 a second), so it is
        // applied for the time that passed since the last draw, whatever
        // triggered this one (a tick, a new frame, a layout pass): a second
        // draw in the same instant steps nothing. The very first draw counts
        // as one frame.
        let now = ProcessInfo.processInfo.systemUptime
        var steps: Float = 1
        if let last = display.steppedAt {
            steps = VoiceGuardWave.frameSteps(elapsed: now - last)
        }
        display.steppedAt = now
        for index in 0..<count {
            display.levels[index] = VoiceGuardWave.nextDisplay(previous: display.levels[index],
                                                              target: live[index],
                                                              steps: steps)
        }
        let shown = Array(display.levels[0..<count])
        let base = Array(reference[0..<count])
        guard let overlay = VoiceGuardWave.overlay(display: shown, reference: base) else {
            drawTrend(ctx: &ctx, size: size, midY: midY)
            return
        }
        let stepX = count > 1 ? size.width / CGFloat(count - 1) : size.width
        let amplitude = midY * 0.92
        ctx.fill(outline(overlay.reference, stepX: stepX, midY: midY, amplitude: amplitude),
                 with: .color(color.opacity(0.18)))
        ctx.stroke(outline(overlay.live, stepX: stepX, midY: midY, amplitude: amplitude),
                   with: .color(color),
                   lineWidth: 1.6)
    }

    /// A closed symmetric shape: the levels above the centre line from left to
    /// right, then the same levels mirrored below it from right to left.
    private func outline(_ levels: [Float], stepX: CGFloat, midY: CGFloat, amplitude: CGFloat) -> Path {
        var path = Path()
        for (index, level) in levels.enumerated() {
            let point = CGPoint(x: CGFloat(index) * stepX, y: midY - CGFloat(level) * amplitude)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        for index in stride(from: levels.count - 1, through: 0, by: -1) {
            path.addLine(to: CGPoint(x: CGFloat(index) * stepX, y: midY + CGFloat(levels[index]) * amplitude))
        }
        path.closeSubpath()
        return path
    }

    private func drawTrend(ctx: inout GraphicsContext, size: CGSize, midY: CGFloat) {
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

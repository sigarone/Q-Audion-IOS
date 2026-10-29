import SwiftUI
import QAudionEngine

// MARK: - Call Security Badge

/// The compact security chip of the call screens and the details panel it expands to on a tap.
///
/// The chip holds a lock, a dot coloured by the Guardian level (grey while the Guardian has no reading), the network
/// path the call reports (a dash until one is reported) and a "PSK" tag when a pre-shared key was mixed into the
/// session key. The panel adds the Guardian word and score and one row each for the pre-shared key, the re-keys, the
/// encryption, the transport and the signalling ping. The PSK, encryption, transport and ping rows print a dash while
/// they have nothing to report, and the path in the chip does the same.
struct CallSecurityBadge: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.qaudionScheme) private var scheme
    @State private var isExpanded = false
    @State private var redPulse = false

    var body: some View {
        VStack(spacing: 0) {
            compactBadge
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }

            if isExpanded {
                expandedDetails
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// What the badge is drawn with where there is no glass: the translucent material, or the opaque surface colour when
    /// "Reduce Transparency" is on (what `qaudionMaterialBackground` did).
    private var surfaceFallback: AnyShapeStyle {
        switch QAudionBackdrop.resolve(reduceTransparency: reduceTransparency) {
        case .material: return AnyShapeStyle(Material.ultraThinMaterial)
        case .opaque: return AnyShapeStyle(scheme.surfaceVariant)
        }
    }

    // MARK: - Compact Badge

    /// Compact pill: [lock] [Guardian dot] [network path] [PSK tag] [chevron].
    ///
    /// The dot is green, yellow or red with the Guardian level once the Guardian has a reading, and grey before. The
    /// path is the backend the call reports ("p2p" | "turn" | "relay"), a dash until one is reported. The PSK tag
    /// appears only when a pre-shared key was mixed into this call's session key.
    private var compactBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
                .foregroundColor(.white)

            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .shadow(
                    color: appState.confidenceLevel == "red" ? .red.opacity(redPulse ? 0.9 : 0.3) : .clear,
                    radius: redPulse ? 8 : 3
                )
                .onAppear { startRedPulseIfNeeded() }
                .onChange(of: appState.confidenceLevel) { _ in startRedPulseIfNeeded() }

            Text(Self.backendLabel(appState.backendType))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(backendColor)

            // Drawn only on a verified fact: a pre-shared key was mixed into this call's session key. Not on
            // the broader `pskActive` flag.
            if appState.callPskMixedThisCall {
                Text("PSK")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.yellow)
                    .cornerRadius(4)
            }

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .qaudionGlassSurface(in: RoundedRectangle(cornerRadius: 20), fallback: surfaceFallback)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Sicurezza chiamata: \(statusLabel)")
        .accessibilityHint(isExpanded ? String(localized: "call.security.hide_details_a11y", defaultValue: "Nascondi i dettagli", comment: "VoiceOver hint of the call security badge while its details are shown.") : String(localized: "Mostra i dettagli"))
    }

    // MARK: - Expanded Details Panel

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(statusLabel)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(dotColor)
                Spacer()
                // A negative score is the "no Guardian score yet" sentinel, not
                // a percentage. It used to be impossible because the score was
                // seeded with a hardcoded 0.97, which showed the user a
                // confident-looking 97% before anything had been measured.
                Text(appState.confidenceScore < 0
                     ? "—"
                     : "\(Int(appState.confidenceScore * 100))%")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(dotColor)
            }

            Divider().background(Color.white.opacity(0.1))

            // Same fact as the chip above: the key and its fingerprint are named only when a pre-shared key was mixed
            // into this call; until then the row shows a dash.
            detailRow(
                label: "PSK",
                value: Self.pskWord(mixed: appState.callPskMixedThisCall,
                                    name: appState.pskName,
                                    fingerprint: appState.pskFingerprint)
            )

            // W-L10N-BATCH1 (2026-09-08) — detailRow's `label:` is a plain
            // String (see its signature below), not LocalizedStringKey, so
            // literal field-name labels here don't auto-localize. "PSK"
            // above is left as-is (protocol acronym, glossary
            // never-translate). "Re-key" default is kept verbatim English
            // (that's the current shipped text even under the Italian
            // locale) — not silently rewritten to Italian here, translators
            // pick each language's real equivalent.
            detailRow(label: String(localized: "call_security.label.rekey", defaultValue: "Re-key", comment: "Call security detail panel — field label for key-rotation count"), value: "\(appState.rekeyCount) rotazioni")
            detailRow(label: String(localized: "call_security.label.encryption", defaultValue: "Cifratura", comment: "Call security detail panel — field label for the active encryption algorithm"), value: Self.encryptionWord(algo: appState.encryptionAlgo, hasMlKemKey: CallSessionKeyShown.realKey(appState.callPqcSessionKey, source: appState.callSasKeySource) != nil))
            detailRow(label: String(localized: "call_security.label.transport", defaultValue: "Trasporto", comment: "Call security detail panel — field label for the media transport type"), value: Self.transportWord(backendType: appState.backendType))
            // `AppState.latencyMs` is the ping of the signalling socket (this device to the server), not the delay of
            // the call, so the row is named for what it is and drawn neutral: a green, yellow or red on it would read
            // as a verdict on the call quality that the number does not support.
            detailRow(label: String(localized: "call_security.label.signaling_ping", defaultValue: "Ping segnalazione", comment: "Call security detail panel — field label for the last ping round trip of the signalling connection (this device to the server); it is not the delay of the call"), value: Self.pingWord(ms: appState.latencyMs))
        }
        .padding(16)
        .qaudionGlassSurface(in: RoundedRectangle(cornerRadius: 16), fallback: surfaceFallback)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Detail Row Helper

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            // Wide enough for the longest label ("Signalisierungs-Ping" in German, "Ping de señalización" in
            // Spanish); a label that still does not fit goes on a second line.
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.gray)
                .lineLimit(2)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
        }
    }

    // MARK: - Computed Colors

    private var dotColor: Color {
        // W-CONFNEUTRAL (2026-10-07) — no Guardian reading yet (the -1 sentinel, shown as "—"): neutral, not the
        // green its reset level "green" would paint.
        guard ConfidenceThresholds.tone(of: Double(appState.confidenceScore)) != .noReading else { return .gray }
        switch appState.confidenceLevel {
        case "yellow": return .yellow
        case "red": return .red
        default: return .green
        }
    }

    private var backendColor: Color {
        switch appState.backendType {
        case "PQC": return .green
        case "BCR": return .blue
        default: return .gray
        }
    }

    private var statusLabel: String {
        Self.statusWord(level: appState.confidenceLevel, score: Double(appState.confidenceScore))
    }

    /// The word of the badge for a Guardian level and score. A call starts at level "green" with the -1 "no score
    /// yet" sentinel (the panel prints a dash, the dot is grey): that is no reading, so the word says there is not
    /// enough data instead of "Sicuro", a verdict nobody measured. This is the Guardian confidence of the badge, not
    /// the voice check card, which has its own words (`VoiceGuardCopy`).
    static func statusWord(level: String, score: Double) -> String {
        guard ConfidenceThresholds.tone(of: score) != .noReading else {
            return String(localized: "call_security.status_no_reading",
                          defaultValue: "Dati insufficienti",
                          comment: "Call security badge — status word while there is no Guardian reading yet (not enough data to say anything about the call)")
        }
        switch level {
        case "yellow": return String(localized: "call.security.status_warning", defaultValue: "Attenzione", comment: "Word of the compact call security badge when the Guardian level is yellow.")
        case "red":    return String(localized: "call.security.status_alarm", defaultValue: "Allarme", comment: "Word of the compact call security badge when the Guardian level is red.")
        default:       return String(localized: "call.security.status_safe", defaultValue: "Sicuro", comment: "Word of the compact call security badge when the Guardian level is green and a score exists.")
        }
    }

    // MARK: - Words of the details panel

    /// The transport row: the backend the call reports ("p2p" | "turn" | "relay"), in the words of the transport chip
    /// of the call screens. It used to print a fixed "P2P Direct" whatever the path, relay included.
    ///
    /// `AppState.backendType` is empty until a network path has been reported (there is no default path), and the
    /// row shows a dash until then: it used to start at "p2p" and print P2P before any path was known.
    static func transportWord(backendType: String) -> String {
        switch backendType {
        case "p2p":   return "P2P"
        case "turn":  return "TURN"
        case "relay": return "RELAY"
        default:      return "\u{2014}"
        }
    }

    /// The path word of the compact badge: the reported backend as it is, or a dash while no path was reported.
    static func backendLabel(_ backendType: String) -> String {
        backendType.isEmpty ? "\u{2014}" : backendType
    }

    /// The PSK row. It names the pre-shared key (name and fingerprint) only when a key was mixed into this call, the
    /// same fact as the PSK chip (`AppState.callPskMixedThisCall`); otherwise it prints a dash, which covers both "no
    /// key" and "not known yet". A name or a fingerprint alone does not make a key in use. A mixed key whose name and
    /// fingerprint are both unknown prints the dash too.
    static func pskWord(mixed: Bool, name: String, fingerprint: String) -> String {
        guard mixed else { return "\u{2014}" }
        let parts = [name, fingerprint].filter { !$0.isEmpty }
        return parts.isEmpty ? "\u{2014}" : parts.joined(separator: "  \u{2022}  ")
    }

    /// The encryption row: the algorithm text is a fixed announcement ("ML-KEM-1024 + ..."), so it is printed only once
    /// the call key really is the ML-KEM one; before that there is nothing to announce yet.
    static func encryptionWord(algo: String, hasMlKemKey: Bool) -> String {
        hasMlKemKey ? algo : "\u{2014}"
    }

    /// The "Ping segnalazione" row: the last round trip, in ms, of the keepalive ping on the signalling socket
    /// (`AppState.latencyMs`), or a dash while nothing was measured (0 is the unset value, not a measurement of "0 ms").
    ///
    /// It is the time between this device and the signalling server, not the delay of the call: it says nothing about
    /// the media path. It is also not reset between calls, and it is refreshed once per keepalive ping (every 20 s on
    /// Wi-Fi, 30 s on a wired or unknown path, 60 s on cellular), so it can be older than the call it is read in.
    static func pingWord(ms: Int) -> String {
        ms > 0 ? String(ms) + " ms" : "\u{2014}"
    }

    // MARK: - Red Glow Pulse Animation

    private func startRedPulseIfNeeded() {
        if appState.confidenceLevel == "red" {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                redPulse = true
            }
        } else {
            redPulse = false
        }
    }
}

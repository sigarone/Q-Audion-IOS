import SwiftUI

/// Outgoing-call (ringing) screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-call/.../OutgoingCallScreen.kt`.
///
/// Shown while we are dialing a peer and the PQC handshake is happening
/// in the background. Layout (top → bottom):
///
///   - "CHIAMANDO · SECURE CHANNEL ACTIVE" header (success, 2.0sp tracking)
///   - 240pt `AvatarHalo` (pqcAccent) + 160pt avatar circle
///   - peer display name (displaySmall, italic, semibold)
///   - "Chiamata audio sicura" subtitle
///   - 3 `MetaPill`s (PQC NEGOTIATING / VOICE TRUST · ENROLLED / LOW LATENCY)
///   - **Handshake log** — 3 rows that tick from circle → check as the
///     state machine advances:
///        1. "KEM encap generated"           (≥ handshaking)
///        2. "PSK matched from vault"        (≥ handshaking)
///        3. "HKDF session key derived"      (≥ connected)
///   - hangup `CircularAction` (riskHigh, 80) + "Ring MM:SS" label
///
/// `state` drives the handshake checklist. `errorMessage` non-nil shows
/// the riskHigh banner instead of the third action.
struct OutgoingCallScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    enum State: Equatable {
        case dialing
        case handshaking
        case connected
        case rekeying
        case ended
    }

    let peerDisplayName: String
    let avatarUrl: URL?
    let state: State
    let elapsedSeconds: Int
    let errorMessage: String?
    /// Numero interno PBX del destinatario (es. "103").
    /// Priorità assoluta nel cerchietto dell'avatar.
    let peerShortNumber: String?
    /// PSK binding method label ("NFC"/"QR"/"KMS"/…), non-nil only once a
    /// real PSK was mixed into THIS call's session key — mirrors
    /// `InCallScreen.KeyInfo.pskMethodLabel`. Shown as an immediate
    /// `MetaPill`, not an animated reveal — see this file's kdoc-equivalent
    /// note on `currentRingPhase` below for why.
    let pskMethodLabel: String?
    /// Session-key fingerprint, formatted like `LiveInCallScreen
    /// .sessionFingerprintFromKey` — non-nil only once the real PQC session
    /// key exists. Shown as an immediate `Text`, not an animated reveal.
    let sessionFingerprint: String?
    let onHangup: () -> Void

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         state: State = .dialing,
         elapsedSeconds: Int = 0,
         errorMessage: String? = nil,
         peerShortNumber: String? = nil,
         pskMethodLabel: String? = nil,
         sessionFingerprint: String? = nil,
         onHangup: @escaping () -> Void) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.errorMessage = errorMessage
        self.peerShortNumber = peerShortNumber
        self.pskMethodLabel = pskMethodLabel
        self.sessionFingerprint = sessionFingerprint
        self.onHangup = onHangup
    }

    /// Pure function of `state` — no local timer, see the implementation
    /// plan's Task 2 note on why (this screen is proven to survive exactly
    /// one render frame at `.connected`, `ContentView.swift:426-433`).
    // Named `currentRingPhase`, NOT `ringPhase`: a same-named computed
    // property calling the free function `ringPhase(for:)` (KeyExchangeRing
    // .swift) from its own body does not disambiguate by argument label —
    // Swift resolves the bare `ringPhase` callee to this property itself
    // ("use of 'ringPhase' refers to instance method rather than global
    // function"). Module-qualifying (`QAudionApp.ringPhase(for:)`) does NOT
    // fix it either: this target's `@main` entry type is ALSO named
    // `QAudionApp` (QAudionApp.swift), so `QAudionApp.` resolves to that
    // type, not the module, and the compiler reports "type 'QAudionApp' has
    // no member 'ringPhase'" instead. Renaming the property is the only fix
    // that isn't fighting Swift's name lookup — see the free function's own
    // definition for the actual phase-mapping logic.
    private var currentRingPhase: KeyExchangeRing.Phase {
        ringPhase(for: state)
    }

    /// True whenever a handshake round-trip is genuinely in flight —
    /// everything except the terminal `.ended` state (and `.rekeying`,
    /// which is dead in production wiring today but treated the same way
    /// for safety).
    private var ringConfirmed: Bool {
        state == .dialing || state == .handshaking || state == .connected
    }

    private var ringPQCColorForText: Color {
        Color(red: 0x8F / 255.0, green: 0xD3 / 255.0, blue: 0xFF / 255.0)
    }

    private var pskPillColor: Color {
        Color(red: 0x7C / 255.0, green: 0x6F / 255.0, blue: 0xFF / 255.0)
    }

    var body: some View {
        ZStack {
            CallMeshBackground()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 32)

                    Text("CHIAMANDO · SECURE CHANNEL ACTIVE")
                        .qaudionStyle(type.labelSmall)
                        .tracking(2.0)
                        .foregroundStyle(extras.success)
                        .padding(.bottom, 36)

                    ZStack {
                        KeyExchangeRing(phase: currentRingPhase, confirmed: ringConfirmed, ringSize: 240)
                        QAudionAvatar(displayName: peerDisplayName,
                                      imageURL: avatarUrl,
                                      size: 160,
                                      shortNumber: peerShortNumber)
                    }
                    .frame(width: 240, height: 240)
                    .padding(.bottom, 24)

                    if let fp = sessionFingerprint {
                        Text(fp)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(ringPQCColorForText)
                            .padding(.bottom, 6)
                    }

                    Text(peerDisplayName)
                        .font(.system(size: 36, weight: .semibold, design: .default))
                        .italic()
                        .foregroundStyle(scheme.onBackground)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 4)

                    Text("Chiamata audio sicura")
                        .qaudionStyle(type.bodyLarge)
                        .italic()
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .padding(.bottom, 20)

                    HStack(spacing: 8) {
                        MetaPill("PQC NEGOTIATING", accent: extras.pqcAccent)
                        MetaPill("VOICE TRUST · ENROLLED", accent: extras.success, filled: true)
                        MetaPill("LOW LATENCY · 48ms", accent: extras.warning)
                        if let method = pskMethodLabel {
                            MetaPill("PSK · \(method)", accent: pskPillColor, filled: true)
                        }
                    }
                    .padding(.bottom, 22)

                    handshakeLog
                        .padding(.horizontal, 4)

                    if let err = errorMessage {
                        errorBanner(err).padding(.top, 12)
                    }

                    Spacer().frame(height: 160) // space for pinned bottom action
                }
                .padding(.horizontal, 24)
            }

            VStack(spacing: 8) {
                Spacer()
                CircularAction(
                    icon: "phone.down.fill",
                    action: onHangup,
                    diameter: 80,
                    background: extras.riskHigh,
                    iconColor: scheme.onPrimary
                )
                .accessibilityLabel("Termina chiamata")
                Text(String(format: "Squillo da %d:%02d", elapsedSeconds / 60, elapsedSeconds % 60))
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(extras.success)
                Spacer().frame(height: 24)
            }
        }
    }

    // MARK: - Handshake log

    private var handshakeLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            handshakeRow("KEM encap generated",
                         done: state == .handshaking || state == .connected || state == .rekeying)
            handshakeRow("PSK matched from vault",
                         done: state == .handshaking || state == .connected || state == .rekeying)
            handshakeRow("HKDF session key derived",
                         done: state == .connected || state == .rekeying)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(scheme.surface.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(extras.pqcAccent.opacity(0.5), lineWidth: 1)
        )
    }

    private func handshakeRow(_ text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(extras.success)
            } else {
                Circle()
                    .stroke(extras.pqcAccent.opacity(0.6), lineWidth: 1.2)
                    .frame(width: 12, height: 12)
            }
            Text(text)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Spacer(minLength: 0)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(extras.riskHigh)
                .padding(.top, 2)
            Text(message)
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 6).fill(extras.riskHigh.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(extras.riskHigh.opacity(0.6), lineWidth: 1))
    }
}

#Preview("Dialing") {
    OutgoingCallScreen(peerDisplayName: "Mario Rossi",
                       state: .dialing,
                       elapsedSeconds: 3,
                       onHangup: {})
        .qAudionTheme(dark: true)
}

#Preview("Handshaking") {
    OutgoingCallScreen(peerDisplayName: "Anna Bianchi",
                       state: .handshaking,
                       elapsedSeconds: 8,
                       onHangup: {})
        .qAudionTheme(dark: true)
}

#Preview("Error") {
    OutgoingCallScreen(peerDisplayName: "Luigi Verdi",
                       state: .ended,
                       elapsedSeconds: 27,
                       errorMessage: "Negoziazione PQC fallita: timeout dopo 25s.",
                       onHangup: {})
        .qAudionTheme(dark: true)
}

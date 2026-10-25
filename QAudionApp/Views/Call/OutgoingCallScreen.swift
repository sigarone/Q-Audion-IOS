import SwiftUI

/// Outgoing-call (ringing) screen. 1:1 visual port of Android
/// `qaudion-android-new/feature/feature-call/.../OutgoingCallScreen.kt`.
///
/// Shown while we are dialing a peer and the PQC handshake is happening
/// in the background. Layout (top → bottom):
///
///   - "CHIAMANDO" header (success, 2.0sp tracking). It says only that the
///     call is being placed: while dialing there is no channel to call secure
///     or active, that is what the handshake log below is for.
///   - 240pt `KeyExchangeRing` (its phase follows `state`) + 160pt avatar circle
///   - session-key fingerprint, only once the real ML-KEM key exists (never
///     the transitional key a call starts with)
///   - peer display name (displaySmall, italic, semibold)
///   - "Chiamata audio" / "Videochiamata" subtitle: the kind of call, nothing
///     about its security, because no channel exists yet. Not shown once the
///     call ended (the kind of call is no longer known there).
///   - `MetaPill`s (PQC NEGOTIATING; the "VOICE TRUST · ENROLLED" and
///     latency pills of the original port are gone: fixed values with no
///     reading behind them)
///   - **Handshake log** — 3 rows that tick from circle → check, each on
///     its own reading:
///        1. "KEM encap generated"           (≥ handshaking: the callee
///                                            acknowledged the offer)
///        2. "PSK matched from vault"        (only when the PSK method label
///                                            exists: the key was found in the
///                                            vault; never from the state)
///        3. "HKDF session key derived"      (connected AND the session-key
///                                            fingerprint exists)
///   - hangup `CircularAction` (riskHigh, 80) + "Ring MM:SS" label
///
/// `state`, `pskMethodLabel` and `sessionFingerprint` drive the handshake
/// checklist, row by row as listed above. `errorMessage` non-nil shows
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
    /// .sessionFingerprintFromKey` — non-nil only once the real ML-KEM
    /// session key exists. The caller must pass nil while the call only
    /// holds the transitional key derived from the pairwise secret at call
    /// start (`CallSessionKeyShown`). Shown as an immediate `Text`, not an
    /// animated reveal; it also decides the third handshake row.
    let sessionFingerprint: String?
    /// True for a video call. Only the line under the name depends on it.
    let isVideo: Bool
    let onHangup: () -> Void

    init(peerDisplayName: String,
         avatarUrl: URL? = nil,
         state: State = .dialing,
         elapsedSeconds: Int = 0,
         errorMessage: String? = nil,
         peerShortNumber: String? = nil,
         pskMethodLabel: String? = nil,
         sessionFingerprint: String? = nil,
         isVideo: Bool = false,
         onHangup: @escaping () -> Void) {
        self.peerDisplayName = peerDisplayName
        self.avatarUrl = avatarUrl
        self.state = state
        self.elapsedSeconds = elapsedSeconds
        self.errorMessage = errorMessage
        self.peerShortNumber = peerShortNumber
        self.pskMethodLabel = pskMethodLabel
        self.sessionFingerprint = sessionFingerprint
        self.isVideo = isVideo
        self.onHangup = onHangup
    }

    /// The line under the name: the kind of call being placed and nothing about
    /// its security, because while dialing there is no channel to call secure.
    private var kindLine: String {
        isVideo
            ? String(localized: "Videochiamata",
                     comment: "Call screens (incoming and outgoing) — line under the name: the kind of call, a video call")
            : String(localized: "Chiamata audio",
                     comment: "Call screens (incoming and outgoing) — line under the name: the kind of call, an audio call")
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

                    // W-CALLERBUSY — the ended state (callee busy / unreachable) no longer claims a secure
                    // channel is being set up.
                    Group {
                        if state == .ended {
                            Text(String(localized: "call.outgoing.header.ended", defaultValue: "CHIAMATA TERMINATA",
                                        comment: "Outgoing call screen header once the call ended before it connected (callee busy or unreachable)"))
                        } else {
                            Text("CHIAMANDO")
                        }
                    }
                        .qaudionStyle(type.labelSmall)
                        .tracking(2.0)
                        .foregroundStyle(state == .ended ? extras.riskHigh : extras.success)
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

                    // W-CALLERBUSY — nothing is negotiating once the call ended before it connected.
                    if state != .ended {
                        // Says what kind of call it is, not that it is secure: nothing is
                        // established yet. Absent on the ended screen, which has no call to
                        // describe (a failed video call would read "Chiamata audio" there).
                        Text(kindLine)
                            .qaudionStyle(type.bodyLarge)
                            .italic()
                            .foregroundStyle(scheme.onSurfaceVariant)
                            .padding(.bottom, 20)

                        HStack(spacing: 8) {
                            MetaPill("PQC NEGOTIATING", accent: extras.pqcAccent)
                            // No "VOICE TRUST · ENROLLED" pill: it was shown on every
                            // outgoing call with no voice reading behind it. Same for the
                            // latency pill: the value it showed was a fixed number.
                            if let method = pskMethodLabel {
                                MetaPill("PSK · \(method)", accent: pskPillColor, filled: true)
                            }
                        }
                        .padding(.bottom, 22)

                        handshakeLog
                            .padding(.horizontal, 4)
                    }

                    if let err = errorMessage {
                        errorBanner(err).padding(.top, 12)
                    }

                    Spacer().frame(height: 160) // space for pinned bottom action
                }
                .padding(.horizontal, 24)
                .qaudionReadableWidth()
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
                .accessibilityLabel(state == .ended
                    ? Text(String(localized: "call.outgoing.dismiss", defaultValue: "Chiudi",
                                  comment: "Accessibility label of the button that closes the outgoing call screen after the call ended (callee busy or unreachable)"))
                    : Text("Termina chiamata"))
                if state != .ended {
                    Text(String(localized: "call.outgoing.ringing_for", defaultValue: "Squillo da \(elapsedSeconds / 60):\(String(format: "%02d", elapsedSeconds % 60))", comment: "Line under the hang-up button of the outgoing call screen. %lld is the minutes, %@ the two-digit seconds of how long it has been ringing."))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(extras.success)
                }
                Spacer().frame(height: 24)
            }
        }
    }

    // MARK: - Handshake log

    /// The first row ("KEM encap generated") follows the call state, which is the only reading the caller has of it:
    /// `.handshaking` is what `ContentView.makeOutgoingScreen` builds for a call that reached ringing, and the caller
    /// enters ringing on the callee's `call_ready`, sent once the callee's ACCEPT (the one carrying the encapsulation)
    /// is on the wire. Before that (`.dialing`, `.ended`) the row stays open.
    static func kemRowDone(state: State) -> Bool {
        state == .handshaking || state == .connected || state == .rekeying
    }

    /// The second row ("PSK matched from vault") is ticked only when a pre-shared key was really matched in the
    /// vault: the method label exists only once the fingerprint of the key mixed into this call was found there
    /// (`AppState.resolvePskDisplayMeta`; it is cleared at the start of every call). The call state says nothing
    /// about it, so it takes no part: a call with no pre-shared key leaves the row open.
    static func pskRowDone(pskMethodLabel: String?) -> Bool {
        guard let label = pskMethodLabel else { return false }
        return !label.isEmpty
    }

    /// The third row ("HKDF session key derived") is ticked only when the call is up AND the fingerprint of the real
    /// ML-KEM key exists. `.connected` alone can come first, while the call still holds the transitional key it
    /// starts with, and that key is not derived by the handshake.
    static func sessionKeyRowDone(state: State, hasFingerprint: Bool) -> Bool {
        (state == .connected || state == .rekeying) && hasFingerprint
    }

    private var handshakeLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            handshakeRow("KEM encap generated",
                         done: Self.kemRowDone(state: state))
            handshakeRow("PSK matched from vault",
                         done: Self.pskRowDone(pskMethodLabel: pskMethodLabel))
            handshakeRow("HKDF session key derived",
                         done: Self.sessionKeyRowDone(state: state, hasFingerprint: sessionFingerprint != nil))
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

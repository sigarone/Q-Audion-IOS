import Foundation
import AVFoundation
import SwiftUI
import UIKit

/// The microphone permission as the app sees it. The raw values are the codes written to the log (`micperm st=<code>`).
enum MicrophonePermissionState: Int, Equatable {
    case undetermined = 0
    case denied = 1
    case granted = 2
}

/// Where a permission check or request came from (`micperm src=<code>` in the log).
enum MicrophonePermissionSource: Int {
    case dial = 1
    case answer = 2
    case foreground = 3
    case banner = 4
    case primer = 5
}

/// What the in-call strip offers while the microphone is not available.
enum MicrophonePermissionBannerKind: Equatable {
    case none
    /// Not asked yet (for instance the call was answered from the lock screen, where no request can be shown).
    case ask
    /// Refused: only the Settings app can change it.
    case openSettings
}

/// The decisions about the microphone permission, as plain values in and plain answers out, so they are tested without a
/// phone or a system prompt.
enum MicrophonePermissionPolicy {

    /// Ask before placing or answering a call: only while the system has not been asked yet and the app is on screen. From
    /// the lock screen, CarPlay or Siri nothing can be shown, so the call goes on and the strip offers the request later.
    static func shouldAskBeforeCall(state: MicrophonePermissionState, appActive: Bool) -> Bool {
        state == .undetermined && appActive
    }

    /// The strip in the call screen: shown during a call for as long as the microphone is not allowed.
    static func bannerKind(state: MicrophonePermissionState, inCall: Bool) -> MicrophonePermissionBannerKind {
        guard inCall else { return .none }
        switch state {
        case .granted: return .none
        case .undetermined: return .ask
        case .denied: return .openSettings
        }
    }

    /// The capture must be started again when the permission arrives while a call is connected (the audio unit that was
    /// opened without it delivers silence for the rest of the call).
    static func shouldRestartCapture(previous: MicrophonePermissionState,
                                     current: MicrophonePermissionState,
                                     inCall: Bool) -> Bool {
        inCall && previous != .granted && current == .granted
    }

    /// The one-time screen before the system request, offered on the home screen: only while the system has not been
    /// asked, outside a call, and once per launch.
    static func shouldOfferPrimer(state: MicrophonePermissionState, inCall: Bool, alreadyOffered: Bool) -> Bool {
        state == .undetermined && !inCall && !alreadyOffered
    }
}

/// Reads and requests the microphone permission and tells the call when it changes. One instance for the app.
@MainActor
final class MicrophonePermissionMonitor: ObservableObject {

    static let shared = MicrophonePermissionMonitor()

    @Published private(set) var state: MicrophonePermissionState
    /// True once the primer was shown in this launch.
    private(set) var primerOffered = false
    /// Bumped when a call starts or ends, so the strip in the call screen redraws at once.
    @Published private(set) var callRevision = 0

    /// Wired by `AppState`: whether a call is live, and what to do when the permission arrives during one.
    var isInCall: () -> Bool = { false }
    var onGrantedDuringCall: () -> Void = {}

    private var requestInFlight = false
    private var observer: NSObjectProtocol?  // the monitor lives as long as the app

    init() {
        state = Self.readSystemState()
        // The user comes back from the Settings app (or from the system request): look again.
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.refresh(source: .foreground)
                // A call answered where no request could be shown (lock screen): the app is on screen now, ask.
                if current == .undetermined, self.isInCall() {
                    await self.requestIfNeeded(source: .foreground)
                }
            }
        }
    }

    nonisolated static func readSystemState() -> MicrophonePermissionState {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            default: return .undetermined
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    /// Reads the system state; restarts the capture when the permission has just arrived during a call.
    @discardableResult
    func refresh(source: MicrophonePermissionSource) -> MicrophonePermissionState {
        let previous = state
        let current = Self.readSystemState()
        state = current
        if previous != current {
            log(current, source)
        }
        if MicrophonePermissionPolicy.shouldRestartCapture(previous: previous, current: current, inCall: isInCall()) {
            RTLog.info("call", "micperm restart=1 src=\(source.rawValue)")
            onGrantedDuringCall()
        }
        return current
    }

    /// Shows the system request when the system has not been asked yet; a decided state is returned as it is.
    @discardableResult
    func requestIfNeeded(source: MicrophonePermissionSource) async -> MicrophonePermissionState {
        guard Self.readSystemState() == .undetermined, !requestInFlight else {
            return refresh(source: source)
        }
        requestInFlight = true
        RTLog.info("call", "micperm ask=1 src=\(source.rawValue)")
        if #available(iOS 17.0, *) {
            _ = await AVAudioApplication.requestRecordPermission()
        } else {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        requestInFlight = false
        return refresh(source: source)
    }

    /// The call is about to start or be answered: ask first when the app is on screen and the system was never asked.
    func askBeforeCallIfNeeded(source: MicrophonePermissionSource) async {
        let current = refresh(source: source)
        let active = UIApplication.shared.applicationState == .active
        if MicrophonePermissionPolicy.shouldAskBeforeCall(state: current, appActive: active) {
            await requestIfNeeded(source: source)
        }
    }

    func callStateChanged() { callRevision &+= 1 }

    func markPrimerOffered() { primerOffered = true }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func log(_ current: MicrophonePermissionState, _ source: MicrophonePermissionSource) {
        RTLog.info("call", "micperm st=\(current.rawValue) src=\(source.rawValue)")
        TelemetryService.shared.emit(
            kind: "call.mic_permission",
            attrs: ["state": current.rawValue, "src": source.rawValue])
    }
}

// MARK: - In-call strip

/// The strip shown in the call screen while the microphone is not allowed: the other side cannot hear this phone.
struct MicrophonePermissionBanner: View {
    @ObservedObject private var monitor = MicrophonePermissionMonitor.shared
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        let kind = MicrophonePermissionPolicy.bannerKind(state: monitor.state, inCall: monitor.isInCall())
        if kind != .none {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(extras.riskHigh)
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "call.mic.banner.title", defaultValue: "Microfono non attivo", comment: "In-call strip title: the microphone permission is missing, so the other person cannot hear you"))
                        .qaudionStyle(type.labelSmall)
                        .foregroundStyle(extras.riskHigh)
                    Text(kind == .ask
                         ? String(localized: "call.mic.banner.ask", defaultValue: "Consenti l'uso del microfono: finché non lo fai, l'altra persona non ti sente.", comment: "In-call strip text: the microphone has not been allowed yet")
                         : String(localized: "call.mic.banner.denied", defaultValue: "L'uso del microfono è disattivato per Q-Audion: l'altra persona non ti sente. Attivalo nelle Impostazioni.", comment: "In-call strip text: the microphone was refused, it can be turned on in the Settings app"))
                        .qaudionStyle(type.labelMedium)
                        .foregroundStyle(scheme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if kind == .ask {
                            Task { await monitor.requestIfNeeded(source: .banner) }
                        } else {
                            monitor.openSettings()
                        }
                    } label: {
                        Text(kind == .ask
                             ? String(localized: "call.mic.banner.allow", defaultValue: "Consenti", comment: "In-call strip button: shows the system microphone request")
                             : String(localized: "call.mic.banner.settings", defaultValue: "Apri Impostazioni", comment: "In-call strip button: opens the Settings app on the Q-Audion page"))
                            .qaudionStyle(type.labelLarge)
                            .foregroundStyle(scheme.onPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(scheme.primary))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(scheme.surfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(extras.riskHigh.opacity(0.6), lineWidth: 1)
                    )
            )
            .accessibilityElement(children: .contain)
            .onAppear { monitor.refresh(source: .foreground) }
        }
    }
}

// MARK: - First-use screen

/// The screen before the system request, offered once the user is signed in and the permission was never asked: one
/// "Continua" that leads to the request, nothing to postpone it.
struct MicrophonePrimerSheet: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    let onContinue: () -> Void
    let busy: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mic.fill")
                .font(.system(size: 56))
                .foregroundStyle(scheme.primary)
            Text(String(localized: "call.mic.primer.title", defaultValue: "Il microfono per le chiamate", comment: "First-use screen title before the system microphone request"))
                .qaudionStyle(type.titleLarge)
                .foregroundStyle(scheme.onSurface)
                .multilineTextAlignment(.center)
            Text(String(localized: "call.mic.primer.body", defaultValue: "Per chiamare e rispondere serve il microfono. Nel prossimo passaggio iOS ti chiederà il permesso: scegli Consenti.", comment: "First-use screen text before the system microphone request"))
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
            Button(action: onContinue) {
                Text("Continua")
                    .qaudionStyle(type.labelLarge)
                    .foregroundStyle(scheme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(scheme.primary))
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .padding(24)
        .background(scheme.background.ignoresSafeArea())
        .interactiveDismissDisabled(true)
    }
}

/// Offers the first-use screen over the home screen.
struct MicrophonePrimerModifier: ViewModifier {
    @ObservedObject private var monitor = MicrophonePermissionMonitor.shared
    @EnvironmentObject private var appState: AppState
    @State private var shown = false
    @State private var busy = false

    func body(content: Content) -> some View {
        content
            .onAppear { evaluate() }
            .onChange(of: appState.isInCall) { inCall in
                // The primer cannot be dismissed by the user and sits over the call cover: a call that goes live
                // (placed or answered) takes it away, and it is not offered again during the call.
                if inCall { shown = false }
                evaluate()
            }
            .sheet(isPresented: $shown) {
                MicrophonePrimerSheet(onContinue: {
                    busy = true
                    Task {
                        await monitor.requestIfNeeded(source: .primer)
                        busy = false
                        shown = false
                    }
                }, busy: busy)
            }
    }

    private func evaluate() {
        let current = monitor.refresh(source: .foreground)
        if MicrophonePermissionPolicy.shouldOfferPrimer(
            state: current, inCall: appState.isInCall, alreadyOffered: monitor.primerOffered) {
            monitor.markPrimerOffered()
            shown = true
        }
    }
}

extension View {
    func microphonePrimer() -> some View { modifier(MicrophonePrimerModifier()) }
}

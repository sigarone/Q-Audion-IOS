import SwiftUI
import QAudionEngine

/// Settings screen for Voice-as-Key: how far the learning of the owner's voice has got, how the feature works, and
/// the reset. The voice is learned by itself during calls; nothing here records or unlocks anything.
struct VoiceKeySettingsScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionType) private var type
    @Environment(\.qaudionSnackbar) private var snackbar

    /// `nil` until the first read; the store is read off the main thread.
    @State private var status: OwnerVoiceLearner.Status?
    @State private var showResetConfirm = false

    // MARK: - Status

    /// Reads the learning state of the signed-in account. The Keychain is touched, so this never runs on the main
    /// thread. No account or an unreadable store reads as not started.
    static func loadStatus() async -> OwnerVoiceLearner.Status {
        await Task.detached(priority: .userInitiated) { () -> OwnerVoiceLearner.Status in
            guard let userId = TokenVault.loadUserId(), !userId.isEmpty else { return .notStarted }
            return OwnerVoiceLearner().status(userId: userId) ?? .notStarted
        }.value
    }

    /// The short line shown under the row in Settings.
    static func shortStatus(_ status: OwnerVoiceLearner.Status) -> String {
        switch status {
        case .notStarted:
            return String(localized: "voicekey.status.not_started", defaultValue: "Si attiva da sola con le tue chiamate", comment: "Settings, Voice-as-Key row subtitle: nothing learned yet")
        case .learning(let percent, _, _):
            return String(localized: "voicekey.status.learning", defaultValue: "In apprendimento · \(percent)%", comment: "Settings, Voice-as-Key row subtitle: learning in progress; the number is a percentage")
        case .active:
            return String(localized: "voicekey.status.active", defaultValue: "Attiva · in affinamento", comment: "Settings, Voice-as-Key row subtitle: on, the model is still improving")
        case .refined:
            return String(localized: "voicekey.status.refined", defaultValue: "Attiva", comment: "Settings, Voice-as-Key row subtitle: on, the model is complete")
        }
    }

    private var current: OwnerVoiceLearner.Status { status ?? .notStarted }

    private var cardTitle: String {
        switch current {
        case .notStarted:
            return String(localized: "voicekey.card.title.not_started", defaultValue: "Non ancora attiva", comment: "Voice-as-Key screen, status card title: not on yet")
        case .learning:
            return String(localized: "voicekey.card.title.learning", defaultValue: "In apprendimento", comment: "Voice-as-Key screen, status card title: learning the voice")
        case .active, .refined:
            return String(localized: "voicekey.card.title.active", defaultValue: "Attiva", comment: "Voice-as-Key screen, status card title: on")
        }
    }

    private var cardBody: String {
        switch current {
        case .notStarted:
            return String(localized: "voicekey.card.body.not_started", defaultValue: "Comincia a imparare la tua voce dalla prossima chiamata in cui parli.", comment: "Voice-as-Key screen, status card text: nothing learned yet")
        case .learning:
            let calls = OwnerVoiceLearning.minDistinctCalls
            let seconds = OwnerVoiceLearning.minNetSpeechMs / 1000
            return String(localized: "voicekey.card.body.learning", defaultValue: "Si attiva dopo almeno \(calls) chiamate, con circa \(seconds) secondi di voce in tutto.", comment: "Voice-as-Key screen, status card text: what turns it on; first number is a count of calls, second a count of seconds")
        case .active:
            return String(localized: "voicekey.card.body.active", defaultValue: "La tua voce viene riconosciuta. Il modello continua a migliorare nelle prossime chiamate.", comment: "Voice-as-Key screen, status card text: on and still improving")
        case .refined:
            return String(localized: "voicekey.card.body.refined", defaultValue: "Il modello della tua voce è completo: l'app non raccoglie più campioni.", comment: "Voice-as-Key screen, status card text: model complete")
        }
    }

    /// Bar fill in `0...1` and its caption; only while learning or improving.
    private var progress: (fraction: Double, caption: String)? {
        switch current {
        case .learning(let percent, let calls, let seconds):
            let minCalls = OwnerVoiceLearning.minDistinctCalls
            let minSeconds = OwnerVoiceLearning.minNetSpeechMs / 1000
            return (Double(percent) / 100,
                    String(localized: "voicekey.card.progress.learning", defaultValue: "\(calls) di \(minCalls) chiamate · \(seconds) di \(minSeconds) secondi di voce", comment: "Voice-as-Key screen, progress line while learning: calls so far of the calls needed, then seconds of voice so far of the seconds needed"))
        case .active(let percent):
            return (Double(percent) / 100,
                    String(localized: "voicekey.card.progress.active", defaultValue: "Affinamento \(percent)%", comment: "Voice-as-Key screen, progress line once on: percentage of the improvement reached"))
        case .notStarted, .refined:
            return nil
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusCard
                        .padding(.top, 16)

                    SettingsSectionHeader(String(localized: "voicekey.how.header", defaultValue: "Come funziona", comment: "Voice-as-Key screen, section header: how the feature works").uppercased())

                    VStack(spacing: 8) {
                        infoItem(
                            String(localized: "voicekey.how.learns.title", defaultValue: "Impara da sola", comment: "Voice-as-Key screen, item title: it learns by itself"),
                            String(localized: "voicekey.how.learns.body", defaultValue: "Durante le chiamate l'app usa solo il tuo microfono e, nei momenti in cui parli, ricava un modello numerico della tua voce. Non devi registrare niente: dopo un paio di chiamate la Voice-as-Key si attiva, poi continua ad affinarsi per qualche giorno.", comment: "Voice-as-Key screen, item text: learning happens by itself from the own microphone during calls"))
                        infoItem(
                            String(localized: "voicekey.how.sees.title", defaultValue: "Cosa vede il tuo contatto", comment: "Voice-as-Key screen, item title: what the contact sees"),
                            String(localized: "voicekey.how.sees.body", defaultValue: "In chiamata il tuo telefono confronta la voce che parla nel microfono con il tuo modello e manda al contatto solo l'esito, cifrato end-to-end. Nella schermata della chiamata il contatto vede uno scudo con il microfono: verde finché la voce corrisponde, viola se il confronto è incerto, rosso se sta parlando un'altra persona, per esempio perché il telefono è passato in altre mani. Tu vedi lo stesso scudo per i contatti che hanno la Voice-as-Key attiva.", comment: "Voice-as-Key screen, item text: the result of the comparison is sent to the contact and shown as a shield with a microphone in three colours"))
                        infoItem(
                            String(localized: "voicekey.how.limits.title", defaultValue: "Cosa non fa", comment: "Voice-as-Key screen, item title: what it does not do"),
                            String(localized: "voicekey.how.limits.body", defaultValue: "È un segnale in più, non una prova: una voce si può imitare o registrare. Non sblocca l'app e non sostituisce la cifratura né la verifica dell'identità (SAS).", comment: "Voice-as-Key screen, item text: an extra signal, not proof; it unlocks nothing; SAS is the short authentication string"))
                        infoItem(
                            String(localized: "voicekey.how.privacy.title", defaultValue: "Privacy", comment: "Voice-as-Key screen, item title: privacy"),
                            String(localized: "voicekey.how.privacy.body", defaultValue: "Il modello resta solo su questo dispositivo, cifrato, e non viene mai inviato al server né ai contatti. L'audio delle chiamate non viene salvato: per imparare si conservano solo valori numerici ricavati dalla voce, mai la voce stessa.", comment: "Voice-as-Key screen, item text: the model stays on the device; no audio is stored"))
                    }

                    if status != nil, current != .notStarted {
                        resetSection
                    }

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(String(localized: "voicekey.title", defaultValue: "Voice-as-Key", comment: "Voice-as-Key screen, navigation title"))
        .task { status = await Self.loadStatus() }
    }

    // MARK: - Pieces

    private var cardShape: some Shape { RoundedRectangle(cornerRadius: 12) }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: cardTitle)
                .qaudionStyle(type.titleMedium)
                .foregroundStyle(scheme.onSurface)
            Text(verbatim: cardBody)
                .qaudionStyle(type.bodyMedium)
                .foregroundStyle(scheme.onSurfaceVariant)
            if let progress {
                ProgressView(value: min(max(progress.fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(scheme.primary)
                    .padding(.top, 4)
                Text(verbatim: progress.caption)
                    .qaudionStyle(type.labelSmall)
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardShape.fill(scheme.surfaceVariant.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }

    private func infoItem(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .qaudionStyle(type.bodyMedium)
                .fontWeight(.semibold)
                .foregroundStyle(scheme.onSurface)
            Text(verbatim: text)
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardShape.fill(scheme.surfaceVariant.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: String(localized: "voicekey.reset.hint", defaultValue: "Se l'app ha imparato una voce sbagliata, per esempio quella di chi ti stava vicino o di chi ha usato il tuo telefono, reimpostala: ricomincerà a imparare dalle prossime chiamate.", comment: "Voice-as-Key screen, text above the reset button"))
                .qaudionStyle(type.labelSmall)
                .foregroundStyle(scheme.onSurfaceVariant)
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Text(verbatim: String(localized: "voicekey.reset.button", defaultValue: "Reimposta Voice-as-Key", comment: "Voice-as-Key screen, destructive button that deletes the learned voice model"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            // Anchored to the button so the iPad popover points at it.
            .confirmationDialog(
                String(localized: "voicekey.reset.confirm.title", defaultValue: "Reimpostare Voice-as-Key?", comment: "Voice-as-Key screen, reset confirmation title"),
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "voicekey.reset.confirm.ok", defaultValue: "Reimposta", comment: "Voice-as-Key screen, destructive confirm button of the reset"), role: .destructive) {
                    Task { await reset() }
                }
                Button("Annulla", role: .cancel) { }
            } message: {
                Text(verbatim: String(localized: "voicekey.reset.confirm.message", defaultValue: "Il modello vocale salvato su questo dispositivo viene cancellato. La tua voce verrà imparata di nuovo in automatico durante le chiamate.", comment: "Voice-as-Key screen, reset confirmation message"))
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Reset

    private func reset() async {
        // The template and everything the learning kept: a window of the wrong voice must not come back.
        let done = await Task.detached(priority: .userInitiated) { OwnerVoiceLearner().reset() }.value
        status = await Self.loadStatus()
        if done {
            snackbar?.show(.init(
                text: String(localized: "voicekey.reset.done", defaultValue: "Voice-as-Key reimpostata.", comment: "Voice-as-Key screen, snackbar after the reset"),
                severity: .info,
                durationSeconds: 3))
        }
    }
}

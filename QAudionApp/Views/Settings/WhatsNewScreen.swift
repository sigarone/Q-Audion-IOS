import SwiftUI
import QAudionEngine

/// W49: "Cosa c'è di nuovo" — changelog viewer per i tester TestFlight.
/// Hardcoded list di release entries (tag + data + bullet di feature)
/// così non serve un fetch network e non c'è dipendenza dall'engine.
/// Pensato per essere aggiornato manualmente a ogni tag — l'autore della
/// release deve aggiungere un nuovo `ReleaseNote` in `releaseNotes` qui
/// sotto. Non sostituisce l'OTA catalog (W42), che gestisce release
/// firmate Ed25519; questo è puramente informativo.
public struct ReleaseNote: Identifiable, Equatable {
    public let id: String   // tag, es. "v1.0.96"
    public let date: String // ISO short, es. "2026-04-30"
    public let title: String
    public let bullets: [String]

    public init(id: String, date: String, title: String, bullets: [String]) {
        self.id = id; self.date = date; self.title = title; self.bullets = bullets
    }
}

extension ReleaseNote {
    /// Hardcoded changelog. Più recenti in alto. Aggiornare a ogni tag.
    public static let releaseNotes: [ReleaseNote] = [
        .init(id: "v1.0.264", date: "2026-05-02",
              title: "STATO SISTEMA section in About (W264)",
              bullets: [
                "About: nuova sezione 'STATO SISTEMA'",
                "Uptime processo (real timer da launch)",
                "Stato termico (Normale / Tiepido / Caldo / Critico)",
                "Numero di core CPU disponibili",
                "Utile per QA che indaga calo di qualità in chiamate lunghe (thermal)"
              ]),
        .init(id: "v1.0.263", date: "2026-05-02",
              title: "Clear delivered notifications dev action (W263)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Cancella notifiche consegnate'",
                "Svuota il cassetto notifiche di iOS (UNUserNotificationCenter)",
                "Sister di 'Pulisci badge' (W166) — usate insieme per QA pulito"
              ]),
        .init(id: "v1.0.262", date: "2026-05-02",
              title: "🎉 Type-checker beat — fix real API mismatch (W262)",
              bullets: [
                "v1.0.261 structural fixes WORKED — type-checker is no longer choking",
                "Build now reports a REAL Swift error, not a timeout",
                "MessageComposer struct had `recordingElapsedSeconds` property but init didn't accept it",
                "Fix: add `recordingElapsedSeconds: TimeInterval = 0` to init signature",
                "First non-timeout failure since v1.0.225 — diagnostic infrastructure won"
              ]),
        .init(id: "v1.0.261", date: "2026-05-02",
              title: "Wrap MessageComposer in computed property (W261)",
              bullets: [
                "v1.0.260 still failed — error moved up to MessageComposer( call site",
                "Even with all closures method-extracted, 14-arg struct construction was too much",
                "Fix: wrap the entire MessageComposer(...) in @ViewBuilder computed property",
                "The body's ZStack now sees a single `composerView` reference",
                "Computed properties have isolated type-check scope from the parent ViewBuilder"
              ]),
        .init(id: "v1.0.260", date: "2026-05-01",
              title: "Extract composer Binding(set:) + scroll callbacks (W260)",
              bullets: [
                "v1.0.259 worked — error moved past photos to line 112 composer Binding",
                "Same fix: extracted `Binding(set:)` body to handleComposerTextChange method",
                "Preemptively flattened scroll-to-bottom .onChange closures with guard let",
                "`if let last = ... { withAnimation { ... } }` is the same antipattern",
                "All inline closures in ChatDetailScreen body are now method-bound or trivial"
              ]),
        .init(id: "v1.0.259", date: "2026-05-01",
              title: "Extract photo-picker callback to methods (W259)",
              bullets: [
                "v1.0.258 voice-note fix worked — error moved to multi-photo callback",
                "Same antipattern: closure → Task → for → if → MainActor.run + interpolation",
                "Same structural fix: extract closure body to instance methods",
                "Snackbar interpolation moved to a static helper (single-overload, fast)",
                "All inline closure bodies in ChatDetailScreen.swift now ≤ 1-2 levels deep"
              ]),
        .init(id: "v1.0.258", date: "2026-05-01",
              title: "Extract voice-note callbacks to methods (W258)",
              bullets: [
                "v1.0.257 still failed — even `container.markFailed(...)` timed out",
                "Root cause: 4-5 levels of closure depth exhausts the type-checker",
                "Structural fix: extract closure bodies into named methods",
                "Methods have a clean type-check scope, isolated from closure constraints",
                "Pattern: `onStartVoiceNote: handleVoiceNoteStart` (no inline { ... })",
                "CLAUDE.md §13 updated with this 5th and final antipattern variant"
              ]),
        .init(id: "v1.0.256", date: "2026-05-01",
              title: "Drop debug prints in voice-note callbacks (W256)",
              bullets: [
                "Even `let line: String = \"...\" + errMsg` (both sides typed) times out",
                "The `+` operator has too many overloads to resolve in nested closures",
                "Pragmatic fix: drop the diagnostic prints entirely — they were debug-only",
                "Pre-emptive: also dropped the 5-segment concat in onFinishVoiceNote",
                "Production uses os_log anyway; debug `print` is not load-bearing",
                "CLAUDE.md §13 updated with this 4th type-checker antipattern variant"
              ]),
        .init(id: "v1.0.255", date: "2026-05-01",
              title: "Fix type-checker timeout #3 — String(Int) overload trap (W255)",
              bullets: [
                "ChatDetailScreen.swift:175 — `String(rec.durationMs)` (Int) also times out",
                "Root cause: String(_:) has many numeric overloads (Int, UInt, Double, …)",
                "Fix: switch to String(describing:) which has a single overload",
                "CLAUDE.md §13 updated with this 3rd type-checker antipattern variant"
              ]),
        .init(id: "v1.0.253", date: "2026-05-01",
              title: "Fix type-checker timeout #2 in ChatDetailScreen (W253)",
              bullets: [
                "ChatDetailScreen.swift:151 — print(\"...\" + errMsg) still tripped the type-checker",
                "Even with errMsg pre-bound, the `+` operator inside `print(...)` was the problem",
                "`print` has many overloads (variadic / separator / terminator / to:&Output)",
                "Fix: build full line into a local String, then `print(line)`",
                "Same pattern as onFinishVoiceNote (lines 169-175) — now consistent"
              ]),
        .init(id: "v1.0.252", date: "2026-05-01",
              title: "Quick-copy build identifier in About (W179)",
              bullets: [
                "About → ASSISTENZA: nuovo bottone 'Copia diagnostica rapida'",
                "Copia in clipboard: versione · build · dispositivo · iOS",
                "Sister di 'Contatta supporto' — stesso payload, transport diverso",
                "Useful per Slack/Discord/issue trackers senza aprire Mail"
              ]),
        .init(id: "v1.0.251", date: "2026-05-01",
              title: "Fix type-checker timeout in ChatDetailScreen (W251)",
              bullets: [
                "ChatDetailScreen.swift:197 W38 send-failure snackbar — multi-segment interpolation `\\(reason.localizedDescription)` triggered Swift 6 / Xcode 26.4 type-checker timeout",
                "Fix: pre-bind reason.localizedDescription to local + use String + concatenation",
                "Same defensive treatment applied to typingRow (peer display-name chain)",
                "Cross-references CLAUDE.md §13 — type-checker traps documented in W174"
              ]),
        .init(id: "v1.0.241–249", date: "2026-05-01",
              title: "QA toolkit polish + CI diagnostics (W170–W177)",
              bullets: [
                "About → PIATTAFORMA: dispositivo + iOS in uso (W170)",
                "Notifiche → DIAGNOSTICA: invio notifica di test (W171)",
                "Footnote copyright sotto la versione (W172)",
                "About → ASSISTENZA: contatta supporto via mail (W173)",
                "CLAUDE.md: documentazione type-checker traps (W174)",
                "CI: profiling flags compile-time per surfacciare bottleneck (W175)",
                "CI: re-print diag.log all'inizio di Step 7 per visibilità (W177)"
              ]),
        .init(id: "v1.0.232–238", date: "2026-05-01",
              title: "Diagnostica e dev tools (W162–W167)",
              bullets: [
                "About: 'Build installato N giorni fa' (W162)",
                "Settings → SVILUPPATORE: Reset metadati locali (W163)",
                "Diagnostic export: conta abbozzi · ultimo accesso · build seen (W164)",
                "Conferma prima di Svuota cache allegati (W165)",
                "Pulisci badge notifiche dev action (W166)",
                "About → CONNESSIONE: stato WS live + autenticato (W167)"
              ]),
        .init(id: "v1.0.220–231", date: "2026-05-01",
              title: "Privacy & polish marathon (W137–W160)",
              bullets: [
                "Abbozzi composer persistenti per chat (W137) + indicatore \"Bozza:\" (W138)",
                "Esporta chat in .txt via share sheet (W139)",
                "Swipe \"Segna letto\" e azioni di contesto sulla lista (W140)",
                "Finestra modifica messaggi 15 minuti (W141)",
                "\"Ultimo accesso\" del peer in topbar chat (W142)",
                "Banner E2E nelle chat vuote (W143)",
                "Velocità voice-note persistente tra sessioni (W144)",
                "Conferma prima di Elimina/Svuota/Esci (W145, W147, W151)",
                "Conteggio non letti nel titolo \"Chat (N)\" (W146)",
                "Markdown inline `code` / **bold** / *italic* nei bubble (W148, W149)",
                "Cancella abbozzi + ultimo accesso da Settings (W150, W153)",
                "Toggle privacy: anteprima link (W152), abbozzi nella lista (W155), vibrazione (W160)",
                "Tap-to-copy versione + ID utente (W156, W157)",
                "About: \"Membro da\" + dati locali (conversazioni, messaggi, abbozzi) (W158, W159)"
              ]),
        .init(id: "v1.0.96", date: "2026-04-30",
              title: "QA toolkit completata",
              bullets: [
                "Esporta diagnostica — text dump shareable con build, device, state (no token leak)",
                "Sister di Reset dati locali (v1.0.94) per workflow QA TestFlight"
              ]),
        .init(id: "v1.0.95", date: "2026-04-30",
              title: "CallHistory gesture",
              bullets: [
                "Swipe-trailing su una chiamata → Elimina (gesto Mail/Messages canonico)",
                "Overflow menu nel topBar → Cancella storico con alert di conferma + count"
              ]),
        .init(id: "v1.0.94", date: "2026-04-30",
              title: "Reset dati locali",
              bullets: [
                "Settings → SVILUPPATORE → Reset dati locali",
                "Wipe di 8 chiavi UserDefaults non-credenziale (numeri, opt-in beta, banner)",
                "Auth token / device id preservati (logout esplicito separato)"
              ]),
        .init(id: "v1.0.93", date: "2026-04-30",
              title: "Group composer real",
              bullets: [
                "FAB \"Nuovo gruppo\" nella tab Chiamate ora apre il vero CreateGroupScreen",
                "Rimosso lo stub \"W40 in arrivo\" (W40 è già live da v1.0.86)"
              ]),
        .init(id: "v1.0.92", date: "2026-04-30",
              title: "I miei numeri (multi-phone)",
              bullets: [
                "Settings → ACCOUNT → I miei numeri",
                "Multipli E.164 attaccati allo stesso account (peppered hash)",
                "Validazione E.164 client-side via PhoneHashHelper"
              ]),
        .init(id: "v1.0.91", date: "2026-04-29",
              title: "Hotfix critico + W42 + W43 + W39.polish",
              bullets: [
                "FIX: HomeView mancava `}` su callsTab — sbloccato build TestFlight",
                "FIX: FastSetup login E.164 double-hash — `loginWithPhoneHash` bypass",
                "Aggiornamento OTA stub UI in Settings → INFO",
                "Simulatore rete (dev) in Settings → SVILUPPATORE",
                "CallHistory encapsulation polish"
              ]),
        .init(id: "v1.0.86–88", date: "2026-04-28",
              title: "Group Chat trio + DeviceManagement",
              bullets: [
                "CreateGroupScreen + GroupChatScreen + GroupInfoScreen (W40)",
                "DeviceManagementScreen enhanced + LinkNewDeviceScreen X25519",
                "BubbleActionSheet snackbar feedback per le 4 azioni chat"
              ]),
        .init(id: "v1.0.66–85", date: "2026-04-26",
              title: "Cross-platform parity track A",
              bullets: [
                "ChatListScreen sectioned (W19) — 1:1 con Android",
                "ContactsScreen W23 — TUTTI / SCOPRI / BLOCCATI",
                "SettingsScreen W24 — ProfileHero + SecurityChips + 6 sezioni",
                "CallHistoryView W39 — call-history list",
                "Onboarding stack — Splash + Welcome + PhoneEntry + VoiceEnrollment + FastSetup"
              ]),
    ]
}

struct WhatsNewScreen: View {
    @Environment(\.qaudionScheme) private var scheme
    @Environment(\.qaudionExtras) private var extras
    @Environment(\.qaudionType) private var type

    var body: some View {
        ZStack {
            scheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    intro
                    ForEach(ReleaseNote.releaseNotes) { note in
                        releaseCard(note)
                    }
                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
        .navigationTitle("Cosa c'è di nuovo")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CHANGELOG")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(scheme.primary)
            Text("Lista delle ultime release TestFlight con i cambiamenti principali. Aggiornata manualmente a ogni tag — la versione canonica del changelog vive nel repository git su `feature/ios-android-parity`.")
                .qaudionStyle(type.bodySmall)
                .foregroundStyle(scheme.onSurface)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
    }

    // MARK: - Release card

    private func releaseCard(_ note: ReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.id)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(scheme.onSurface)
                Spacer(minLength: 0)
                Text(note.date)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(scheme.onSurfaceVariant)
            }
            Text(note.title)
                .qaudionStyle(type.titleSmall)
                .fontWeight(.semibold)
                .foregroundStyle(scheme.primary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(note.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(scheme.primary)
                        Text(bullet)
                            .qaudionStyle(type.bodySmall)
                            .foregroundStyle(scheme.onSurface)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(scheme.surfaceVariant.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(scheme.outline.opacity(0.4), lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack {
        WhatsNewScreen()
    }
    .qAudionTheme(dark: true)
}

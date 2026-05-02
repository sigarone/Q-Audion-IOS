import Foundation

// W302: extracted from WhatsNewScreen.swift to keep the changelog data
// out of the View file. WhatsNewScreen.swift was approaching 600 lines
// (TODO_AUDIT.md §6) which puts it in the Xcode 26.4 type-checker
// danger zone for any future @ViewBuilder additions.
//
// Future release entries: prepend a new `.init(...)` to the array
// below. Both files live in the same target so the extension binds
// to the `ReleaseNote` struct declared in WhatsNewScreen.swift.

extension ReleaseNote {
    /// Hardcoded changelog. Più recenti in alto. Aggiornare a ogni tag.
    public static let releaseNotes: [ReleaseNote] = [
        .init(id: "v1.0.307", date: "2026-05-02",
              title: "Audit §3 stub-UI sweep — InCall + Bubble (W323-W325)",
              bullets: [
                "InCallScreen (W323): 'DEMO' capsule badge quando keyInfo == nil",
                "LiveInCallScreen (W324): 'REKEY DEMO' overlay + extract InCallScreen call",
                "BubbleActionSheet (W325): disabled '+' ora flash tooltip 'Picker emoji in arrivo'",
                "TUTTE le 16 §3 stub UIs ora polished",
                "Audit §3 100% closed"
              ]),
        .init(id: "v1.0.306", date: "2026-05-02",
              title: "Refresh TODO_AUDIT.md scoreboard",
              bullets: [
                "Updated audit progress matrix",
                "§3 stub UIs: 13/16 → 16/16 dopo W323-W325"
              ]),
        .init(id: "v1.0.305", date: "2026-05-02",
              title: "Audit §3 stub-UI sweep batch — onboarding (W314-W316)",
              bullets: [
                "WelcomeScreen (W314): 'Funzione in arrivo' italic disclaimers sotto i CTA stub",
                "PhoneEntryScreen (W315): timestamp 'Ultimo tentativo HH:mm:ss' dopo Continue",
                "LinkNewDeviceScreen (W316): tap-to-copy fingerprint + disclaimer pairing",
                "Tutto via static helpers, type-checker safe (SWIFT6_PATTERNS rules)",
                "3 stub UIs polished — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.304", date: "2026-05-02",
              title: "Audit §3 stub-UI sweep batch — group screens (W319-W322)",
              bullets: [
                "CreateGroupScreen (W319): 'N selezionati su M' counter live",
                "GroupChatScreen (W320): long-press titolo → copy group UUID + snackbar",
                "GroupInfoScreen (W321): 'Aggiornato N minuti fa' relative timestamp",
                "GroupCallScreen (W322): 'N in linea' capsule badge in titolo",
                "4 stub UIs polished — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.303", date: "2026-05-02",
              title: "NetworkSimulator: stub disclaimer (W317)",
              bullets: [
                "Settings → Simulatore rete: aggiunto disclaimer '⚠️ stub UI'",
                "Esplicito che il packet shaper non agisce sul transport",
                "Evita confusione QA: 'perché non funziona?'",
                "Sister polish dei W295/W303 — UX wins su stub UIs"
              ]),
        .init(id: "v1.0.302", date: "2026-05-02",
              title: "Pin xcode 26.4 in codemagic.yaml (W313)",
              bullets: [
                "codemagic.yaml: 'xcode: latest' → 'xcode: 26.4' (entrambi i workflow)",
                "Latest resolveva già a 26.4.1 — pin per reproducibilità",
                "Soddisfa Apple ITMS-90725 deadline (April 28, 2026)",
                "Audit §1 critical item DONE (Xcode 26 deadline)"
              ]),
        .init(id: "v1.0.301", date: "2026-05-02",
              title: "Estratto SWIFT6_PATTERNS.md (W312)",
              bullets: [
                "Nuovo: SWIFT6_PATTERNS.md nel root del repo",
                "Estratto da CLAUDE.md §13 (W174-W258 saga)",
                "Reference stabile per agenti che lavoreranno su Q-Audion iOS",
                "Audit §6 hygiene progress (3 of ~3)"
              ]),
        .init(id: "v1.0.300", date: "2026-05-02",
              title: "🎉 v1.0.300 milestone — STATISTICHE section in About (W311)",
              bullets: [
                "300ª release! About guadagna una sezione 'STATISTICHE'",
                "Conta release nel changelog (≥300 entries)",
                "Giorni dall'installazione (da W158 'Membro da')",
                "Build distinte launciate (da W162 buildSeen stamps)",
                "Reads cheap, recomputed on render"
              ]),
        .init(id: "v1.0.299", date: "2026-05-02",
              title: "WhatsNew: 'Esporta come testo' share button (W310)",
              bullets: [
                "'Cosa c'è di nuovo': toolbar share button → export .txt",
                "Genera plain-text con header '## v1.0.X — date' + bullet list",
                "Rispetta il filtro 'Solo ultime 5' (esporta solo visibili)",
                "Sheet con UIActivityViewController (Mail · Messages · Files)",
                "Utile per condividere release log fuori dall'app"
              ]),
        .init(id: "v1.0.298", date: "2026-05-02",
              title: "Shared TapCopyRow component (W309)",
              bullets: [
                "Nuovo: DesignSystem/Components/TapCopyRow.swift",
                "Promuove il pattern W297/W307/W308 in un componente condiviso",
                "Pure additive — i 3 helper per-file restano invariati per ora",
                "Future tap-to-copy possono usare il componente condiviso",
                "Hygiene: §6 audit progress (DRY refactor)"
              ]),
        .init(id: "v1.0.297", date: "2026-05-02",
              title: "Backup: Cifratura tap-to-copy (W308)",
              bullets: [
                "Settings → Backup: 'Cifratura' tap-to-copy",
                "QAUD/AES-256-GCM è il valore più chiesto in security audit",
                "tapCopyRow helper estesi a 3 file (About, Account, Backup)"
              ]),
        .init(id: "v1.0.296", date: "2026-05-02",
              title: "Account: User ID + Phone Hash tap-to-copy (W307)",
              bullets: [
                "Account → IDENTITÀ: 'User ID' e 'Phone Hash' tap-to-copy",
                "Sister di W297/W298 (About) — stesso pattern",
                "Clipboard icon + haptic feedback alla copia",
                "I valori più richiesti in bug-report cross-device"
              ]),
        .init(id: "v1.0.295", date: "2026-05-02",
              title: "Backup: 'Backup stimato' size preview (W306)",
              bullets: [
                "Settings → Backup: nuova riga 'Backup stimato'",
                "Stima byte di conv list + messaggi + abbozzi da UserDefaults",
                "Formattato via ByteCountFormatter (KB / MB)",
                "Tester sa al volo se il backup sarà piccolo o pesante"
              ]),
        .init(id: "v1.0.294", date: "2026-05-02",
              title: "Idiom row in About → PIATTAFORMA (W305)",
              bullets: [
                "About → PIATTAFORMA: nuova riga 'Idiom'",
                "Distingue iPhone / iPad / Mac (Catalyst) / TV / CarPlay",
                "QA può capire al volo se un layout bug è phone o pad",
                "Default fallback per .vision (iOS 17+) e cases futuri"
              ]),
        .init(id: "v1.0.293", date: "2026-05-02",
              title: "OtaUpdate: 'Ultimo controllo N minuti fa' (W304)",
              bullets: [
                "Aggiornamento OTA: timestamp 'Ultimo controllo N minuti fa'",
                "Stamped a ogni check() (anche errori)",
                "Sister di W295 / W303 — pattern relativo it_IT",
                "Stub UI polish — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.292", date: "2026-05-02",
              title: "DeviceManagement: 'Aggiornato N minuti fa' (W303)",
              bullets: [
                "Settings → Dispositivi: timestamp 'Aggiornato N minuti fa'",
                "Stamped al construct + dopo ogni refresh()",
                "Sister di W295 (MyPhones) — pattern relativo it_IT",
                "Stub UI polish — TODO_AUDIT.md §3 progress"
              ]),
        .init(id: "v1.0.291", date: "2026-05-02",
              title: "Split WhatsNew data → WhatsNewData.swift (W302)",
              bullets: [
                "WhatsNewScreen.swift era ~580 linee — danger zone type-checker",
                "Estratto extension ReleaseNote { releaseNotes: [...] } in nuovo file",
                "WhatsNewData.swift: solo i dati. WhatsNewScreen.swift: solo la View",
                "Stesso target → l'extension binda al ReleaseNote esistente",
                "Future entry vanno SOLO in WhatsNewData.swift (TODO_AUDIT.md §6)"
              ]),
        .init(id: "v1.0.290", date: "2026-05-02",
              title: "WhatsNew: toggle 'Solo ultime 5' (W301)",
              bullets: [
                "'Cosa c'è di nuovo': nuovo toggle in cima 'Solo ultime 5'",
                "Filtra a `releaseNotes.prefix(5)` quando attivo",
                "Riduce lo scroll dopo 50+ release shipped",
                "Stato @State scoped alla schermata, non persiste"
              ]),
        .init(id: "v1.0.289", date: "2026-05-02",
              title: "Riga 'Regione' in About → STATO SISTEMA (W300)",
              bullets: [
                "About → STATO SISTEMA: 'Regione' (es. 'IT', 'CH', 'US')",
                "Distinta dalla 'Lingua sistema' (W269)",
                "Locale.current.region.identifier con fallback iOS 15-",
                "Utile per debug 'it_CH' — italiano + regione Svizzera"
              ]),
        .init(id: "v1.0.288", date: "2026-05-02",
              title: "Showcase aptico 6 pattern in DIAGNOSTICA (W299)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Showcase aptico'",
                "Fa scattare i 6 pattern HapticFeedback in sequenza",
                "Sent · Start · Stop · Reaction · Destructive · Failure",
                "Tester può distinguere ogni pattern singolarmente (gap 0.5s)"
              ]),
        .init(id: "v1.0.287", date: "2026-05-02",
              title: "Estendi tap-to-copy a Bundle name/id + vendor ID (W298)",
              bullets: [
                "About → VERSIONE: 'Bundle name' e 'Bundle id' tap-to-copy",
                "About → DATI LOCALI: 'ID dispositivo (vendor)' tap-to-copy",
                "Stessa pattern di W297 (Commit) — clipboard + haptic",
                "I 4 metadati più copiati nei bug report ora copy-out 1 tap"
              ]),
        .init(id: "v1.0.286", date: "2026-05-02",
              title: "Tap-to-copy commit row in About (W297)",
              bullets: [
                "About → VERSIONE: tap sulla riga 'Commit' copia il SHA",
                "Icona doc.on.clipboard a destra telegrafa il gesto",
                "Haptic feedback alla copia (HapticFeedback.messageSent)",
                "Sister di W156/W157 — pattern tap-to-copy per metadata"
              ]),
        .init(id: "v1.0.285", date: "2026-05-02",
              title: "CallHistory: filtro 'Solo perse' (W296)",
              bullets: [
                "Schermata Chiamate: nuovo toggle 'Solo perse' in cima alla lista",
                "Mostra il count visibile vs totale (es. '3 di 12')",
                "Filtraggio reattivo, scopo session (non persiste)",
                "Riduce il triage per chi cerca solo le chiamate perse"
              ]),
        .init(id: "v1.0.284", date: "2026-05-02",
              title: "MyPhones: 'Aggiornato N minuti fa' (W295)",
              bullets: [
                "Settings → I miei numeri: timestamp 'Aggiornato N minuti fa'",
                "Stamped quando l'utente preme 'Salva' (UserDefaults)",
                "RelativeDateTimeFormatter con locale 'it_IT'",
                "Visivo che le modifiche sono state effettivamente persistite"
              ]),
        .init(id: "v1.0.283", date: "2026-05-02",
              title: "Wire 'Apri chat' su ContactDetail (W294)",
              bullets: [
                "ContactDetail action 'Chat': era TODO no-op, ora reagisce",
                "Dismiss della scheda + snackbar guida 'Apri da Chat'",
                "Soluzione interim — deep-link reale richiede nav coordinator globale",
                "Rimane in TODO_AUDIT.md §2.3 per il fix definitivo"
              ]),
        .init(id: "v1.0.282", date: "2026-05-02",
              title: "Wire admin banner CTA URL (W293)",
              bullets: [
                "ChatListScreen admin banner: era TODO no-op, ora apre URL",
                "Esteso AdminBannerData con `ctaURL: URL?` opzionale",
                "Tap del CTA → UIApplication.shared.open(url) se URL presente",
                "Wired un altro TODO(engine) dall'audit (TODO_AUDIT.md §2.2)"
              ]),
        .init(id: "v1.0.281", date: "2026-05-02",
              title: "Settings top-bar Menu — wired engine TODO (W292)",
              bullets: [
                "Settings → top-bar `⋯`: era TODO no-op, ora Menu funzionante",
                "Quick actions: Copia versione · Impostazioni iOS · Feedback TF",
                "Wired uno dei TODO(engine) dall'audit (TODO_AUDIT.md §2.4)",
                "Ogni voce è side-effect-only — nessuna nuova navigation state"
              ]),
        .init(id: "v1.0.280", date: "2026-05-02",
              title: "Bundle metadata + GitHub tags link (W290/W291)",
              bullets: [
                "About → VERSIONE: 'Bundle name' + 'Bundle id' (W290)",
                "Surface CFBundleName + CFBundleIdentifier per QA",
                "About → ASSISTENZA: 'Tags GitHub' button (W291)",
                "Apre github.com/sigarone/Q-Audion-IOS/tags",
                "Cronologia release pubblica accessibile dal device"
              ]),
        .init(id: "v1.0.279", date: "2026-05-02",
              title: "Fix Xcode 26.4 build errors (W289) + W288 TF link",
              bullets: [
                "v1.0.278 build failed: 2 real Swift errors caught by diag step",
                "Fix W289a: Calendar.Identifier switch needed regular `default` (Xcode 26.4 strict)",
                "Fix W289b: ByteCountFormatter has no .locale property — removed",
                "Aggiunto W288: 'Feedback TestFlight' button in About → ASSISTENZA",
                "Apre la pagina pubblica del beta su testflight.apple.com",
                "Aggiunto TODO_AUDIT.md — outstanding work audit nel repo"
              ]),
        .init(id: "v1.0.278", date: "2026-05-02",
              title: "Audio session cat + UN auth status (W286/W287)",
              bullets: [
                "About → STATO SISTEMA: 'Audio session' (W286)",
                "Mostra la AVAudioSession.category corrente (es. 'PlayAndRecord')",
                "Notifiche → STATO: 'Autorizzazione' riga sopra Pendenti/Consegnate (W287)",
                "Authorized · Denied · Provisional · Ephemeral · Not determined",
                "Diagnosi rapida 'le notifiche non arrivano' (potrebbe essere denied)"
              ]),
        .init(id: "v1.0.277", date: "2026-05-02",
              title: "Conta release nel WhatsNew intro (W285)",
              bullets: [
                "'Cosa c'è di nuovo': intro mostra il count di entries",
                "Es. '53 entries · feature/ios-android-parity'",
                "Aiuta i tester a vedere d'occhio quante milestone sono uscite",
                "Static computed property — type-checker safe (CLAUDE.md §13)"
              ]),
        .init(id: "v1.0.276", date: "2026-05-02",
              title: "'Apri Privacy iOS' deep-link in Privacy (W284)",
              bullets: [
                "Privacy → SISTEMA: 'Apri Privacy in Impostazioni iOS'",
                "Sister di W169 (Notifiche → SISTEMA), stesso destination URL",
                "Più vicino al contesto mentale quando l'utente legge i toggle privacy",
                "Util quando Mic / NFC / Camera permessi sono stati revocati"
              ]),
        .init(id: "v1.0.275", date: "2026-05-02",
              title: "Diagnostics export: SYSTEM STATE section (W283)",
              bullets: [
                "Esporta diagnostica: nuova sezione 'SYSTEM STATE'",
                "Aggrega thermal · low-power · cores · physical mem · uptime · free disk",
                "Pre-bind disciplinato di ogni valore (CLAUDE.md §13)",
                "Bug-report di QA ora si auto-include il contesto hardware"
              ]),
        .init(id: "v1.0.274", date: "2026-05-02",
              title: "Timezone + calendar + dark-mode + mic (W279-W282)",
              bullets: [
                "About → STATO SISTEMA: 4 nuove righe diagnostiche",
                "W279 Fuso orario (es. 'Europe/Rome')",
                "W280 Calendario (Gregoriano / Islamico / Ebraico / ...)",
                "W281 Aspetto (Chiaro / Scuro / Non specificato)",
                "W282 Permesso microfono (Concesso / Negato / Non richiesto)",
                "AVAudioSession aggiunto agli imports per W282"
              ]),
        .init(id: "v1.0.273", date: "2026-05-02",
              title: "Test feedback aptico in DIAGNOSTICA (W278)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Test feedback aptico'",
                "Fa scattare il buzz canonico (HapticFeedback.messageSent)",
                "Verifica che la W160 vibrazione sia wirata e che il device abbia Taptic Engine",
                "Utile su iPad vecchi che mancano del motore aptico"
              ]),
        .init(id: "v1.0.272", date: "2026-05-02",
              title: "Battery + brightness + screen + vendorID (W274-W277)",
              bullets: [
                "About → STATO SISTEMA: 3 nuove righe diagnostiche",
                "W274 Batteria: livello + stato (in carica / scarica / piena)",
                "W275 Luminosità schermo: 0..100%",
                "W276 Schermo: dimensioni (es. '390×844 · @3x')",
                "W277 ID dispositivo (vendor): identifierForVendor truncato",
                "Tutto via UIDevice + UIScreen, single-statement helpers"
              ]),
        .init(id: "v1.0.271", date: "2026-05-02",
              title: "Svuota URLCache dev action (W271)",
              bullets: [
                "Settings → SVILUPPATORE: 'Svuota URLCache'",
                "Forza re-fetch HTTP per OTA catalog + avatar download",
                "URLCache.shared.removeAllCachedResponses()",
                "Utile per QA che vuole verificare metadata server fresh"
              ]),
        .init(id: "v1.0.270", date: "2026-05-02",
              title: "Cancella notifiche pianificate dev action (W270)",
              bullets: [
                "Notifiche → DIAGNOSTICA: 'Cancella notifiche pianificate'",
                "Sister di W263 (consegnate) — questa annulla i trigger in coda",
                "Utile se il tester tocca W171 e cambia idea prima dell'1.5s",
                "API: UNUserNotificationCenter.removeAllPendingNotificationRequests()"
              ]),
        .init(id: "v1.0.269", date: "2026-05-02",
              title: "Locale + memoria fisica + low-power in About (W269/W272/W273)",
              bullets: [
                "About → STATO SISTEMA: 3 nuove righe",
                "W269: lingua sistema (es. 'it_IT')",
                "W272: memoria fisica del dispositivo (RAM totale)",
                "W273: stato risparmio energetico (CPU ridotta quando attivo)",
                "Tutto via ProcessInfo + Locale, no async, no closures"
              ]),
        .init(id: "v1.0.268", date: "2026-05-02",
              title: "Self-test crittografia ML-KEM-1024 (W268)",
              bullets: [
                "Settings → SVILUPPATORE: 'Self-test crittografia'",
                "Round-trip sincrono: keygen → encap → decap → confronto shared secret",
                "Mostra OK + bytes + ms se passa, FAIL + reason se cade",
                "Sanity check rapido che la PQC stack sia viva senza fare una chiamata",
                "Alert title generalizzato in 'Sviluppatore' (era 'Cache liberata')"
              ]),
        .init(id: "v1.0.267", date: "2026-05-02",
              title: "Memoria processo in About (W267)",
              bullets: [
                "About → STATO SISTEMA: nuova riga 'Memoria processo'",
                "Resident size via mach_task_basic_info (Mach syscall)",
                "Stessa cifra che Activity Monitor / Instruments mostra come 'Memory'",
                "Utile per individuare leak in sessioni lunghe (PQC + ONNX)"
              ]),
        .init(id: "v1.0.266", date: "2026-05-02",
              title: "Spazio libero su disco in About (W266)",
              bullets: [
                "About → STATO SISTEMA: nuova riga 'Spazio libero'",
                "Usa volumeAvailableCapacityForImportantUsage (cifra realistica)",
                "Aiuta i tester a indagare upload falliti o eviction cache",
                "Formattato in locale italiana via ByteCountFormatter"
              ]),
        .init(id: "v1.0.265", date: "2026-05-02",
              title: "STATO section in Notifiche (pending + delivered) (W265)",
              bullets: [
                "Notifiche → STATO: conta pendenti + consegnate",
                "Refresh automatico all'apertura schermata",
                "Refresh anche dopo W171 (test) e W263 (clear)",
                "Verifica visibile che il toolkit di QA stia agendo davvero"
              ]),
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

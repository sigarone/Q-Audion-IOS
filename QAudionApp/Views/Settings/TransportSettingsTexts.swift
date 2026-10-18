import Foundation
import QAudionEngine

/// The texts of Settings > Trasporto that say what a mode, an address or a check does. They live apart from the view so
/// that each one is a plain function of the choice, and so the catalog test can pin that every key used here exists in the
/// six languages (`TransportSettingsTextsTests`).
///
/// The setting is read by 1-to-1 calls only (`QAudionWebRtcCallController`); group calls build their own media connections
/// and never read it. Every text that talks about calls says "chiamate 1 a 1".
///
/// Each text describes what the engine's `TransportPlan` does for that choice:
///   - auto: policy `.all`, STUN and TURN servers of the pool, the WSS bridge only when UDP looks blocked;
///   - p2p: policy `.all`, STUN servers only, never a TURN server, a relay or the bridge, for THIS phone;
///   - turn: policy `.relay`, TURN servers of the pool only, no bridge;
///   - relay: policy `.relay`, the WSS bridge alone, or the TURN servers of the pool when the bridge cannot start;
///   - a custom TURN server (the address, the user name and the password, each in its own field) replaces the pool in every
///     mode but p2p, which ignores it: in turn and relay it is the only route (policy `.relay`), in auto the policy stays
///     `.all`, so the servers are only this one but a direct connection stays possible. It gets the user name and password
///     the user wrote, never the temporary credentials of the BCrypto server. An address without credentials is refused by
///     Save and by the check.
///
/// Two behaviours do not depend on the mode, and the texts that would otherwise promise too much say so:
///   - p2p only shapes this phone's candidates. The candidates of the other phone go to ICE unfiltered
///     (`QAudionWebRtcCallController.handleRemoteIce`), so a relay it offers can still carry the call. The p2p texts say
///     "your phone", never "no relay in the call".
///   - when the connection does not come up, or drops during a call, the sealed voice frames go to the server's relay link:
///     the frame router answers `.useRelay` while ICE is not carrying (W-DCTXICEGATE), and a call with native audio
///     re-engages its manual capture once ICE has been bad for the debounce (W-SRTPFALLBACK). Neither looks at the
///     transport mode. So p2p, turn, relay, auto with a custom server and every custom server end with the same sentence
///     about the server, and it names no delay: "the connection does not come up or drops", then "until the connection is
///     active". The trigger is the connection (ICE), not the direct one: a call carried by the other phone's relay is a
///     connection, and the voice does not go through the server then.
/// If one of those rules changes, the matching text changes with it.
///
/// No `AppState` here (repo rule: a new file must not take it as a parameter).
enum TransportSettingsTexts {

    typealias Mode = TransportSettingsViewModel.Mode

    /// What the TURN server fields hold, for the note under them. The engine's `TransportChoice` computes it.
    typealias AddressState = TransportChoice.AddressState

    // MARK: - Mode

    /// The explanation under the mode picker. With a valid custom server typed in the field, turn and relay both route
    /// through that server alone, so they share one text (the pool and the WSS link of the plain texts would be false).
    /// auto and p2p do not change with the address: the note under the field says what it does there.
    static func explanation(for mode: Mode, address: AddressState) -> String {
        if address == .valid && (mode == .turn || mode == .relay) {
            return String(localized: "transport_settings.mode.custom_server.explanation", defaultValue: "Instrada le chiamate 1 a 1 solo tramite il server TURN scritto nel campo qui sotto, senza connessione diretta: l'altro telefono non vede il tuo indirizzo IP. Il pool di relay predefinito e il collegamento WSS non vengono usati. Se la connessione non si stabilisce o si interrompe, la voce passa invece dal server BCrypto, cifrata, finché la connessione non è attiva.", comment: "Transport settings — explanation under the mode picker, TURN or Relay with a valid custom server typed: relay-only policy through that server alone, no pool, no WSS link; the voice goes encrypted through the server if the connection does not come up or drops")
        }
        switch mode {
        case .auto:
            return String(localized: "transport_settings.mode.auto.explanation", defaultValue: "Per le chiamate 1 a 1 sceglie automaticamente la rotta migliore (P2P preferito, relay fallback).", comment: "Transport settings — explanation under the mode picker, Auto: policy all, STUN and TURN servers of the pool, the WSS link only when UDP looks blocked; it applies to 1-to-1 calls")
        case .p2p:
            return String(localized: "transport_settings.mode.p2p.explanation", defaultValue: "Per le chiamate 1 a 1 cerca una connessione diretta tra i due telefoni: il tuo telefono non usa server TURN né relay (restano ammessi i server STUN del server BCrypto) e l'altro telefono vede il tuo indirizzo IP. Se l'altro telefono offre un relay, la chiamata può comunque passare dal suo relay. Se la connessione non si stabilisce o si interrompe, la voce passa dal server BCrypto, cifrata, finché la connessione non è attiva.", comment: "Transport settings — explanation under the mode picker, P2P: looks for a direct connection; no TURN servers and no relay candidates on this phone, STUN allowed; a relay offered by the other phone can still carry the call; the voice goes encrypted through the server if the connection does not come up or drops; it applies to 1-to-1 calls")
        case .turn:
            return String(localized: "transport_settings.mode.turn.explanation", defaultValue: "Instrada le chiamate 1 a 1 solo tramite un server TURN del pool di relay predefinito, senza connessione diretta: l'altro telefono non vede il tuo indirizzo IP. Aumenta la latenza ma migliora il NAT traversal. Non usa il collegamento WSS. Se la connessione non si stabilisce o si interrompe, la voce passa invece dal server BCrypto, cifrata, finché la connessione non è attiva.", comment: "Transport settings — explanation under the mode picker, TURN: relay-only policy with the TURN servers of the pool, no WSS link; the voice goes encrypted through the server if the connection does not come up or drops; it applies to 1-to-1 calls")
        case .relay:
            return String(localized: "transport_settings.mode.relay.explanation", defaultValue: "Instrada le chiamate 1 a 1 solo tramite il collegamento WSS (WebSocket sicuro) al server BCrypto, senza connessione diretta: l'altro telefono non vede il tuo indirizzo IP. Funziona anche dove UDP e le porte TURN sono bloccati, a costo di latenza maggiore. Se il collegamento WSS non può essere avviato, usa i server TURN del pool di relay predefinito: la chiamata resta comunque su un relay. Se la connessione non si stabilisce o si interrompe, la voce passa invece dal server BCrypto, cifrata, finché la connessione non è attiva.", comment: "Transport settings — explanation under the mode picker, Relay: relay-only policy through the WSS link; if the link does not open, the TURN servers of the pool; the voice goes encrypted through the server if the connection does not come up or drops; it applies to 1-to-1 calls")
        }
    }

    // MARK: - TURN server fields

    /// Placeholder of the user name field of the custom TURN server.
    static var usernameFieldTitle: String {
        String(localized: "transport_settings.field.username", defaultValue: "Utente", comment: "Transport settings — placeholder of the user name field of the custom TURN server")
    }

    /// Placeholder of the password field of the custom TURN server (the word already used by the login screens).
    static var passwordFieldTitle: String {
        String(localized: "Password")
    }

    /// Under the buttons when "Salva" could not keep the user name and password in the Keychain: nothing was changed.
    static var saveFailedText: String {
        String(localized: "transport_settings.save.failed", defaultValue: "Non è stato possibile salvare utente e password nel Keychain del telefono: le impostazioni precedenti restano valide. Riprova.", comment: "Transport settings — shown when Save could not keep the user name and password of the custom TURN server in the Keychain; the previous settings stay in effect")
    }

    /// The note under the TURN server fields.
    static func addressNote(mode: Mode, address: AddressState) -> String {
        if address == .invalid {
            return String(localized: "transport_settings.address.note.invalid", defaultValue: "Indirizzo non valido: deve essere turn: o turns:, poi il nome del server e la porta (per esempio turn:hostname:3478), senza utente e password, che vanno nei campi Utente e Password. Finché non lo correggi non si può salvare né verificare la modalità.", comment: "Transport settings — note under the TURN server fields when the address is not a usable turn:/turns: address, or has the user name and password written inside it; they go in their own fields")
        }
        if address == .needsCredentials {
            return String(localized: "transport_settings.address.note.needs_credentials", defaultValue: "Servono utente e password: il server che scrivi non riceve le credenziali temporanee del server BCrypto, quindi compila i campi Utente e Password. Finché non li aggiungi non si può salvare né verificare la modalità.", comment: "Transport settings — note under the TURN server fields when the address is well formed but the user name or the password is empty: it cannot be saved or checked, and the BCrypto temporary credentials are not given to it")
        }
        if mode == .p2p {
            return String(localized: "transport_settings.address.note.p2p", defaultValue: "In modalità P2P il tuo telefono non usa nessun relay: l'indirizzo TURN non ha effetto.", comment: "Transport settings — note under the TURN address field in P2P mode, where this phone never uses a relay")
        }
        if address == .valid {
            if mode == .auto {
                return String(localized: "transport_settings.address.note.custom_auto", defaultValue: "Come server, le chiamate 1 a 1 useranno solo questo server TURN, con l'utente e la password che hai scritto; le credenziali temporanee del server BCrypto non gli vengono date. I server predefiniti (STUN e relay) e il collegamento WSS non vengono usati. Una connessione diretta tra i due telefoni resta possibile. Se la connessione non si stabilisce o si interrompe, la voce passa dal server BCrypto, cifrata, finché la connessione non è attiva.", comment: "Transport settings — note under the TURN address field in Auto mode when a valid address is typed: it is the only server (the policy stays all, so a direct connection stays possible), with the credentials the user wrote; the voice goes encrypted through the server if the connection does not come up or drops")
            }
            return String(localized: "transport_settings.address.note.custom", defaultValue: "Le chiamate 1 a 1 useranno solo questo server TURN, con l'utente e la password che hai scritto; le credenziali temporanee del server BCrypto non gli vengono date. I server predefiniti (STUN e relay) e il collegamento WSS non vengono usati. Se la connessione non si stabilisce o si interrompe, la voce passa invece dal server BCrypto, cifrata, finché la connessione non è attiva.", comment: "Transport settings — note under the TURN address field in TURN or Relay mode when a valid address is typed: it replaces the default servers and gets the credentials the user wrote; the voice goes encrypted through the server if the connection does not come up or drops")
        }
        // Empty field: the default servers of the chosen mode (the text that was always here).
        return String(localized: "Lascia vuoto per usare il pool di relay predefinito.")
    }

    // MARK: - Check

    static func checkButtonTitle(running: Bool) -> String {
        if running {
            return String(localized: "transport_settings.check.running", defaultValue: "Verifica in corso…", comment: "Transport settings — check button label while the check runs")
        }
        return String(localized: "transport_settings.check.button", defaultValue: "Verifica la modalità scelta", comment: "Transport settings — check button: it checks the mode selected in the picker, not only the server")
    }

    static var rowModeTitle: String {
        String(localized: "transport_settings.check.row.mode", defaultValue: "Modalità controllata", comment: "Transport settings — check result row label: which mode was checked")
    }

    static var rowRouteTitle: String {
        String(localized: "transport_settings.check.row.route", defaultValue: "Percorso", comment: "Transport settings — check result row label: which servers the mode used")
    }

    static var rowCandidatesTitle: String {
        String(localized: "transport_settings.check.row.candidates", defaultValue: "Candidati trovati", comment: "Transport settings — check result row label: how many ICE candidates of each type were found")
    }

    static func routeText(_ route: TransportPlan.Route) -> String {
        switch route {
        case .directOnly:
            return String(localized: "transport_settings.route.direct_only", defaultValue: "Solo server STUN su questo telefono, nessun TURN né relay", comment: "Transport settings — check route: P2P, this phone gathers with STUN servers only and no TURN or relay; it does not promise a direct connection (the other phone may offer a relay)")
        case .serverPool:
            return String(localized: "transport_settings.route.server_pool", defaultValue: "Server STUN e relay predefiniti", comment: "Transport settings — check route: Auto, the default STUN and relay servers")
        case .serverPoolWithBridge:
            return String(localized: "transport_settings.route.server_pool_bridge", defaultValue: "Server STUN e relay predefiniti, più il collegamento WSS", comment: "Transport settings — check route: Auto with UDP blocked, the default servers plus the WSS link")
        case .poolTurn:
            return String(localized: "transport_settings.route.pool_turn", defaultValue: "Server TURN del pool di relay predefinito", comment: "Transport settings — check route: TURN mode, the TURN servers of the default relay pool")
        case .wssBridge:
            return String(localized: "transport_settings.route.wss_bridge", defaultValue: "Collegamento WSS al server BCrypto", comment: "Transport settings — check route: Relay mode, the WSS link to the server")
        case .poolTurnFallback:
            return String(localized: "transport_settings.route.pool_turn_fallback", defaultValue: "Server TURN del pool di relay predefinito (il collegamento WSS non è disponibile)", comment: "Transport settings — check route: Relay mode when the WSS link could not be used, so the TURN servers of the pool")
        case .customServer:
            return String(localized: "transport_settings.route.custom_server", defaultValue: "Il server TURN che hai inserito", comment: "Transport settings — check route: the custom TURN address typed by the user")
        }
    }

    static func candidatesText(_ counts: TransportCandidateCounts) -> String {
        let host: Int = counts.host
        let srflx: Int = counts.srflx
        let relay: Int = counts.relay
        return String(localized: "transport_settings.candidates.counts", defaultValue: "Locali (host) \(host) · Pubblici (srflx) \(srflx) · Relay \(relay)", comment: "Transport settings — check result: number of ICE candidates by type (host = local network, srflx = public address seen by a STUN server, relay = through a relay); three whole numbers in this order")
    }

    static func outcomeText(_ outcome: TransportCheckOutcome, mode: Mode) -> String {
        switch outcome {
        case .ok:
            switch mode {
            case .p2p:
                return String(localized: "transport_settings.outcome.ok_p2p", defaultValue: "OK: il tuo telefono non ha prodotto candidati relay, come previsto in modalità P2P.", comment: "Transport settings — check verdict: P2P with candidates found on this phone and none of them relay")
            case .auto:
                return String(localized: "transport_settings.outcome.ok_auto", defaultValue: "OK: la rete ha prodotto candidati di connessione.", comment: "Transport settings — check verdict: Auto with candidates found")
            case .turn, .relay:
                return String(localized: "transport_settings.outcome.ok_relay", defaultValue: "OK: trovato almeno un candidato relay.", comment: "Transport settings — check verdict: TURN or Relay mode with at least one relay candidate")
            }
        case .unexpectedRelay:
            return String(localized: "transport_settings.outcome.unexpected_relay", defaultValue: "NON OK: è comparso un candidato relay, ma in modalità P2P non dovrebbe esserci.", comment: "Transport settings — check verdict: a relay candidate appeared in P2P mode")
        case .noRelayCandidate:
            return String(localized: "transport_settings.outcome.no_relay_candidate", defaultValue: "NON OK: nessun candidato relay trovato, da questa rete il relay non risulta raggiungibile.", comment: "Transport settings — check verdict: TURN or Relay mode and no relay candidate came out")
        case .noCandidates:
            return String(localized: "transport_settings.outcome.no_candidates", defaultValue: "NON OK: nessun candidato trovato, controlla la connessione di rete.", comment: "Transport settings — check verdict: not a single candidate, so no usable network")
        case .serverListUnavailable:
            return String(localized: "transport_settings.outcome.server_list_unavailable", defaultValue: "NON OK: per questa modalità non c'era nessun server da provare, perché dal server BCrypto non è arrivato l'elenco o non contiene nulla che la modalità possa usare.", comment: "Transport settings — check verdict: no server to try for the mode, in any mode: the list did not arrive from the server, or nothing in it can be used by the mode")
        }
    }

    static var confirmTitle: String {
        String(localized: "transport_settings.check.confirm", defaultValue: "Confermo", comment: "Transport settings — button after a check: the user confirms the result; the mode and the date are remembered")
    }

    static var reportTitle: String {
        String(localized: "transport_settings.check.report", defaultValue: "Segnala problema", comment: "Transport settings — button after a check: copies a technical summary (mode, candidate types, result; no IP addresses) to the clipboard")
    }

    static var reportCopiedText: String {
        String(localized: "transport_settings.check.report_copied", defaultValue: "Riepilogo tecnico copiato negli appunti, senza indirizzi IP.", comment: "Transport settings — shown after the report button copied the technical summary")
    }

    /// The line "Ultima conferma": the mode, whether the check it confirmed was OK, and the date. The verdict is part of the
    /// sentence, so the two cases are two texts (each translated whole, not glued together).
    static func confirmedText(modeName: String, outcomeIsOk: Bool, dateText: String) -> String {
        if outcomeIsOk {
            return String(localized: "transport_settings.check.confirmed", defaultValue: "Ultima conferma: \(modeName) con esito OK il \(dateText)", comment: "Transport settings — the last confirmation of a check that was OK: first the mode name, then the date and time")
        }
        return String(localized: "transport_settings.check.confirmed_not_ok", defaultValue: "Ultima conferma: \(modeName) con esito NON OK il \(dateText)", comment: "Transport settings — the last confirmation of a check that was NOT OK: first the mode name, then the date and time")
    }

    /// Under a check result whose mode OR address differs from the saved ones. It says both: the mode, the address or
    /// both can be the unsaved part, and a text about "this mode" alone would be wrong when only the address changed.
    static var notSavedText: String {
        String(localized: "transport_settings.check.not_saved", defaultValue: "Il controllo è stato fatto con una modalità o un indirizzo non ancora salvati: premi Salva per usarli nelle chiamate 1 a 1.", comment: "Transport settings — shown under a check result when the checked mode or the checked address (or both) differs from the saved one")
    }

    // MARK: - Save and diagnostics rows

    static var savedText: String {
        String(localized: "transport_settings.saved.note", defaultValue: "Salvato. Vale dalla prossima chiamata 1 a 1.", comment: "Transport settings — shown after Save: a call already running keeps the mode it started with; group calls do not read this setting")
    }

    static var relayListResponseTitle: String {
        String(localized: "transport_settings.rtt.last_label", defaultValue: "Risposta elenco relay", comment: "Transport settings, DIAGNOSTICA — row label: how long the server took to answer the relay list request in the last check (not a TURN round trip)")
    }

    static var relayListResponseSavedTitle: String {
        String(localized: "transport_settings.rtt.saved_label", defaultValue: "Risposta elenco relay salvata", comment: "Transport settings, DIAGNOSTICA — row label: the relay list response time stored by the last Save")
    }
}

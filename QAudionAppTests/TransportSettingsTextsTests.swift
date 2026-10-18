import XCTest
import QAudionEngine
@testable import QAudionApp

/// The texts of Settings > Trasporto and the storage behind `TransportGate`.
///
///  - every text that is new or changed is in the String Catalog in the six languages of the app, with the same
///    placeholders, and the Italian text of the catalog is the text the code falls back to;
///  - each mode has its own explanation, and what the Italian explanation says is what `TransportPlan` does for that
///    mode (no TURN in p2p, no bridge in turn, the bridge alone in relay, the pool as the fallback of relay, the typed
///    server alone in turn and relay when the address is valid), without promising more than the code keeps: p2p talks
///    about THIS phone, and every mode says that the voice goes through the server when the connection does not come up
///    or drops, without naming a delay;
///  - the texts say "chiamate 1 a 1" (group calls do not read the setting);
///  - the note under the TURN field, the route names and the verdicts cover every case, none of them shared;
///  - the German texts use "Sie", like the rest of the catalog;
///  - what "Salva" writes through `TransportGate` is what the calls read, and the password is not left in UserDefaults.
///
/// The behaviour itself (the plan, the verdicts, where the server is kept) is pinned by the engine tests
/// `TransportPlanTests`, `TransportCheckTests` and `TransportPreferencesCredentialsTests`.
///
/// Wired into CI: on the include list of `QAudionApp/project-apptests.yml` and in the `-only-testing` list of
/// `.github/workflows/ios-app-tests.yml`.
final class TransportSettingsTextsTests: XCTestCase {

    private let languages = ["it", "en", "de", "es", "fr", "pt-BR"]

    /// Every key of the screen that is new or changed (the older sentence under the TURN field keeps its own key, below).
    private let keys = [
        "transport_settings.mode.auto.explanation",
        "transport_settings.mode.p2p.explanation",
        "transport_settings.mode.turn.explanation",
        "transport_settings.mode.relay.explanation",
        "transport_settings.mode.custom_server.explanation",
        "transport_settings.address.note.invalid",
        "transport_settings.address.note.needs_credentials",
        "transport_settings.field.username",
        "transport_settings.address.note.p2p",
        "transport_settings.address.note.custom",
        "transport_settings.address.note.custom_auto",
        "transport_settings.check.button",
        "transport_settings.check.running",
        "transport_settings.check.row.mode",
        "transport_settings.check.row.route",
        "transport_settings.check.row.candidates",
        "transport_settings.route.direct_only",
        "transport_settings.route.server_pool",
        "transport_settings.route.server_pool_bridge",
        "transport_settings.route.pool_turn",
        "transport_settings.route.wss_bridge",
        "transport_settings.route.pool_turn_fallback",
        "transport_settings.route.custom_server",
        "transport_settings.candidates.counts",
        "transport_settings.outcome.ok_p2p",
        "transport_settings.outcome.ok_auto",
        "transport_settings.outcome.ok_relay",
        "transport_settings.outcome.unexpected_relay",
        "transport_settings.outcome.no_relay_candidate",
        "transport_settings.outcome.no_candidates",
        "transport_settings.outcome.server_list_unavailable",
        "transport_settings.check.confirm",
        "transport_settings.check.report",
        "transport_settings.check.report_copied",
        "transport_settings.check.confirmed",
        "transport_settings.check.confirmed_not_ok",
        "transport_settings.check.not_saved",
        "transport_settings.saved.note",
        "transport_settings.save.failed",
        "transport_settings.rtt.last_label",
        "transport_settings.rtt.saved_label"
    ]

    /// The sentence that was already there, still used under an empty TURN field.
    private let legacyKey = "Lascia vuoto per usare il pool di relay predefinito."

    /// The texts that talk about calls, and how each language writes "1-to-1".
    private let oneToOneKeys = [
        "transport_settings.mode.auto.explanation",
        "transport_settings.mode.p2p.explanation",
        "transport_settings.mode.turn.explanation",
        "transport_settings.mode.relay.explanation",
        "transport_settings.mode.custom_server.explanation",
        "transport_settings.address.note.custom",
        "transport_settings.address.note.custom_auto",
        "transport_settings.check.not_saved",
        "transport_settings.saved.note"
    ]
    private let oneToOneMarker = ["it": "1 a 1", "en": "1-to-1", "de": "1:1", "es": "1 a 1", "fr": "1 à 1", "pt-BR": "1 a 1"]

    /// A TURN server with its own user name and password: what the field needs to hold to be saved.
    private let customServer = "turn:custom-user:custom-secret@custom.example.test:3478"

    private typealias Mode = TransportSettingsViewModel.Mode

    // MARK: - Catalog access

    private func catalogValue(_ strings: [String: Any], _ key: String, _ language: String) -> String? {
        guard let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[language] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }

    private func catalogStrings() throws -> [String: Any] {
        let catalog = try sourceText("QAudionApp/Localizable.xcstrings")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalog.utf8)) as? [String: Any])
        return try XCTUnwrap(json["strings"] as? [String: Any])
    }

    private func placeholders(_ text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let percent = rest.firstIndex(of: "%") {
            let after = rest[rest.index(after: percent)...]
            if after.hasPrefix("lld") {
                found.append("%lld")
            } else if after.hasPrefix("@") {
                found.append("%@")
            }
            rest = after
        }
        return found
    }

    // MARK: - The catalog

    func testEveryTextOfTheScreenIsInTheCatalogInAllSixLanguages() throws {
        let strings = try catalogStrings()
        for key in keys + [legacyKey] {
            let italian = catalogValue(strings, key, "it")
            XCTAssertNotNil(italian, "\(key) it")
            for language in languages {
                let value = catalogValue(strings, key, language)
                XCTAssertNotNil(value, "\(key) is missing in \(language)")
                guard let text = value else { continue }
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(key) \(language) is empty")
                XCTAssertEqual(placeholders(text), placeholders(italian ?? ""), "\(key) \(language) has other placeholders than the Italian text")
                if language != "it" {
                    XCTAssertNotEqual(text, key, "\(key) \(language) is the key")
                    XCTAssertNotEqual(text, italian, "\(key) \(language) is still the Italian text")
                }
            }
        }
    }

    func testTheCountsAndTheConfirmationKeepTheirPlaceholdersInEveryLanguage() throws {
        let strings = try catalogStrings()
        for language in languages {
            XCTAssertEqual(placeholders(catalogValue(strings, "transport_settings.candidates.counts", language) ?? ""),
                           ["%lld", "%lld", "%lld"], "counts \(language): host, srflx, relay")
            XCTAssertEqual(placeholders(catalogValue(strings, "transport_settings.check.confirmed", language) ?? ""),
                           ["%@", "%@"], "confirmed \(language): mode name, date")
            XCTAssertEqual(placeholders(catalogValue(strings, "transport_settings.check.confirmed_not_ok", language) ?? ""),
                           ["%@", "%@"], "confirmed, not OK \(language): mode name, date")
        }
    }

    /// The keys the Texts file asks the catalog for are exactly the keys tested above: a text added to the code without
    /// its translations, or left in the catalog without code, fails here.
    func testTheKeysTheCodeUsesAreTheKeysTheCatalogTestCovers() throws {
        let source = try sourceText("QAudionApp/Views/Settings/TransportSettingsTexts.swift")
        let used = Set(literalKeys(in: source))
        XCTAssertFalse(used.isEmpty, "no key found in the Texts file: the parser is stale")
        XCTAssertEqual(used, Set(keys),
                       "keys in code but not in this test: \(used.subtracting(keys)); keys here but not in code: \(Set(keys).subtracting(used))")
    }

    /// The Italian text in the catalog is the text the code falls back to (an interpolation reads as its placeholder).
    func testTheItalianCatalogTextIsTheTextTheCodeFallsBackTo() throws {
        let strings = try catalogStrings()
        let source = try sourceText("QAudionApp/Views/Settings/TransportSettingsTexts.swift")
        let defaults = defaultValues(in: source)
        XCTAssertEqual(Set(defaults.keys), Set(keys))
        for (key, fallback) in defaults {
            XCTAssertEqual(catalogValue(strings, key, "it"), fallback, key)
        }
    }

    // MARK: - What the explanations say is what the plan does

    private func plan(_ mode: Mode, bridge: Bool = false) -> TransportPlan {
        TransportPlan.make(mode: mode, customTurnUrl: nil, bridgeAvailable: bridge)
    }

    private func italian(_ key: String) throws -> String {
        try XCTUnwrap(catalogValue(try catalogStrings(), key, "it"), key)
    }

    func testEachModeHasItsOwnExplanation() {
        let texts = Mode.allCases.map { TransportSettingsTexts.explanation(for: $0, address: .empty) }
        XCTAssertEqual(Set(texts).count, Mode.allCases.count, "two modes share an explanation: \(texts)")
        for text in texts {
            XCTAssertFalse(text.isEmpty)
        }
    }

    /// An address that cannot be used (or none) changes nothing under the picker; a valid one changes turn and relay only.
    func testTheExplanationFollowsAValidAddressInTurnAndRelayOnly() {
        for mode in Mode.allCases {
            let plain = TransportSettingsTexts.explanation(for: mode, address: .empty)
            XCTAssertEqual(TransportSettingsTexts.explanation(for: mode, address: .invalid), plain, "\(mode): invalid")
            XCTAssertEqual(TransportSettingsTexts.explanation(for: mode, address: .needsCredentials), plain,
                           "\(mode): an address without credentials is not used, so the plain text is the true one")
            let withAddress = TransportSettingsTexts.explanation(for: mode, address: .valid)
            if mode == .turn || mode == .relay {
                XCTAssertNotEqual(withAddress, plain, "\(mode): the plain text says the pool or the WSS link, which a valid address replaces")
            } else {
                XCTAssertEqual(withAddress, plain, "\(mode)")
            }
        }
        XCTAssertEqual(TransportSettingsTexts.explanation(for: .turn, address: .valid),
                       TransportSettingsTexts.explanation(for: .relay, address: .valid),
                       "with a valid address turn and relay are the same route: the typed server alone")
    }

    func testTheP2PExplanationSaysNoTurnNoRelayAndStunStaysAndTheIpIsSeen() throws {
        let p2p = plan(.p2p, bridge: true)
        XCTAssertFalse(p2p.includePoolTurn, "the plan lets TURN in: the text below would be false")
        XCTAssertFalse(p2p.includeBridge)
        XCTAssertTrue(p2p.includePoolStun)
        XCTAssertEqual(p2p.icePolicy, .all)
        let text = try italian("transport_settings.mode.p2p.explanation")
        XCTAssertTrue(text.contains("cerca una connessione diretta tra i due telefoni"))
        XCTAssertTrue(text.contains("il tuo telefono non usa server TURN né relay"), "the plan shapes this phone only")
        XCTAssertTrue(text.contains("server STUN"))
        XCTAssertTrue(text.contains("l'altro telefono vede il tuo indirizzo IP"))
        XCTAssertTrue(text.contains("Se l'altro telefono offre un relay, la chiamata può comunque passare dal suo relay"),
                      "the candidates of the other phone are not filtered, so its relay can carry the call")
        XCTAssertFalse(text.contains("Solo connessione diretta"), "the old text promised a direct call, which p2p cannot guarantee")
        assertSaysTheVoiceGoesThroughTheServerWhenTheConnectionFails(text, "p2p")
        XCTAssertTrue(text.contains("la voce passa dal server BCrypto, cifrata"),
                      "p2p does not say 'only': the fallback is plain, not an exception to something")
    }

    /// What the voice does when the connection does not come up or drops during a call, in the same words for p2p, turn,
    /// relay and a custom server: the router sends the frames to the server while ICE is not carrying, and a call with
    /// native audio re-engages once ICE has been bad for the debounce (neither looks at the mode). The trigger is the
    /// connection, not the direct one: a call carried by the other phone's relay is a connection, and the voice stays off
    /// the server then. No delay is named: a DataChannel call diverts the very next frame, so "within a few moments"
    /// would be a grace period that does not exist there.
    private func assertSaysTheVoiceGoesThroughTheServerWhenTheConnectionFails(
        _ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(text.contains("Se la connessione non si stabilisce o si interrompe,"),
                      "\(label): the condition", file: file, line: line)
        XCTAssertTrue(text.contains("dal server BCrypto, cifrata, finché la connessione non è attiva."),
                      "\(label): the voice goes through the server, encrypted, until the connection is active",
                      file: file, line: line)
        XCTAssertFalse(text.contains("pochi istanti"), "\(label): no grace period exists for a DataChannel call", file: file, line: line)
        XCTAssertFalse(text.contains("ripristina"), "\(label): no recovery window is promised", file: file, line: line)
        XCTAssertFalse(text.contains("all'avvio"), "\(label): not true for a call with native audio", file: file, line: line)
    }

    func testTheTurnExplanationSaysRelayOnlyPoolTurnAndNoWssLink() throws {
        let turn = plan(.turn, bridge: true)
        XCTAssertEqual(turn.icePolicy, .relay)
        XCTAssertTrue(turn.includePoolTurn)
        XCTAssertFalse(turn.includePoolStun)
        XCTAssertFalse(turn.includeBridge)
        XCTAssertEqual(turn.bridgeRole, .never)
        let text = try italian("transport_settings.mode.turn.explanation")
        XCTAssertTrue(text.contains("senza connessione diretta"))
        XCTAssertTrue(text.contains("server TURN del pool"))
        XCTAssertTrue(text.contains("Non usa il collegamento WSS"))
        XCTAssertTrue(text.contains("non vede il tuo indirizzo IP"))
        assertSaysTheVoiceGoesThroughTheServerWhenTheConnectionFails(text, "turn")
        XCTAssertTrue(text.contains("la voce passa invece dal server BCrypto"),
                      "turn says 'only through a TURN server', so the exception has to read as an exception")
    }

    func testTheRelayExplanationSaysTheWssLinkAloneAndThePoolTurnAsFallback() throws {
        let withBridge = plan(.relay, bridge: true)
        XCTAssertEqual(withBridge.icePolicy, .relay)
        XCTAssertTrue(withBridge.includeBridge)
        XCTAssertFalse(withBridge.includePoolTurn, "the plan mixes the pool into the bridge: the text says the link is alone")
        let fallback = plan(.relay, bridge: false)
        XCTAssertEqual(fallback.icePolicy, .relay, "the fallback must stay relay-only: the text promises a relay")
        XCTAssertTrue(fallback.includePoolTurn)
        XCTAssertFalse(fallback.includeBridge)
        let text = try italian("transport_settings.mode.relay.explanation")
        XCTAssertTrue(text.contains("solo tramite il collegamento WSS"))
        XCTAssertTrue(text.contains("senza connessione diretta"))
        XCTAssertTrue(text.contains("Se il collegamento WSS non può essere avviato, usa i server TURN del pool"))
        XCTAssertTrue(text.contains("la chiamata resta comunque su un relay"))
        assertSaysTheVoiceGoesThroughTheServerWhenTheConnectionFails(text, "relay")
        XCTAssertTrue(text.contains("la voce passa invece dal server BCrypto"),
                      "relay says 'only through the WSS link', so the exception has to read as an exception")
    }

    /// Under the picker, turn and relay with a valid address say that the calls use the typed server alone. The plan agrees:
    /// the pool and the bridge are out, the policy is relay-only, the list is that one server.
    func testTheExplanationWithAValidAddressSaysTheTypedServerAloneForTurnAndRelay() throws {
        let address = URL(string: customServer)
        for mode in [Mode.turn, .relay] {
            let p = TransportPlan.make(mode: mode, customTurnUrl: address, bridgeAvailable: true)
            XCTAssertEqual(p.icePolicy, .relay, "\(mode): no direct connection")
            XCTAssertFalse(p.includePoolStun || p.includePoolTurn || p.includeBridge, "\(mode)")
            XCTAssertEqual(p.route, .customServer, "\(mode)")
        }
        let text = try italian("transport_settings.mode.custom_server.explanation")
        XCTAssertTrue(text.contains("solo tramite il server TURN scritto nel campo qui sotto"))
        XCTAssertTrue(text.contains("senza connessione diretta"))
        XCTAssertTrue(text.contains("Il pool di relay predefinito e il collegamento WSS non vengono usati"))
        assertSaysTheVoiceGoesThroughTheServerWhenTheConnectionFails(text, "custom server explanation")
        XCTAssertFalse(text.contains("server TURN del pool"), "the pool is not used with a valid address")
    }

    // MARK: - The note under the TURN field

    /// In turn and relay the typed server is the only route (policy `.relay`): "solo questo server TURN" is true. In auto
    /// the policy stays `.all`: the servers are only that one, but a direct connection stays possible, and the note says
    /// so instead of promising "solo questo server".
    func testTheCustomAddressNoteIsTrueForTheModeItIsShownIn() throws {
        let address = URL(string: customServer)
        let pool = [RelayServer(urls: ["turn:turn-a.example.test:3478"], username: "user-a", credential: "secret-a")]
        for mode in [Mode.auto, .turn, .relay] {
            let p = TransportPlan.make(mode: mode, customTurnUrl: address, bridgeAvailable: true)
            XCTAssertFalse(p.includePoolStun || p.includePoolTurn || p.includeBridge, "\(mode): the default servers and the link are not used")
            let entries = p.servers(pool: pool, bridgeIceUrl: "turn:127.0.0.1:50123?transport=udp")
            XCTAssertEqual(entries.count, 1, "\(mode)")
            XCTAssertEqual(entries.first?.username, "custom-user", "\(mode): the user name the user wrote")
            XCTAssertEqual(entries.first?.credential, "custom-secret", "\(mode): the password the user wrote")
            XCTAssertNotEqual(entries.first?.username, "user-a", "\(mode): the temporary credentials of the BCrypto server are not given")
        }
        XCTAssertEqual(TransportPlan.make(mode: .auto, customTurnUrl: address, bridgeAvailable: false).icePolicy, .all,
                       "auto keeps the policy that allows a direct connection")
        XCTAssertEqual(TransportPlan.make(mode: .turn, customTurnUrl: address, bridgeAvailable: false).icePolicy, .relay)
        XCTAssertEqual(TransportPlan.make(mode: .relay, customTurnUrl: address, bridgeAvailable: false).icePolicy, .relay)

        let custom = try italian("transport_settings.address.note.custom")
        XCTAssertTrue(custom.contains("Le chiamate 1 a 1 useranno solo questo server TURN"))
        XCTAssertTrue(custom.contains("con l'utente e la password che hai scritto"))
        XCTAssertTrue(custom.contains("le credenziali temporanee del server BCrypto non gli vengono date"))
        XCTAssertTrue(custom.contains("I server predefiniti (STUN e relay) e il collegamento WSS non vengono usati"))
        XCTAssertFalse(custom.contains("il server che scrivi le riceve"), "the old claim: the pool credentials go to the typed server")
        XCTAssertFalse(custom.contains("Funziona se quel server accetta le stesse credenziali"), "the old claim: it borrows the pool credentials")
        XCTAssertFalse(custom.contains("resta possibile"), "turn and relay have no direct connection")
        assertSaysTheVoiceGoesThroughTheServerWhenTheConnectionFails(custom, "custom address, turn and relay")

        let auto = try italian("transport_settings.address.note.custom_auto")
        XCTAssertTrue(auto.hasPrefix("Come server, le chiamate 1 a 1 useranno solo questo server TURN"),
                      "in auto the text is about the servers: the calls are not forced through this one")
        XCTAssertTrue(auto.contains("Una connessione diretta tra i due telefoni resta possibile"),
                      "auto keeps the policy that allows a direct connection")
        XCTAssertFalse(auto.contains("senza connessione diretta"))
        XCTAssertTrue(auto.contains("le credenziali temporanee del server BCrypto non gli vengono date"))
        XCTAssertTrue(auto.contains("I server predefiniti (STUN e relay) e il collegamento WSS non vengono usati"))
        assertSaysTheVoiceGoesThroughTheServerWhenTheConnectionFails(auto, "custom address, auto")
        XCTAssertFalse(auto.contains("passa invece"), "auto does not say 'only', so there is no exception to flag")
    }

    func testTheNeedsCredentialsNoteSaysWhatToWriteAndThatTheBcryptoCredentialsAreNotGiven() throws {
        XCTAssertEqual(TransportCustomTurn.parse("turn:custom.example.test:3478"), .missingCredentials)
        let text = try italian("transport_settings.address.note.needs_credentials")
        XCTAssertTrue(text.contains("Servono utente e password"))
        XCTAssertTrue(text.contains("non riceve le credenziali temporanee del server BCrypto"))
        XCTAssertTrue(text.contains("non si può salvare né verificare la modalità"))
        XCTAssertFalse(text.contains("%"), "a percent sign in a localized text is read as a format")
    }

    /// The p2p texts under the address field and in the check verdict talk about this phone: the plan shapes its
    /// candidates, the check gathers only them, and the other phone may still offer a relay.
    func testTheOtherP2PTextsTalkAboutThisPhoneNotAboutTheWholeCall() throws {
        let note = try italian("transport_settings.address.note.p2p")
        XCTAssertTrue(note.contains("il tuo telefono non usa nessun relay"))
        XCTAssertTrue(note.contains("l'indirizzo TURN non ha effetto"))
        let verdict = try italian("transport_settings.outcome.ok_p2p")
        XCTAssertTrue(verdict.contains("il tuo telefono non ha prodotto candidati relay"))
        XCTAssertFalse(verdict.contains("nessun candidato relay,"), "the old verdict read as if no relay could carry the call")
    }

    /// The route row of the check must not promise more than the p2p explanation: this phone gathers with STUN servers
    /// only, and whether the call is direct is not decided here (the other phone may offer a relay).
    func testTheP2PRouteRowSaysWhatThisPhoneUsesNotThatTheCallIsDirect() throws {
        let p2p = plan(.p2p, bridge: true)
        XCTAssertEqual(p2p.route, .directOnly)
        XCTAssertTrue(p2p.includePoolStun)
        XCTAssertFalse(p2p.includePoolTurn || p2p.includeBridge)
        let row = try italian("transport_settings.route.direct_only")
        XCTAssertTrue(row.contains("Solo server STUN su questo telefono"))
        XCTAssertTrue(row.contains("nessun TURN né relay"))
        XCTAssertFalse(row.lowercased().contains("diretta"), "the row must not promise a direct connection")
        XCTAssertNotEqual(row, "Connessione diretta, solo server STUN", "the old row")
        for language in languages where language != "it" {
            let text = catalogValue(try catalogStrings(), "transport_settings.route.direct_only", language) ?? ""
            XCTAssertFalse(text.lowercased().hasPrefix("direct connection") || text.lowercased().hasPrefix("connexion directe")
                           || text.lowercased().hasPrefix("conexión directa") || text.lowercased().hasPrefix("conexão direta")
                           || text.lowercased().hasPrefix("direkte verbindung"), "\(language): the old promise is back: \(text)")
        }
    }

    func testTheNoteUnderTheTurnFieldFollowsTheModeAndTheAddress() {
        let p2pEmpty = TransportSettingsTexts.addressNote(mode: .p2p, address: .empty)
        let p2pValid = TransportSettingsTexts.addressNote(mode: .p2p, address: .valid)
        XCTAssertEqual(p2pEmpty, p2pValid, "p2p ignores the address, so the note is the same with or without one")
        let emptyNote = TransportSettingsTexts.addressNote(mode: .auto, address: .empty)
        let autoValidNote = TransportSettingsTexts.addressNote(mode: .auto, address: .valid)
        let validNote = TransportSettingsTexts.addressNote(mode: .turn, address: .valid)
        let needsCredentialsNote = TransportSettingsTexts.addressNote(mode: .auto, address: .needsCredentials)
        let invalidNote = TransportSettingsTexts.addressNote(mode: .auto, address: .invalid)
        XCTAssertEqual(Set([p2pEmpty, emptyNote, autoValidNote, validNote, needsCredentialsNote, invalidNote]).count, 6,
                       "six different situations, six texts")
        XCTAssertEqual(TransportSettingsTexts.addressNote(mode: .relay, address: .valid), validNote, "turn and relay say the same")
        for mode in [Mode.auto, .turn, .relay] {
            XCTAssertEqual(TransportSettingsTexts.addressNote(mode: mode, address: .empty), emptyNote, "\(mode)")
        }
        for mode in Mode.allCases {
            XCTAssertEqual(TransportSettingsTexts.addressNote(mode: mode, address: .invalid), invalidNote,
                           "an address that cannot be saved is flagged in every mode")
            XCTAssertEqual(TransportSettingsTexts.addressNote(mode: mode, address: .needsCredentials), needsCredentialsNote,
                           "an address without credentials cannot be saved either, in every mode")
        }
        XCTAssertEqual(emptyNote, String(localized: "Lascia vuoto per usare il pool di relay predefinito."),
                       "the empty-field sentence is the one that was already in the catalog")
    }

    // MARK: - Routes and verdicts

    func testEveryRouteAndEveryVerdictHasItsOwnText() {
        let routes = TransportPlan.Route.allCases.map { TransportSettingsTexts.routeText($0) }
        XCTAssertEqual(Set(routes).count, TransportPlan.Route.allCases.count, "two routes share a text: \(routes)")
        for outcome in TransportCheckOutcome.allCases {
            for mode in Mode.allCases {
                XCTAssertFalse(TransportSettingsTexts.outcomeText(outcome, mode: mode).isEmpty, "\(outcome) \(mode)")
            }
        }
        XCTAssertNotEqual(TransportSettingsTexts.outcomeText(.ok, mode: .p2p), TransportSettingsTexts.outcomeText(.ok, mode: .auto))
        XCTAssertNotEqual(TransportSettingsTexts.outcomeText(.ok, mode: .auto), TransportSettingsTexts.outcomeText(.ok, mode: .relay))
        XCTAssertEqual(TransportSettingsTexts.outcomeText(.ok, mode: .turn), TransportSettingsTexts.outcomeText(.ok, mode: .relay),
                       "turn and relay are both judged by the relay candidate")
        let failures = [TransportCheckOutcome.unexpectedRelay, .noRelayCandidate, .noCandidates, .serverListUnavailable]
            .map { TransportSettingsTexts.outcomeText($0, mode: .relay) }
        XCTAssertEqual(Set(failures).count, failures.count)
    }

    /// "No server was tried" is a verdict of every mode, so its text must not talk about one of them.
    func testTheNoServerVerdictIsTheSameInEveryModeAndDoesNotTalkAboutRelaysAlone() throws {
        let texts = Set(Mode.allCases.map { TransportSettingsTexts.outcomeText(.serverListUnavailable, mode: $0) })
        XCTAssertEqual(texts.count, 1, "the verdict does not depend on the mode")
        let italianText = try italian("transport_settings.outcome.server_list_unavailable")
        XCTAssertTrue(italianText.hasPrefix("NON OK:"))
        XCTAssertTrue(italianText.contains("per questa modalità non c'era nessun server da provare"))
        XCTAssertFalse(italianText.contains("elenco dei relay"), "the old text talked about the relay list, but auto and p2p use STUN servers too")
    }

    /// The three numbers keep their roles: host, srflx, relay, in that order. Distinct values make a swap visible, which
    /// the old check (the digits 4, 2 and 7 anywhere in the text) could not.
    func testTheCandidateCountsTextPutsEachNumberNextToItsOwnType() throws {
        let text = TransportSettingsTexts.candidatesText(TransportCandidateCounts(host: 4, srflx: 2, relay: 7))
        let host = try XCTUnwrap(text.range(of: #"\(host\)\s*4(?!\d)"#, options: .regularExpression), "host is not 4: \(text)")
        let srflx = try XCTUnwrap(text.range(of: #"\(srflx\)\s*2(?!\d)"#, options: .regularExpression), "srflx is not 2: \(text)")
        let relay = try XCTUnwrap(text.range(of: #"(relay|relais)\s*7(?!\d)"#, options: [.regularExpression, .caseInsensitive]),
                                  "relay is not 7: \(text)")
        XCTAssertLessThan(host.lowerBound, srflx.lowerBound, "host comes first: \(text)")
        XCTAssertLessThan(srflx.lowerBound, relay.lowerBound, "relay comes last: \(text)")

        // And the other way round: the numbers do not follow another type's label.
        let swapped = TransportSettingsTexts.candidatesText(TransportCandidateCounts(host: 7, srflx: 4, relay: 2))
        XCTAssertNotNil(swapped.range(of: #"\(host\)\s*7(?!\d)"#, options: .regularExpression), swapped)
        XCTAssertNotNil(swapped.range(of: #"\(srflx\)\s*4(?!\d)"#, options: .regularExpression), swapped)
        XCTAssertNotNil(swapped.range(of: #"(relay|relais)\s*2(?!\d)"#, options: [.regularExpression, .caseInsensitive]), swapped)
        XCTAssertNotEqual(text, swapped)
    }

    /// The same roles in every language of the catalog: each template reads "(host) n · (srflx) n · Relay n" in this order,
    /// so the order of the arguments in the code is the order of the labels.
    func testTheCandidateCountsTemplateKeepsTheOrderHostSrflxRelayInEveryLanguage() throws {
        let strings = try catalogStrings()
        for language in languages {
            let template = try XCTUnwrap(catalogValue(strings, "transport_settings.candidates.counts", language), language)
            XCTAssertNotNil(template.range(of: #"\(host\)\s*%lld.*\(srflx\)\s*%lld.*(relay|relais)\s*%lld"#,
                                           options: [.regularExpression, .caseInsensitive]),
                            "\(language): host, srflx, relay in this order, each before its own number: \(template)")
        }
        let source = try sourceText("QAudionApp/Views/Settings/TransportSettingsTexts.swift")
        XCTAssertTrue(source.contains("(host) \\(host) · Pubblici (srflx) \\(srflx) · Relay \\(relay)"),
                      "the fallback text passes host, srflx and relay to the labels of the same name")
    }

    /// A localized text without arguments that holds a percent sign can be read as a format: the screen writes no `%` in
    /// any text that has no placeholder (the URL encoding of the credentials is named, not shown).
    func testNoTextWithoutPlaceholdersHasAPercentSign() throws {
        let strings = try catalogStrings()
        let withPlaceholders: Set<String> = ["transport_settings.candidates.counts", "transport_settings.check.confirmed",
                                             "transport_settings.check.confirmed_not_ok"]
        for key in keys where !withPlaceholders.contains(key) {
            for language in languages {
                let text = try XCTUnwrap(catalogValue(strings, key, language), "\(key) \(language)")
                XCTAssertFalse(text.contains("%"), "\(key) \(language) has a percent sign: \(text)")
            }
        }
    }

    // MARK: - 1-to-1 calls, no grace period, formal German

    func testTheTextsThatTalkAboutCallsSayOneToOneInEveryLanguage() throws {
        let strings = try catalogStrings()
        for key in oneToOneKeys {
            for language in languages {
                let text = try XCTUnwrap(catalogValue(strings, key, language), "\(key) \(language)")
                let marker = try XCTUnwrap(oneToOneMarker[language])
                XCTAssertTrue(text.contains(marker), "\(key) \(language) does not say the setting is for 1-to-1 calls: \(text)")
            }
        }
        // The explanations used to start with "the call": that read as every call.
        for key in ["transport_settings.mode.turn.explanation", "transport_settings.mode.relay.explanation"] {
            let text = try italian(key)
            XCTAssertFalse(text.hasPrefix("Instrada la chiamata"), key)
            XCTAssertTrue(text.hasPrefix("Instrada le chiamate 1 a 1"), key)
        }
    }

    /// No text promises that the voice waits for the connection to recover before it goes through the server: for a call
    /// with audio on the DataChannel the very next frame is diverted, so there is no waiting period to promise.
    func testNoTextNamesAGracePeriodInAnyLanguage() throws {
        let strings = try catalogStrings()
        let fragments = ["pochi istanti", "few moments", "weniger Augenblicke", "pocos instantes", "quelques instants",
                         "poucos instantes", "ripristin", "recover", "wieder her", "restablece", "rétablit", "voltar em"]
        for key in keys {
            for language in languages {
                let text = try XCTUnwrap(catalogValue(strings, key, language), "\(key) \(language)")
                for fragment in fragments {
                    XCTAssertFalse(text.lowercased().contains(fragment.lowercased()),
                                   "\(key) \(language) names a recovery period (\(fragment)): \(text)")
                }
            }
        }
    }

    /// The German texts of the screen use "Sie", like the other German texts of the catalog.
    func testTheGermanTextsUseSieNotDu() throws {
        let strings = try catalogStrings()
        let informal = #"\b(dein|deine|deinen|deinem|deiner|deines|du|dir|dich|tippe|prüfe|verwende|wähle|gib|lass|schreibe)\b"#
        for key in keys {
            let text = try XCTUnwrap(catalogValue(strings, key, "de"), key)
            XCTAssertNil(text.range(of: informal, options: [.regularExpression, .caseInsensitive]),
                         "\(key) de uses du/dein: \(text)")
        }
        let p2p = try XCTUnwrap(catalogValue(strings, "transport_settings.mode.p2p.explanation", "de"))
        XCTAssertTrue(p2p.contains("Ihr Telefon"))
        XCTAssertTrue(p2p.contains("Ihre IP-Adresse"))
        XCTAssertTrue(try XCTUnwrap(catalogValue(strings, "transport_settings.address.note.p2p", "de")).contains("Ihr Telefon"))
        XCTAssertTrue(try XCTUnwrap(catalogValue(strings, "transport_settings.outcome.ok_p2p", "de")).contains("Ihr Telefon"))
        XCTAssertTrue(try XCTUnwrap(catalogValue(strings, "transport_settings.route.custom_server", "de")).contains("Ihnen"))
        XCTAssertTrue(try XCTUnwrap(catalogValue(strings, "transport_settings.check.not_saved", "de")).contains("Tippen Sie"))
        XCTAssertTrue(try XCTUnwrap(catalogValue(strings, "transport_settings.outcome.no_candidates", "de")).contains("prüfen Sie"))
    }

    // MARK: - "Il controllo è stato fatto con una modalità o un indirizzo non ancora salvati"

    /// The note appears when the checked mode OR the checked address differs from the saved one
    /// (`TransportChoiceTests.test_theNotSavedNoteAlsoFollowsAChangeOfTheAddressAloneAndOfTheModeAlone`), so the text names
    /// both instead of saying "this mode" when only the address changed.
    func testTheNotSavedNoteNamesTheModeAndTheAddress() throws {
        let italianText = try italian("transport_settings.check.not_saved")
        XCTAssertTrue(italianText.contains("una modalità o un indirizzo non ancora salvati"))
        XCTAssertTrue(italianText.contains("premi Salva"))
        XCTAssertFalse(italianText.contains("Questa modalità non è ancora salvata"), "the old text: wrong when only the address changed")
        let strings = try catalogStrings()
        let addressWord = ["it": "indirizzo", "en": "address", "de": "Adresse", "es": "dirección", "fr": "adresse", "pt-BR": "endereço"]
        for language in languages {
            let translated = try XCTUnwrap(catalogValue(strings, "transport_settings.check.not_saved", language))
            XCTAssertTrue(translated.lowercased().contains(try XCTUnwrap(addressWord[language]).lowercased()),
                          "\(language) names only the mode: \(translated)")
        }
    }

    // MARK: - TransportGate (what "Salva" writes is what the calls read)

    private var savedMode: Any?
    private var savedUrl: Any?
    private var savedCredentialStore: TransportTurnCredentialStore = KeychainTransportTurnCredentialStore()
    /// The Keychain stand-in the gate uses during a test: the app test bundle must not touch the real Keychain.
    private var credentials = InMemoryTransportTurnCredentialStore()

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.object(forKey: TransportGate.keyPreferredMode)
        savedUrl = UserDefaults.standard.object(forKey: TransportGate.keyPreferredTurnUrl)
        UserDefaults.standard.removeObject(forKey: TransportGate.keyPreferredMode)
        UserDefaults.standard.removeObject(forKey: TransportGate.keyPreferredTurnUrl)
        savedCredentialStore = TransportGate.credentialStore
        credentials = InMemoryTransportTurnCredentialStore()
        TransportGate.credentialStore = credentials
    }

    override func tearDown() {
        TransportGate.credentialStore = savedCredentialStore
        UserDefaults.standard.set(savedMode, forKey: TransportGate.keyPreferredMode)
        UserDefaults.standard.set(savedUrl, forKey: TransportGate.keyPreferredTurnUrl)
        super.tearDown()
    }

    func testTheGateDefaultsToAutoAndForcesNoRelay() {
        XCTAssertEqual(TransportGate.mode, .auto)
        XCTAssertEqual(TransportGate.preferredMode, "auto")
        XCTAssertFalse(TransportGate.forcesRelay)
        XCTAssertNil(TransportGate.preferredTurnUrl)
        XCTAssertEqual(TransportGate.plan().route, .serverPool)
    }

    func testTheGateReadsWhatSaveWrote() {
        let expectedForce: [Mode: Bool] = [.auto: false, .p2p: false, .turn: true, .relay: true]
        for mode in Mode.allCases {
            TransportGate.save(mode: mode, customTurnUrl: nil)
            XCTAssertEqual(TransportGate.mode, mode)
            XCTAssertEqual(TransportGate.preferredMode, mode.rawValue)
            XCTAssertEqual(TransportGate.forcesRelay, expectedForce[mode], "\(mode)")
        }
        TransportGate.save(mode: .relay, customTurnUrl: URL(string: customServer))
        XCTAssertEqual(TransportGate.preferredTurnUrl?.absoluteString, customServer)
        XCTAssertEqual(TransportGate.plan().route, .customServer)
        TransportGate.save(mode: .relay, customTurnUrl: nil)
        XCTAssertNil(TransportGate.preferredTurnUrl)
        XCTAssertEqual(TransportGate.plan(bridgeAvailable: true).route, .wssBridge)
        XCTAssertEqual(TransportGate.plan(bridgeAvailable: false).route, .poolTurnFallback)
    }

    /// "Salva" keeps the address in UserDefaults and the user name and password in the Keychain, never in UserDefaults; the
    /// calls get the whole server back from the two.
    func testTheGateKeepsOnlyTheAddressInUserDefaults() {
        XCTAssertTrue(TransportGate.save(mode: .turn, customTurnUrl: URL(string: customServer)))
        XCTAssertEqual(UserDefaults.standard.string(forKey: TransportGate.keyPreferredTurnUrl),
                       "turn:custom.example.test:3478")
        XCTAssertEqual(credentials.credentials(forHost: "custom.example.test"),
                       TransportTurnCredentials(username: "custom-user", password: "custom-secret"))
        XCTAssertEqual(TransportGate.preferredTurnUrl?.absoluteString, customServer)
    }

    /// An address saved by an earlier build had no credentials: the calls read it as no address.
    func testTheGateIgnoresAnAddressStoredWithoutCredentials() {
        UserDefaults.standard.set("turn:custom.example.test:3478", forKey: TransportGate.keyPreferredTurnUrl)
        XCTAssertNil(TransportGate.preferredTurnUrl)
        TransportGate.save(mode: .turn, customTurnUrl: nil)
        UserDefaults.standard.set("turn:custom.example.test:3478", forKey: TransportGate.keyPreferredTurnUrl)
        XCTAssertEqual(TransportGate.plan().route, .poolTurn, "the pool is used, not a TURN server without credentials")
    }

    func testTheGateStillReadsTheKeysEarlierBuildsWrote() {
        UserDefaults.standard.set("turn", forKey: "qaudion.transport.preferred_mode")
        XCTAssertTrue(TransportGate.forcesRelay)
        XCTAssertEqual(TransportGate.mode, .turn)
    }

    // MARK: - Source lookup

    private func literalKeys(in source: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(source)
        let marker = "String(localized: \"transport_settings."
        while let r = rest.range(of: marker) {
            let afterQuote = rest[r.upperBound...]
            guard let end = afterQuote.firstIndex(of: "\"") else { break }
            keys.append("transport_settings." + String(afterQuote[afterQuote.startIndex..<end]))
            rest = afterQuote[end...]
        }
        return keys
    }

    /// `key -> defaultValue` of every `String(localized: "key", defaultValue: "...", comment: ...)`, an interpolation
    /// `\(name)` replaced by its placeholder (`%lld` for the counts, `%@` for the names).
    private func defaultValues(in source: String) -> [String: String] {
        var out: [String: String] = [:]
        let keyMarker = "String(localized: \"transport_settings."
        let valueMarker = "defaultValue: \""
        var rest = Substring(source)
        while let k = rest.range(of: keyMarker) {
            let afterKey = rest[k.upperBound...]
            guard let keyEnd = afterKey.firstIndex(of: "\"") else { break }
            let key = "transport_settings." + String(afterKey[afterKey.startIndex..<keyEnd])
            let afterKeyText = afterKey[keyEnd...]
            guard let v = afterKeyText.range(of: valueMarker) else { break }
            var value = ""
            var index = v.upperBound
            while index < afterKeyText.endIndex {
                let ch = afterKeyText[index]
                if ch == "\\" {
                    // "\(name)": read up to the closing parenthesis.
                    let next = afterKeyText.index(after: index)
                    if next < afterKeyText.endIndex, afterKeyText[next] == "(",
                       let close = afterKeyText[next...].firstIndex(of: ")") {
                        let name = String(afterKeyText[afterKeyText.index(after: next)..<close])
                        value += ["host", "srflx", "relay"].contains(name) ? "%lld" : "%@"
                        index = afterKeyText.index(after: close)
                        continue
                    }
                }
                if ch == "\"" { break }
                value.append(ch)
                index = afterKeyText.index(after: index)
            }
            out[key] = value
            rest = afterKeyText[index...]
        }
        return out
    }

    private struct SourceNotFound: Error {}

    private func sourceDirectory(_ relativePath: String, file: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(file)")
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        XCTFail("\(relativePath) not found from \(file)")
        throw SourceNotFound()
    }

    private func sourceText(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let url = try sourceDirectory(relativePath, file: file)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

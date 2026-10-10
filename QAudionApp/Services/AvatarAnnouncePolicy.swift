import Foundation
import CryptoKit
import QAudionEngine

/// Quando l'avatar proprio si invia a un contatto: la decisione, senza effetti collaterali, e il registro di cio' che e' gia'
/// stato inviato. `AvatarAnnounceCoordinator` le usa; sono separate perche' si provano senza rete, senza Keychain e senza
/// orologio di sistema.
///
/// Ridurre traffico e riapplicazioni dell'avatar: l'avatar si invia solo se serve. Ogni invio e' un file nuovo piu' un messaggio di
/// chat al contatto, quindi ogni invio inutile costa spazio sul server e una consegna al destinatario. Prima lo stesso avatar
/// veniva rimandato a ogni chiamata, due volte.
///
/// Regola. Si ricorda, per contatto, l'impronta del CONTENUTO (SHA-256 dei byte) dell'ultimo avatar inviato con successo e
/// l'identificativo breve della chiave a coppia di quel momento. I momenti in cui si controlla (messaggio decifrato, chiamata
/// connessa, scambio chiavi completato, foto cambiata) non inviano per il solo fatto di ripetersi: si invia solo se
///  1. l'utente ha cambiato foto (`.avatarChanged`, azione esplicita): sempre;
///  2. il contenuto di adesso e' diverso da quello inviato a quel contatto (`why=1`);
///  3. a quel contatto non si e' mai inviato, o la chiave a coppia e' cambiata da allora, cioe' ha un'installazione o un
///     dispositivo nuovo (`why=2`);
///  4. in futuro, se il contatto segnala che gli manca (`why=3`): vedi `peerRequested`, non collegato.
/// Non si invia nei primi `callGuardSec` secondi di una chiamata. Dopo un tentativo verso un contatto, riuscito o no, non se ne fa un
/// altro prima di `attemptBrakeSec`: e' un freno contro le raffiche (per esempio un invio che fallisce a ogni messaggio ricevuto
/// mentre la rete e' giu'), non un criterio per rimandare lo stesso avatar.
///
/// Dispositivo del contatto. L'invio e' indirizzato all'utente (`ChatMessageSendService.sendEncrypted`, `recipientId`), non a un
/// suo dispositivo, e l'identificativo di dispositivo del contatto lo conosce l'app solo dall'ultima chiamata in arrivo
/// (`AppState.peerDeviceId(for:)`), non in modo stabile. Come segnale di "installazione o dispositivo nuovo" si usa quindi la chiave
/// a coppia dello scambio chiavi, che una reinstallazione cambia (nuova identita', nuovo scambio). Se non c'e' (contatto raggiunto
/// solo con la chiave derivata da una chiamata) la chiave non e' un segnale e decide solo il contenuto.
///
/// Perche' la chiave a coppia e non "ogni scambio chiavi". `ContactKeyExchange.deriveAndStore` (ContactKeyExchange.swift:166-227)
/// deriva la chiave in modo deterministico dalle due identita' e, se l'impronta e' uguale a quella gia' nel Keychain, esce senza
/// scrivere ne' chiamare `onKeyExchanged` (righe 220-223): lo scambio che `endCall` fa a ogni chiamata (`triggerKeyExchange`, AppState.swift:21350) non
/// cambia nulla e non puo' essere preso come "chiave nuova". Cambia l'impronta, e quindi scatta l'evento (righe 226-227), solo se
/// cambia una delle due identita' (reinstallazione, telefono nuovo). Piuttosto che agganciarsi all'evento (che non sopravvive a un
/// riavvio e si perde se l'app e' chiusa) si confronta l'impronta ricordata all'ultimo invio con quella di adesso, che il Keychain
/// tiene come etichetta della voce: lo stesso segnale, ricostruibile in ogni momento. Il passaggio da "nessuna chiave" a "chiave
/// presente" non conta come cambio: il contatto aveva gia' ricevuto l'avatar con la chiave derivata dalla chiamata.
///
/// Inviato ma non arrivato. Il marcatore (`AvatarSentLedger.markSent`) si scrive quando il server ha accettato il messaggio col
/// descrittore, non quando il contatto l'ha ricevuto: per l'avatar non c'e' una ricevuta di consegna (chi lo riceve non ne manda).
/// Si accetta il compromesso, e non si reintroduce un invio ripetuto a tempo: un contatto che ha perso l'avatar lo riavra' quando
/// cambia il contenuto, la chiave a coppia, o quando ci sara' il segnale del punto 4. Un invio che fallisce prima di quel punto
/// (rete assente, nessun canale, caricamento fallito) non viene marcato e si riprova al primo momento utile dopo il freno.
///
/// Ricevuta di consegna. Esiste: `msg_delivered` (`AppState.handleDeliveryReceipts`), che cerca la riga della conversazione per
/// identificativo del server. Il messaggio dell'avatar non scrive una riga in `ConversationStore`, quindi la ricevuta risulta
/// "unmatched" e non conferma nulla. Si potrebbe collegare (`sendEncrypted` restituisce l'identificativo del server, oggi
/// scartato da `FileV2AvatarSender`), ma farne la condizione per marcare reintrodurrebbe l'invio ripetuto: la ricevuta arriva solo
/// quando il dispositivo del contatto svuota la sua coda, e un contatto spento la farebbe aspettare a lungo. Per questo il
/// marcatore e' l'accettazione del messaggio da parte del server.
enum AvatarAnnouncePolicy {

    /// Nei primi secondi di una chiamata non si invia (la chiamata ha altro da fare); a chiamata aperta da piu' tempo si'.
    static let callGuardSec: TimeInterval = 90
    /// Tempo minimo tra due tentativi di invio allo stesso contatto (solo freno: l'avatar uguale non si rimanda in nessun caso).
    static let attemptBrakeSec: TimeInterval = 120

    /// Perche' si invia. Il numero e' quello del log (`why=`).
    enum SendCause: Int, Equatable {
        /// Il contenuto e' cambiato (o l'utente ha cambiato foto).
        case changed = 1
        /// Mai inviato a questo contatto, o chiave a coppia cambiata: installazione o dispositivo nuovo.
        case newPeerDevice = 2
        /// Riservato: il contatto ha segnalato che gli manca. Non collegato.
        case requested = 3
    }

    /// Perche' non si invia. Il numero e' quello del log (`code=`).
    enum SkipCause: Equatable {
        /// Stesso contenuto, stessa chiave a coppia: il contatto ce l'ha gia'.
        case same
        /// Nei primi secondi di una chiamata.
        case callGuard
        /// Un tentativo verso questo contatto e' appena finito (riuscito o no): freno anti-raffica.
        case brake

        var code: Int {
            switch self {
            case .same: return 4
            case .callGuard, .brake: return 5
            }
        }
    }

    enum Verdict: Equatable {
        case send(SendCause)
        case skip(SkipCause)
    }

    /// Cosa e' uscito dal telefono l'ultima volta verso quel contatto.
    struct SentState: Equatable {
        var contentHash: String?
        var pairKey: String?
        init(contentHash: String? = nil, pairKey: String? = nil) {
            self.contentHash = contentHash
            self.pairKey = pairKey
        }
    }

    /// - Parameters:
    ///   - currentHash: impronta del contenuto che si invierebbe adesso.
    ///   - currentPairKey: chiave a coppia di adesso (`AvatarSentLedger.noPairKey` se non ce n'e' una).
    ///   - prior: `nil` o con impronta `nil` se a quel contatto non si e' mai inviato.
    ///   - callAgeSec: secondi dall'inizio della chiamata in corso, `nil` se non ce n'e' una.
    ///   - lastAttemptAgeSec: secondi dalla fine dell'ultimo tentativo di invio a questo contatto, `nil` se non ce ne sono stati
    ///     da quando l'app e' partita. Frena un nuovo invio, mai la foto cambiata dall'utente.
    ///   - peerRequested: punto d'ingresso del segnale "al contatto manca l'avatar" (punto 4 sopra). Nessun chiamante lo imposta
    ///     ancora: serve prima un segnale sul filo, da decidere a parte.
    static func decide(
        trigger: AvatarAnnounceCoordinator.Trigger,
        currentHash: String,
        currentPairKey: String,
        prior: SentState?,
        callAgeSec: TimeInterval?,
        lastAttemptAgeSec: TimeInterval? = nil,
        peerRequested: Bool = false
    ) -> Verdict {
        if trigger == .avatarChanged { return .send(.changed) }
        if let callAgeSec, callAgeSec < callGuardSec { return .skip(.callGuard) }
        let needed = need(currentHash: currentHash, currentPairKey: currentPairKey, prior: prior, peerRequested: peerRequested)
        if case .send = needed, let lastAttemptAgeSec, lastAttemptAgeSec < attemptBrakeSec { return .skip(.brake) }
        return needed
    }

    private static func need(
        currentHash: String, currentPairKey: String, prior: SentState?, peerRequested: Bool
    ) -> Verdict {
        if peerRequested { return .send(.requested) }
        guard let priorHash = prior?.contentHash else { return .send(.newPeerDevice) }
        if let priorKey = prior?.pairKey, priorKey != AvatarSentLedger.noPairKey,
           currentPairKey != AvatarSentLedger.noPairKey, priorKey != currentPairKey {
            return .send(.newPeerDevice)
        }
        return priorHash == currentHash ? .skip(.same) : .send(.changed)
    }
}

/// Impronta del contenuto di un avatar: SHA-256 dei byte, in esadecimale minuscolo. Resta sul dispositivo (UserDefaults), non esce.
enum AvatarContentHash {
    static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Registro, per contatto, di cio' che e' uscito dal telefono: impronta del contenuto e chiave a coppia dell'ultimo invio, piu' la
/// versione e l'ora (stesse chiavi `UserDefaults` di prima: lo stato esistente resta leggibile).
struct AvatarSentLedger {

    // W-AVATARSTUCK (2026-07-31): chiavi `.v2`; quelle precedenti sono orfane di proposito, mai migrate.
    static let versionsKey = "qaudion.avatarSentVersions.v2"
    static let sentAtKey = "qaudion.avatarSentAt.v2"
    static let pairKeysKey = "qaudion.avatarSentPairKey.v1"
    static let hashesKey = "qaudion.avatarSentHash.v1"

    /// Valore registrato quando non c'e' una chiave di scambio chiavi per il contatto.
    static let noPairKey = "-"
    /// Quanti caratteri dell'impronta della chiave si tengono: bastano per riconoscere un cambio e non dicono nulla della chiave.
    static let pairKeyIdLength = 16

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastVersionSent(toPeer peerId: String) -> Int {
        let dict = defaults.dictionary(forKey: Self.versionsKey) as? [String: Int] ?? [:]
        return dict[peerId] ?? -1
    }

    func lastSentAt(toPeer peerId: String) -> Date? {
        let dict = defaults.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
        guard let ts = dict[peerId] else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    func sentState(toPeer peerId: String) -> AvatarAnnouncePolicy.SentState {
        AvatarAnnouncePolicy.SentState(contentHash: string(Self.hashesKey, peerId), pairKey: string(Self.pairKeysKey, peerId))
    }

    func markSent(version: Int, contentHash: String, pairKey: String, toPeer peerId: String, at: Date) {
        var versions = defaults.dictionary(forKey: Self.versionsKey) as? [String: Int] ?? [:]
        versions[peerId] = version
        defaults.set(versions, forKey: Self.versionsKey)
        var times = defaults.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
        times[peerId] = at.timeIntervalSince1970
        defaults.set(times, forKey: Self.sentAtKey)
        set(contentHash, Self.hashesKey, peerId)
        set(pairKey, Self.pairKeysKey, peerId)
    }

    /// Un invio fatto prima che si registrasse l'impronta, della versione di adesso: il contenuto e' lo stesso (la versione cambia a
    /// ogni nuova foto), quindi si adotta l'impronta di adesso come punto di partenza invece di rimandare a tutti i contatti
    /// all'aggiornamento. Non tocca versione e ora dell'ultimo invio.
    func adoptBaseline(contentHash: String, pairKey: String, toPeer peerId: String) {
        set(contentHash, Self.hashesKey, peerId)
        set(pairKey, Self.pairKeysKey, peerId)
    }

    /// Aggiorna solo la chiave a coppia ricordata (per esempio quando prima non c'era e adesso c'e'), senza toccare l'impronta.
    func recordPairKey(_ pairKey: String, toPeer peerId: String) {
        set(pairKey, Self.pairKeysKey, peerId)
    }

    private func string(_ key: String, _ peerId: String) -> String? {
        (defaults.dictionary(forKey: key) as? [String: String])?[peerId]
    }

    private func set(_ value: String, _ key: String, _ peerId: String) {
        var dict = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        dict[peerId] = value
        defaults.set(dict, forKey: key)
    }

    /// Identificativo breve, non segreto, della chiave che lo scambio chiavi ha legato al contatto. Non si deriva dalla chiave e non
    /// la legge: e' l'impronta che il Keychain conserva gia' come etichetta della voce (`SovereignKeyVault.getFingerprint`, la
    /// stessa che si pubblicizza ai contatti), troncata. Cambia solo se la voce viene sostituita da una chiave diversa (nuova
    /// coppia di identita') o sparisce.
    ///
    /// Si guarda la voce dello scambio chiavi (`auto:`) e non la "piu' recente" del `PairwiseChainKeyResolver`: quella cambia a
    /// ogni chiamata, perche' ogni chiamata ne deriva una nuova uguale su entrambi i lati, e farebbe risultare "cambiata" la
    /// chiave a ogni chiamata. Il nome ripete quello di `ContactKeyExchange.keyName(for:)` e del resolver.
    static func vaultPairKeyId(peerId: String) -> String {
        let prefix = peerId.count > 8 ? String(peerId.prefix(8)) : peerId
        let name = "auto:" + prefix + ":" + peerId
        return pairKeyId(fingerprint: SovereignKeyVault().getFingerprint(name: name))
    }

    /// Parte pura di `vaultPairKeyId`, per provarla senza Keychain.
    static func pairKeyId(fingerprint: String?) -> String {
        guard let fingerprint, !fingerprint.isEmpty else { return noPairKey }
        return String(fingerprint.prefix(pairKeyIdLength))
    }
}

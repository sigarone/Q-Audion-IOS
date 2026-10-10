import Foundation
import QAudionEngine

/// Quando l'avatar proprio si rimanda a un contatto: la decisione, senza effetti collaterali, e il registro di cio' che e' gia'
/// stato inviato. `AvatarAnnounceCoordinator` le usa; sono separate perche' si provano senza rete, senza Keychain e senza
/// orologio di sistema.
///
/// Ridurre traffico e riapplicazioni dell'avatar. Ogni invio e' un file nuovo piu' un messaggio di chat verso il contatto, quindi
/// ogni invio inutile costa spazio sul server e una consegna al destinatario. Prima un avatar invariato veniva rimandato a ogni
/// chiamata, due volte (alla connessione e dopo lo scambio chiavi di fine chiamata). Ora:
///
///  1. Lo scambio chiavi non rimanda un avatar se la versione e la chiave a coppia (vedi `AvatarSentLedger.pairKeyId`) sono quelle
///     dell'ultimo invio riuscito a quel contatto.
///  2. A parita' di versione e di chiave, un nuovo invio alla connessione di una chiamata aspetta `callResendIntervalSec`
///     (prima 2 minuti).
///
/// Cosa si perde. Un invio riuscito dimostra che il messaggio e' uscito dal telefono, non che il contatto l'ha ricevuto e
/// decifrato: il rinvio periodico a parita' di versione serve da auto-guarigione. Con i valori nuovi un contatto che ha perso
/// l'avatar (messaggio non decifrato, app reinstallata, cache svuotata) lo riavra' alla prima occasione utile dopo
/// `callResendIntervalSec` (una chiamata, o un messaggio dopo `chatResendIntervalSec`), non a ogni chiamata. Se l'avatar cambia
/// (versione nuova) o la chiave a coppia cambia, si invia subito come prima.
enum AvatarAnnouncePolicy {

    /// Trigger in background (messaggio decifrato): resta a un'ora.
    static let chatResendIntervalSec: TimeInterval = 60 * 60
    /// Trigger di chiamata e di scambio chiavi, a parita' di versione e di chiave a coppia: 6 ore. Una sessione d'uso dura meno,
    /// quindi in una giornata il rinvio di auto-guarigione scatta al massimo poche volte invece che a ogni chiamata; resta molto
    /// sotto i 3 giorni che si erano dimostrati un rinvio che non scatta mai nell'uso normale.
    static let callResendIntervalSec: TimeInterval = 6 * 60 * 60

    static func cooldownSec(for trigger: AvatarAnnounceCoordinator.Trigger) -> TimeInterval {
        switch trigger {
        case .chatDecrypt:   return chatResendIntervalSec
        case .callConnect:   return callResendIntervalSec
        case .keyExchange:   return callResendIntervalSec
        case .avatarChanged: return 0
        }
    }

    enum SendCause: Equatable {
        /// La versione propria e' piu' avanti dell'ultima inviata (o non e' mai stata inviata).
        case versionAhead
        /// Il trigger non ha cooldown (l'utente ha appena cambiato foto).
        case noCooldown
        /// La chiave a coppia e' diversa da quella dell'ultimo invio.
        case pairKeyChanged
        /// Stessa versione e stessa chiave, ma il cooldown del trigger e' trascorso (o l'ora dell'ultimo invio manca).
        case cooldownElapsed
    }

    enum SkipCause: Equatable {
        /// Stessa versione, il cooldown del trigger non e' trascorso.
        case withinCooldown
        /// Scambio chiavi con versione e chiave a coppia identiche all'ultimo invio riuscito: nessun cooldown, non si rimanda.
        case pairKeyUnchanged
    }

    enum Verdict: Equatable {
        case send(SendCause)
        case skip(SkipCause)
    }

    /// - Parameters:
    ///   - priorVersion: ultima versione inviata a quel contatto (-1 se mai).
    ///   - priorPairKey: chiave a coppia registrata all'ultimo invio; `nil` per un invio fatto prima che si registrasse (in quel
    ///     caso decide solo il cooldown, per non provocare un rinvio a tutti i contatti all'aggiornamento).
    ///   - currentPairKey: chiave a coppia di adesso (`AvatarSentLedger.noPairKey` se non ce n'e' una).
    static func decide(
        trigger: AvatarAnnounceCoordinator.Trigger,
        version: Int,
        priorVersion: Int,
        priorSentAt: Date?,
        priorPairKey: String?,
        currentPairKey: String,
        now: Date
    ) -> Verdict {
        guard priorVersion >= version else { return .send(.versionAhead) }
        let cooldown = cooldownSec(for: trigger)
        if cooldown <= 0 { return .send(.noCooldown) }
        if let priorPairKey, priorPairKey != currentPairKey { return .send(.pairKeyChanged) }
        if trigger == .keyExchange, priorPairKey != nil { return .skip(.pairKeyUnchanged) }
        guard let priorSentAt else { return .send(.cooldownElapsed) }
        return now.timeIntervalSince(priorSentAt) >= cooldown ? .send(.cooldownElapsed) : .skip(.withinCooldown)
    }
}

/// Registro, per contatto, di cio' che e' uscito dal telefono: versione, ora e chiave a coppia dell'ultimo invio. Stesse chiavi
/// `UserDefaults` di prima per versione e ora (lo stato esistente resta valido); la chiave a coppia e' una chiave nuova.
struct AvatarSentLedger {

    // W-AVATARSTUCK (2026-07-31): chiavi `.v2`; quelle precedenti sono orfane di proposito, mai migrate.
    static let versionsKey = "qaudion.avatarSentVersions.v2"
    static let sentAtKey = "qaudion.avatarSentAt.v2"
    static let pairKeysKey = "qaudion.avatarSentPairKey.v1"

    /// Valore registrato quando non c'e' una chiave di scambio chiavi per il contatto.
    static let noPairKey = "-"
    /// Quanti caratteri dell'impronta si tengono: bastano per riconoscere un cambio e non dicono nulla della chiave.
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

    func lastPairKey(toPeer peerId: String) -> String? {
        let dict = defaults.dictionary(forKey: Self.pairKeysKey) as? [String: String] ?? [:]
        return dict[peerId]
    }

    func markSent(version: Int, pairKey: String, toPeer peerId: String, at: Date) {
        var versions = defaults.dictionary(forKey: Self.versionsKey) as? [String: Int] ?? [:]
        versions[peerId] = version
        defaults.set(versions, forKey: Self.versionsKey)
        var times = defaults.dictionary(forKey: Self.sentAtKey) as? [String: Double] ?? [:]
        times[peerId] = at.timeIntervalSince1970
        defaults.set(times, forKey: Self.sentAtKey)
        var pairKeys = defaults.dictionary(forKey: Self.pairKeysKey) as? [String: String] ?? [:]
        pairKeys[peerId] = pairKey
        defaults.set(pairKeys, forKey: Self.pairKeysKey)
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

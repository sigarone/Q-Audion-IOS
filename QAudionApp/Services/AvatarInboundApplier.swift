import Foundation

/// Controllo di completezza dei byte di un avatar ricevuto, prima di applicarlo.
///
/// `UIImage(data:)` accetta anche un JPEG troncato (mostra la parte decodificata): un avatar tagliato a meta' sovrascriverebbe
/// quello buono. Un JPEG completo finisce con il marcatore EOI (FF D9), un PNG completo con il chunk IEND. Qualche trasporto
/// accoda byte nulli di riempimento: se ne tollerano pochi in coda. Gli altri formati (che l'app stessa non invia) non hanno un
/// controllo di fine e restano accettati se `UIImage` li decodifica.
enum AvatarImageIntegrity {

    enum Verdict: Equatable {
        case complete
        /// `kind`: 1 = JPEG, 2 = PNG. I byte iniziano come quel formato ma non finiscono come deve.
        case incomplete(kind: Int)
        /// Ne' JPEG ne' PNG: nessun controllo di fine possibile.
        case unknownFormat
    }

    /// Byte nulli in coda che si ignorano prima di guardare la fine del file.
    static let maxTrailingPadding = 64

    private static let jpegStart: [UInt8] = [0xFF, 0xD8, 0xFF]
    private static let jpegEnd: [UInt8] = [0xFF, 0xD9]
    private static let pngStart: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    /// Lunghezza 0, tipo "IEND", CRC fisso del chunk vuoto.
    private static let pngEnd: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]

    static func check(_ data: Data) -> Verdict {
        let bytes = [UInt8](data)
        if bytes.starts(with: jpegStart) {
            return endsWith(jpegEnd, in: bytes) ? .complete : .incomplete(kind: 1)
        }
        if bytes.starts(with: pngStart) {
            return endsWith(pngEnd, in: bytes) ? .complete : .incomplete(kind: 2)
        }
        return .unknownFormat
    }

    /// `true` se `tail` e' la fine di `bytes`, ignorando fino a `maxTrailingPadding` byte nulli in coda.
    private static func endsWith(_ tail: [UInt8], in bytes: [UInt8]) -> Bool {
        var end = bytes.count
        var skipped = 0
        while end > 0, bytes[end - 1] == 0x00, skipped < maxTrailingPadding {
            end -= 1
            skipped += 1
        }
        guard end >= tail.count else { return false }
        return Array(bytes[(end - tail.count)..<end]) == tail
    }
}

/// Applica i byte di un avatar ricevuto (decifrati) come immagine del contatto, oppure no. Tutto cio' che tocca il disco, i contatti
/// e l'aggiornamento delle viste e' dietro un closure, cosi' si prova senza Keychain ne' file: `AvatarAnnounceCoordinator` lo costruisce con i
/// closure veri.
///
/// Ridurre le riapplicazioni. Un avatar identico a quello gia' presente non cambia nulla: niente riscrittura del file, niente nuova
/// versione, niente aggiornamento delle viste. Il descrittore del file non porta un'impronta del contenuto (solo la dimensione e,
/// opzionale, le misure in pixel: non bastano a riconoscere lo stesso avatar), quindi il file si scarica comunque; il confronto e' sul
/// contenuto decifrato (SHA-256 dei byte ricevuti, ricordata per mittente).
///
/// Ridurre lo spazio. Un avatar ricevuto molto piu' grande della regola (`AvatarImageRule`) si mostra comunque, ma in cache se ne
/// tiene una copia ridimensionata (`reduce`): non si tengono megabyte per contatto. Per questo il confronto non e' solo col file in
/// cache, che dopo la riduzione ha altri byte, ma con l'impronta dei byte ricevuti.
struct AvatarInboundApplier {

    enum Outcome: Equatable {
        /// Scritto e registrato con questa versione; le viste sono state avvisate.
        case applied(version: Int)
        /// Stesso contenuto di quello gia' presente: non si e' cambiato nulla.
        case identical
        /// Fine mancante (vedi `AvatarImageIntegrity`): l'avatar precedente e' intatto e la versione non e' avanzata.
        case incomplete(kind: Int)
        /// Non e' un'immagine decodificabile.
        case undecodable
        /// Il contatto non ha accettato la nuova versione (o il salvataggio non e' riuscito): il file e' scritto, le viste non
        /// sono state avvisate.
        case notPersisted(version: Int)
    }

    /// `true` se `UIImage` decodifica i byte.
    let decodes: (Data) -> Bool
    /// Contenuto del file dell'avatar del contatto adesso, se c'e'.
    let readCurrent: () -> Data?
    /// Scrive il file dell'avatar del contatto (atomico).
    let write: (Data) throws -> Void
    /// Versione dell'avatar del contatto, -1 se non ne ha ancora uno applicato.
    let cachedVersion: () -> Int
    /// Registra il file come avatar del contatto con questa versione; `false` se non e' stato accettato.
    let setLocalPath: (Int) -> Bool
    /// Avvisa le viste.
    let notify: () -> Void
    let now: () -> Date
    /// Impronta (SHA-256 esadecimale) dei byte dell'ultimo avatar applicato per questo mittente, prima della riduzione.
    var lastReceivedHash: () -> String? = { nil }
    var saveReceivedHash: (String) -> Void = { _ in }
    /// La copia da tenere in cache dei byte ricevuti (ridimensionata se serve); gli stessi byte se non cambia nulla o non si riesce.
    var reduce: (Data) -> Data = { $0 }

    func apply(_ data: Data) throws -> Outcome {
        guard decodes(data) else { return .undecodable }
        if case .incomplete(let kind) = AvatarImageIntegrity.check(data) {
            return .incomplete(kind: kind)
        }
        let cached = cachedVersion()
        let receivedHash = AvatarContentHash.hex(of: data)
        if cached >= 0, let current = readCurrent(), current == data || lastReceivedHash() == receivedHash {
            return .identical
        }
        try write(reduce(data))
        // Il descrittore non porta una versione: l'avatar si applica come il piu' recente annunciato, con l'ora di arrivo come
        // versione, mai sotto l'ultima.
        let version = max(cached + 1, Int(now().timeIntervalSince1970))
        guard setLocalPath(version) else { return .notPersisted(version: version) }
        saveReceivedHash(receivedHash)
        notify()
        return .applied(version: version)
    }
}

/// Impronta dell'ultimo avatar ricevuto da ogni mittente (prima della riduzione), per riconoscere lo stesso avatar anche quando il file
/// in cache ha altri byte perche' e' stato ridimensionato. Resta sul dispositivo.
struct AvatarReceivedLedger {

    static let key = "qaudion.avatarRecvHash.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hash(fromPeer peerId: String) -> String? {
        (defaults.dictionary(forKey: Self.key) as? [String: String])?[peerId]
    }

    func save(_ hash: String, fromPeer peerId: String) {
        var dict = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        dict[peerId] = hash
        defaults.set(dict, forKey: Self.key)
    }
}

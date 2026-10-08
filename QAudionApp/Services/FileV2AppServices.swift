import Foundation
import QAudionEngine

/// File transfer v2 in the app (WIRE_SPEC section 12, the server's parts protocol): the glue between the engine's
/// pipelines (`FileV2Sender`, `FileV2Receiver`, in `QAudionEngine/FileV2Transfer`) and the chat. Nothing here touches a key, a
/// token or an object id except to pass it on, and nothing here prints one.
enum FileV2AppServices {

    /// The client of the parts protocol, built from what the app's authenticated REST client already holds (the way the tus
    /// client is): its `URLSession` (so the same TLS pinning), the certificate-pinned primary server (the node that stores the
    /// files: `files.db` and the blobs are not replicated, so a file request never rides the node selector), a closure that reads
    /// the CURRENT access token, and the closure that runs the session recovery (one refresh and one repeat on a 401).
    @MainActor
    static func makeServer(appState: AppState) -> FileV2Server {
        let rest = appState.makeUploadProvider().getRestClient()
        return FileV2HTTPServer(
            session: rest.urlSession,
            serverURL: rest.pinnedPrimaryServerUrl,
            getToken: { rest.accessToken },
            refreshToken: { try await rest.refreshAccessTokenForExternalClient() })
    }

    /// The mime type of a picked file, from its extension (the descriptor's `mt`; the receiver never trusts it for anything but a
    /// label). `application/octet-stream` when it is not known.
    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "zip": return "application/zip"
        case "txt": return "text/plain"
        case "csv": return "text/csv"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return "application/octet-stream"
        }
    }

    /// The size of a file to send, or the failure that says why it cannot be sent (checked BEFORE a row is shown or anything is
    /// created on the server). The caller holds the security-scoped access to `url`.
    static func sendableSize(of url: URL) -> Result<UInt64, FileV2Failure> {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber, number.int64Value >= 0 else {
            return .failure(FileV2Failure(.unreadable))
        }
        let size = UInt64(number.int64Value)
        if size == 0 { return .failure(FileV2Failure(.emptyFile)) }
        if size > FileV2.maxSize { return .failure(FileV2Failure(.fileTooLarge)) }
        return .success(size)
    }
}

// MARK: - What the user reads

/// The ONE place that turns a v2 file failure into a sentence the user can act on. Italian is the source language; the English
/// (and any other) text is in `Localizable.xcstrings`, keyed `file_v2.*`.
enum FileV2FailureText {

    static func message(for failure: FileV2Failure) -> String {
        switch failure.reason {
        case .emptyFile:
            return String(localized: "file_v2.fail.empty", defaultValue: "Il file è vuoto.", comment: "File transfer error: the picked file has no content.")
        case .fileTooLarge:
            return String(localized: "file_v2.fail.too_large", defaultValue: "Il file supera il limite di 5 GB.", comment: "File transfer error: the picked file is larger than 5 GB.")
        case .unreadable:
            return String(localized: "file_v2.fail.unreadable", defaultValue: "Impossibile leggere il file.", comment: "File transfer error: the file could not be read from disk.")
        case .viewOnceUnsupported:
            return String(localized: "file_v2.fail.view_once", defaultValue: "Documenti e video non possono essere inviati con «visualizza una volta».", comment: "File transfer error: view-once is not available for documents and videos.")
        case .noSecureChannel:
            return String(localized: "file_v2.fail.no_channel", defaultValue: "Il canale cifrato con questo contatto non è ancora pronto. Riprova tra un momento.", comment: "File transfer error: no encrypted session with the contact yet, so the file message cannot be sealed.")
        case .unavailable:
            return String(localized: "file_v2.fail.unavailable", defaultValue: "Il file non è più disponibile sul server (scaduto o rimosso).", comment: "File transfer error: the server no longer has the file the contact sent.")
        case .imageNotCleanable:
            return String(localized: "file_v2.fail.image_not_cleanable", defaultValue: "Immagine non inviata: da questo formato non si possono togliere la posizione e i dati del dispositivo.", comment: "File transfer error: the picture was not sent because its location and device data could not be removed from its format (nothing was uploaded).")
        case .objectGone:
            return String(localized: "file_v2.fail.object_gone", defaultValue: "Il server ha interrotto il caricamento. Riprova.", comment: "File transfer error: the server dropped the object while it was being uploaded.")
        case .format:
            return String(localized: "file_v2.fail.format", defaultValue: "Il file ricevuto è danneggiato e non è stato salvato.", comment: "File transfer error: a chunk of the received file did not verify.")
        case .transfer(let error):
            return message(for: error, server: failure.server)
        }
    }

    /// A photo that is not an image the device can read, or that is above 10 MB after it was downscaled: nothing is sent.
    static var imageMessage: String {
        String(localized: "file_v2.fail.image", defaultValue: "Immagine non valida o troppo grande.", comment: "File transfer error: the picked photo cannot be decoded, or is too large to send.")
    }

    private static func message(for error: FileV2TransferError, server: FileV2ServerError?) -> String {
        switch error {
        case .entitlement:
            return String(localized: "file_v2.fail.entitlement", defaultValue: "L'invio di file non è disponibile per il tuo account.", comment: "File transfer error: the account has no file-sending entitlement.")
        case .quota:
            if let server, server.code == "quota_exceeded", let used = server.details.used, let limit = server.details.limit {
                let usedText: String = bytes(used)
                let limitText: String = bytes(limit)
                return String(localized: "file_v2.fail.quota_used", defaultValue: "Spazio per i file esaurito (usati \(usedText) di \(limitText)). Elimina qualcosa e riprova.", comment: "File transfer error: storage quota full; first %@ is the used size, second %@ the limit.")
            }
            if let server, server.code == "blob_too_large" {
                return String(localized: "file_v2.fail.too_big_server", defaultValue: "Il file è troppo grande per il server.", comment: "File transfer error: the server refuses an object this large.")
            }
            if let server, server.status == 429 {
                return String(localized: "file_v2.fail.too_many_pending", defaultValue: "Hai troppi trasferimenti in sospeso sul server. Riprova tra poco.", comment: "File transfer error: the account holds as many unfinished uploads as it may.")
            }
            return String(localized: "file_v2.fail.quota", defaultValue: "Spazio per i file esaurito sul tuo account.", comment: "File transfer error: storage quota full.")
        case .serverFull:
            return String(localized: "file_v2.fail.server_full", defaultValue: "Il server non ha spazio al momento. Riprova più tardi.", comment: "File transfer error: the server has no room.")
        case .rateLimited:
            return String(localized: "file_v2.fail.rate_limited", defaultValue: "Troppe richieste al server. Riprova tra poco.", comment: "File transfer error: too many requests.")
        case .network:
            return String(localized: "file_v2.fail.network", defaultValue: "Connessione al server non riuscita. Controlla la rete e riprova.", comment: "File transfer error: network failure after the retries.")
        case .auth:
            return String(localized: "file_v2.fail.auth", defaultValue: "Accesso ai file negato.", comment: "File transfer error: the server refused access.")
        case .noSpace:
            return String(localized: "file_v2.fail.no_space", defaultValue: "Spazio insufficiente sul dispositivo.", comment: "File transfer error: not enough free space on the device.")
        case .sourceChanged:
            return String(localized: "file_v2.fail.source_changed", defaultValue: "Il file è cambiato durante l'invio. Riprova.", comment: "File transfer error: the file changed while it was being sent.")
        case .badRequest:
            return String(localized: "file_v2.fail.bad_request", defaultValue: "Il server ha rifiutato la richiesta.", comment: "File transfer error: the server refused the request.")
        case .announceNotSent:
            return String(localized: "file_v2.fail.announce", defaultValue: "Il messaggio con il file non è partito, quindi il file non è stato inviato. Riprova.", comment: "File transfer error: the chat message that carries the file could not be sent.")
        case .descriptorTooLarge:
            return String(localized: "file_v2.fail.descriptor_big", defaultValue: "La descrizione del file è troppo lunga.", comment: "File transfer error: the file description does not fit in a message.")
        }
    }

    private static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

/// The text a rejected file message becomes in the conversation (WIRE_SPEC 12.7.1): never its content. Installed into the engine
/// once at launch; the engine writes it into the row and the preview at the moment the message arrives.
enum FileV2PlaceholderText {
    static func install() {
        FileV2ChatBody.kindLabelText = { label in
            switch label {
            case .image:
                return String(localized: "file_v2.kind.image", defaultValue: "📷 Foto", comment: "One-line label of an image message in the conversation list and in notifications.")
            case .voice:
                return String(localized: "file_v2.kind.voice", defaultValue: "🎤 Nota vocale", comment: "One-line label of a voice note in the conversation list and in notifications.")
            case .video:
                return String(localized: "file_v2.kind.video", defaultValue: "🎬 Video", comment: "One-line label of a video message in the conversation list and in notifications.")
            }
        }
        FileV2ChatBody.placeholderText = { placeholder in
            switch placeholder {
            case .unsupportedVersion:
                return String(localized: "file_v2.placeholder.unsupported", defaultValue: "📎 Allegato non supportato: aggiorna l'app per aprirlo", comment: "Placeholder row for a file message of a newer version this app cannot read.")
            case .invalid:
                return String(localized: "file_v2.placeholder.invalid", defaultValue: "📎 Allegato non valido", comment: "Placeholder row for a file message that was rejected as invalid.")
            }
        }
    }
}

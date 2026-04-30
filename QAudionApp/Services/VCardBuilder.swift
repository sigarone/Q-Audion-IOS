import Foundation
import UIKit
import SwiftUI
import QAudionEngine

/// W51: builder RFC 6350 vCard 3.0 + share-sheet payload + UIActivity
/// wrapper. Centralizzato qui così altre superfici (rubrica condivisa,
/// import/export NFC, ecc.) possono riusare la stessa serializzazione.
///
/// Format scelto: vCard 3.0 (più compatibile di 4.0 con iOS Contatti +
/// Android Contatti + macOS). Le linee CRLF e l'`END:VCARD` finale
/// sono richieste dallo standard.
public enum VCardBuilder {

    /// Costruisce una vCard 3.0 da un `ContactsListViewModel.Item`. I
    /// campi sicuri (FN, NOTE con USERID Q-Audion + phoneHash) sono
    /// sempre emessi; il PHOTO è omesso (l'avatarUrl è remoto e i
    /// peer iOS Contatti non lo dereferencerebbero comunque senza
    /// auth).
    public static func build(for item: ContactsListViewModel.Item) -> String {
        // Tutte le righe vCard usano CRLF come separator (RFC 6350 § 3.2).
        let crlf = "\r\n"
        var lines: [String] = []
        lines.append("BEGIN:VCARD")
        lines.append("VERSION:3.0")
        // FN (formatted name) è REQUIRED in 3.0.
        lines.append("FN:\(escape(item.displayName))")
        // N (structured name) — usiamo solo il "given" (componente 1)
        // dato che non separiamo first/last sul nostro lato.
        lines.append("N:;\(escape(item.displayName));;;")
        // X-Q-AUDION-USERID custom property — preservato dai contact
        // store che fanno round-trip della vCard.
        lines.append("X-Q-AUDION-USERID:\(escape(item.userId))")
        // NOTE per peer non-Q-Audion: spiega cos'è il userId.
        let note = "Contatto Q-Audion. ID: \(item.userId)"
        lines.append("NOTE:\(escape(note))")
        lines.append("END:VCARD")
        return lines.joined(separator: crlf) + crlf
    }

    /// vCard 3.0 escape: backslash, virgola, punto-e-virgola, e CRLF
    /// embedded vanno escapati come `\\`, `\,`, `\;`, `\n` (RFC 6350
    /// § 3.4 — equivalente per 3.0 dato che il subset è compatibile).
    private static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: ",", with: "\\,")
        out = out.replacingOccurrences(of: ";", with: "\\;")
        out = out.replacingOccurrences(of: "\r\n", with: "\\n")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\n")
        return out
    }
}

/// Payload Identifiable per `.sheet(item:)` — porta sia il testo vCard
/// che il filename suggerito (per AirDrop / Mail attachment naming).
public struct VCardShareItem: Identifiable {
    public let id = UUID()
    public let text: String
    public let filename: String

    public init(text: String, filename: String) {
        self.text = text; self.filename = filename
    }
}

/// `UIActivityViewController` wrapper che condivide il vCard come file
/// `.vcf` temporaneo. Scrivere a un file URL con estensione `.vcf` è
/// più affidabile che condividere come `String` puro — Mail / Messaggi
/// riconoscono il tipo MIME e mostrano "Aggiungi ai Contatti" nel
/// receiver.
public struct VCardShareSheet: UIViewControllerRepresentable {
    public let text: String
    public let filename: String

    public init(text: String, filename: String) {
        self.text = text; self.filename = filename
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        // Scriviamo il vCard a un file temporaneo. Best-effort: se la
        // scrittura fallisce, fallback al testo puro così il share
        // sheet apre comunque qualcosa di utile.
        let activityItems: [Any]
        if let url = writeTempFile() {
            activityItems = [url]
        } else {
            activityItems = [text]
        }
        let vc = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        return vc
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController,
                                       context: Context) {
        // No-op: il VC è creato fresh ogni presentazione.
    }

    /// Scrive il vCard in `tmp/<filename>.vcf` e restituisce l'URL.
    /// Restituisce `nil` se la scrittura fallisce (rara — `tmp` è
    /// sempre scrivibile su iOS).
    private func writeTempFile() -> URL? {
        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent(filename)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

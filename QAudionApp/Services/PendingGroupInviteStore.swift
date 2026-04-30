import Foundation
import QAudionEngine

/// W68c: store UserDefaults-backed per le richieste di group-join in
/// attesa che il backend esponga `POST /groups/:id/join`.
///
/// Quando l'utente scansiona un QR `qaudion-group-invite` (W52/W53), il
/// payload viene salvato qui invece di chiamare l'API server (che oggi
/// non esiste). Quando l'engine team wirerà l'endpoint, l'app può
/// replay-are tutti i pending da questo store via `replay(_:)`.
///
/// Schema: array di `Pending` (groupId, groupName, payloadVersion,
/// scannedAt). Cap a 50 entries — oltre quello, le entry più vecchie
/// vengono espulse FIFO. UserDefaults size budget rispettato.
public enum PendingGroupInviteStore {

    public struct Pending: Codable, Equatable, Identifiable {
        public let id: UUID         // local id per List rendering
        public let groupId: UUID
        public let groupName: String
        public let payloadVersion: Int
        public let scannedAt: Date

        public init(id: UUID = UUID(),
                    groupId: UUID,
                    groupName: String,
                    payloadVersion: Int,
                    scannedAt: Date = Date()) {
            self.id = id
            self.groupId = groupId
            self.groupName = groupName
            self.payloadVersion = payloadVersion
            self.scannedAt = scannedAt
        }
    }

    private static let key = "com.qaudion.groupInvite.pending"
    private static let maxEntries = 50

    /// Carica tutte le pending invites, sorted by scannedAt newest-first.
    public static func load() -> [Pending] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let entries = try? JSONDecoder().decode([Pending].self, from: data) else { return [] }
        return entries.sorted { $0.scannedAt > $1.scannedAt }
    }

    /// Aggiunge una pending invite. Dedup per groupId — se la stessa
    /// invite è scansionata 2x, l'entry vecchia viene rimossa.
    public static func append(_ pending: Pending) {
        var current = load()
        current.removeAll { $0.groupId == pending.groupId }
        current.insert(pending, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Rimuove una specific pending dal store. Chiamato dopo replay
    /// successful (HTTP 2xx dall'endpoint server quando lands).
    public static func remove(id: UUID) {
        var current = load()
        current.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Wipe completo. Chiamato dal `DevResetScreen` (W46) — la chiave
    /// è stata aggiunta a `DevResetContainer.knownKeys` in W68c.
    public static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Conveniente helper per costruire una `Pending` da un decoded
    /// `GroupInviteQrCode.Payload` (output del QrScannerSheet).
    public static func append(from payload: GroupInviteQrCode.Payload) {
        let p = Pending(
            groupId: payload.groupId,
            groupName: payload.groupName,
            payloadVersion: payload.version
        )
        append(p)
    }
}

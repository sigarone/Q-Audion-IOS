import Foundation
import QAudionEngine

/// W70: thin client wrapper attorno ai 3 endpoint Track-B server-side
/// (DELETE /calls/history, POST /conversations/:id/read, POST /groups/:id/join).
///
/// Pattern best-effort — il local store W68 (UserDefaults) resta source
/// of truth e l'UI non blocca mai sull'HTTP. Errori sono loggati ma
/// l'operazione locale non viene mai annullata: al prossimo restart il
/// `PendingGroupInviteStore.replay()` riprova.
///
/// Endpoint live in produzione (VPS 217.160.65.35) dal commit
/// `f99e00c feat(track-b)` su `bcrypto-server`.
@MainActor
final class TrackBSyncService {

    private let baseURL: URL?
    private let token: String?
    /// SECURITY C-6 — cert-pinned session for all Track-B sync calls.
    private let session: URLSession

    init(serverUrl: String, accessToken: String?) {
        self.baseURL = URL(string: serverUrl)
        self.token = accessToken
        self.session = PinnedURLSession.make(for: serverUrl)
    }

    /// Convenience factory. Restituisce nil se non autenticato (caller deve
    /// trattare come no-op silenzioso).
    static func from(serverUrl: String, token: String?) -> TrackBSyncService? {
        guard let token = token, !token.isEmpty else { return nil }
        return TrackBSyncService(serverUrl: serverUrl, accessToken: token)
    }

    // MARK: - 1. Call history

    /// DELETE /api/v1/calls/history/:id — soft-delete server-side.
    /// Best-effort: 401/404/5xx → swallow + log, local tombstone resta.
    func deleteCallHistoryEntry(_ entryId: String) async {
        guard let url = endpoint("/api/v1/calls/history/\(entryId)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        addAuth(&req)
        await fireAndLog(req, label: "calls.history.delete[\(entryId)]")
    }

    /// DELETE /api/v1/calls/history (no id) — bulk wipe per l'utente.
    /// Server replies 200 + count, ma noi ignoriamo il body.
    func deleteAllCallHistory() async {
        guard let url = endpoint("/api/v1/calls/history") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        addAuth(&req)
        await fireAndLog(req, label: "calls.history.deleteAll")
    }

    // MARK: - 2. Conversation read marks

    /// POST /api/v1/conversations/:id/read — mark single conversation as read.
    func markConversationRead(convId: String, lastReadMessageId: String? = nil) async {
        guard let url = endpoint("/api/v1/conversations/\(convId)/read") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let lastId = lastReadMessageId, !lastId.isEmpty {
            let body = ["lastReadMessageId": lastId]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            req.httpBody = "{}".data(using: .utf8)
        }
        await fireAndLog(req, label: "conversations.read[\(convId)]")
    }

    /// POST /api/v1/conversations/read-all — bulk mark.
    func markAllConversationsRead(asOfMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async {
        guard let url = endpoint("/api/v1/conversations/read-all") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["asOf": asOfMs]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        await fireAndLog(req, label: "conversations.readAll")
    }

    // MARK: - 3. Group join

    /// POST /api/v1/groups/:id/join — submit join request. Returns true
    /// se l'HTTP è 2xx (così il replay loop può rimuovere la pending
    /// dal local store), false altrimenti (lascia l'entry per retry).
    func requestGroupJoin(groupId: String,
                                  inviteSource: String = "qr",
                                  inviterUserId: String? = nil) async -> Bool {
        guard let url = endpoint("/api/v1/groups/\(groupId)/join") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        addAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["inviteSource": inviteSource]
        if let inviter = inviterUserId, !inviter.isEmpty {
            body["inviterUserId"] = inviter
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await fireAndLog(req, label: "groups.join[\(groupId)]")
    }

    /// Drain `PendingGroupInviteStore` chiamando `requestGroupJoin` per
    /// ognuna. Le entries che ricevono 2xx vengono rimosse dal local
    /// store; quelle che falliscono restano per il prossimo replay.
    /// Returns count delle pending replayed con success.
    @discardableResult
    func replayPendingGroupInvites() async -> Int {
        let pending = PendingGroupInviteStore.load()
        guard !pending.isEmpty else { return 0 }
        var ok = 0
        for entry in pending {
            let success = await requestGroupJoin(
                groupId: entry.groupId.uuidString,
                inviteSource: "qr",
                inviterUserId: nil
            )
            if success {
                PendingGroupInviteStore.remove(id: entry.id)
                ok += 1
            }
        }
        return ok
    }

    // MARK: - Internals

    private func endpoint(_ path: String) -> URL? {
        guard let base = baseURL else { return nil }
        return URL(string: base.absoluteString + path)
    }

    private func addAuth(_ req: inout URLRequest) {
        if let t = token, !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Fire HTTP. Returns true se 2xx, false altrimenti. Logga sempre
    /// in console (non blocca). Total timeout ~10s via URLSession default.
    @discardableResult
    private func fireAndLog(_ req: URLRequest, label: String) async -> Bool {
        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                let ok = (200..<300).contains(http.statusCode)
                if !ok {
                    print("[TrackBSync] \(label) HTTP \(http.statusCode)")
                }
                return ok
            }
            return false
        } catch {
            print("[TrackBSync] \(label) error: \(error.localizedDescription)")
            return false
        }
    }
}

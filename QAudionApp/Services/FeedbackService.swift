import Foundation
import Combine

/// W546+W547 — Bidirectional in-app feedback channel.
///
/// Talks to bcrypto-server `/api/v1/feedback*` (see
/// apps/bcrypto-server/cmd/bcrypto-lite/feedback.go for the wire
/// contract). Three duties:
///
/// 1. `submit(...)` — POST a new feedback thread (subject + body + kind).
///    The server auto-replies with a maintainer "Grazie" so the user
///    gets immediate visible acknowledgement. Returns the freshly
///    created `FeedbackItem` (including the auto-reply).
/// 2. `fetchInbox()` — poll the server for any unread maintainer
///    replies on this user's threads. Called every ~60 s by a
///    timer in the UI, plus once when the FeedbackScreen mounts.
/// 3. `ack(item, reply)` — mark a maintainer reply as read so it
///    stops showing up in subsequent inbox polls.
/// 4. `reply(to:, body:)` — append a follow-up message from the
///    user to an existing thread.
///
/// Same primitives-only API constraint as the other services in
/// this file (CLAUDE.md "Hard-won lesson 16" — never take AppState
/// as a parameter type, or the Swift type checker exhausts itself
/// on Sendable inference and the build silently fails).
@MainActor
public final class FeedbackService: ObservableObject {

    public static let shared = FeedbackService()

    public typealias TokenProvider = TelemetryService.TokenProvider

    /// Number of unread maintainer replies across all threads.
    /// Updated by the background poller — read by SettingsScreen
    /// to show a badge dot next to the "Feedback" row.
    @Published public private(set) var unreadCount: Int = 0

    private var serverUrl: String = ""
    private var getToken: TokenProvider?
    private var pollTask: Task<Void, Never>?

    private init() {}

    // ─── Lifecycle ─────────────────────────────────────────────────

    /// Wire the service. Caller supplies the base URL (no trailing
    /// slash) plus a closure returning the current JWT.
    public func start(
        serverUrl: String,
        getToken: @escaping TokenProvider
    ) {
        self.serverUrl = serverUrl
        self.getToken = getToken
        startPollingIfNeeded()
    }

    /// Kicks the 60-second inbox poll. Idempotent. The poll runs
    /// silently — failures don't surface as snackbars, they just
    /// keep `unreadCount` at its last known value. Cancel the
    /// task at logout (or leave it running — without a token it
    /// no-ops anyway).
    public func startPollingIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            // First refresh ~5 s after launch so we don't compete
            // with login + WS connect for bandwidth.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                await self?.refreshUnreadCount()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Update `unreadCount` from the server. Best-effort — keeps
    /// the previous value on failure.
    public func refreshUnreadCount() async {
        do {
            let items = try await fetchInbox()
            self.unreadCount = items.reduce(0) { acc, item in
                acc + item.replies.filter {
                    $0.role == "maintainer" && ($0.read_by_user != true)
                }.count
            }
        } catch {
            // Silent — pre-login or transient network.
        }
    }

    // ─── Wire types ────────────────────────────────────────────────

    public struct Reply: Codable, Identifiable, Equatable {
        public let id: String
        public let role: String      // "user" | "maintainer"
        public let author_id: String
        public let body: String
        public let created_ms: Int64
        public var read_by_user: Bool?
    }

    public struct Item: Codable, Identifiable, Equatable {
        public let id: String
        public let user_id: String
        public let kind: String      // "bug" | "feature" | "praise" | "other"
        public let subject: String
        public let status: String    // "new" | "ack" | "closed"
        public let assignee: String?
        public let git_ref: String?
        public let call_id: String?
        public let platform: String
        public let app_ver: String
        public let created_ms: Int64
        public let updated_ms: Int64
        public let replies: [Reply]
    }

    private struct SubmitInput: Codable {
        let kind: String
        let subject: String
        let body: String
        let call_id: String?
        let platform: String
        let app_ver: String
    }

    private struct SubmitResponse: Codable {
        let v: Int
        let item: Item
    }

    private struct InboxResponse: Codable {
        let v: Int
        let items: [Item]
    }

    public enum FeedbackError: Error {
        case notStarted
        case noToken
        case http(Int)
        case decode(String)
    }

    // ─── Public API ────────────────────────────────────────────────

    public func submit(
        kind: String,
        subject: String,
        body: String,
        callId: String? = nil
    ) async throws -> Item {
        let url = try endpoint("/api/v1/feedback")
        let input = SubmitInput(
            kind: kind,
            subject: subject,
            body: body,
            call_id: callId,
            platform: "ios",
            app_ver: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        )
        let body = try JSONEncoder().encode(input)
        let data = try await postJSON(url: url, body: body)
        do {
            return try JSONDecoder().decode(SubmitResponse.self, from: data).item
        } catch {
            throw FeedbackError.decode("\(error)")
        }
    }

    public func fetchInbox() async throws -> [Item] {
        let url = try endpoint("/api/v1/feedback/inbox")
        let data = try await getJSON(url: url)
        do {
            return try JSONDecoder().decode(InboxResponse.self, from: data).items
        } catch {
            throw FeedbackError.decode("\(error)")
        }
    }

    public func ack(itemId: String, replyId: String) async throws {
        let url = try endpoint("/api/v1/feedback/\(itemId)/replies/\(replyId)/ack")
        _ = try await postJSON(url: url, body: Data())
    }

    public func reply(to itemId: String, body: String) async throws -> Item {
        let url = try endpoint("/api/v1/feedback/\(itemId)/replies")
        struct R: Codable { let body: String }
        let payload = try JSONEncoder().encode(R(body: body))
        let data = try await postJSON(url: url, body: payload)
        do {
            return try JSONDecoder().decode(SubmitResponse.self, from: data).item
        } catch {
            throw FeedbackError.decode("\(error)")
        }
    }

    // ─── HTTP plumbing ─────────────────────────────────────────────

    private func endpoint(_ path: String) throws -> URL {
        guard !serverUrl.isEmpty, let url = URL(string: serverUrl + path) else {
            throw FeedbackError.notStarted
        }
        return url
    }

    private func token() throws -> String {
        guard let getToken = getToken, let t = getToken(), !t.isEmpty else {
            throw FeedbackError.noToken
        }
        return t
    }

    private func postJSON(url: URL, body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        let tok = try token()
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status / 100 == 2 else {
            throw FeedbackError.http(status)
        }
        return data
    }

    private func getJSON(url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        let tok = try token()
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status / 100 == 2 else {
            throw FeedbackError.http(status)
        }
        return data
    }
}

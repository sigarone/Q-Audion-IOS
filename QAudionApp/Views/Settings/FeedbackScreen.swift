import SwiftUI

/// W546+W547 — In-app feedback UI.
///
/// Two panes:
///   - "Messaggi dal team" — every thread that has at least one
///     unread maintainer reply. Tapping a thread opens the
///     conversation, marks the maintainer's last reply as read, and
///     lets the user follow-up.
///   - "Invia feedback" — compose form (kind picker + subject +
///     body). On submit, the server auto-replies with a thank-you so
///     the user sees confirmation immediately.
///
/// The screen does NOT live-poll. It re-fetches on appear + after
/// every submit/reply. The bg push poll (FeedbackInboxPoller) is
/// what keeps the badge fresh between visits — this is just the
/// detail view.
struct FeedbackScreen: View {

    @State private var inbox: [FeedbackService.Item] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showCompose = false
    @State private var selected: FeedbackService.Item?

    var body: some View {
        List {
            Section {
                Button {
                    showCompose = true
                } label: {
                    Label("Invia un nuovo feedback", systemImage: "square.and.pencil")
                        .font(.body.weight(.semibold))
                }
            }
            Section("Messaggi dal team") {
                if loading && inbox.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Caricamento…").foregroundStyle(.secondary)
                    }
                } else if inbox.isEmpty {
                    Text("Nessun messaggio non letto. Buona giornata.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(inbox) { item in
                        Button {
                            selected = item
                        } label: {
                            ThreadRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .sheet(isPresented: $showCompose) {
            FeedbackComposeSheet { _ in
                Task { await refresh() }
            }
        }
        .sheet(item: $selected) { item in
            FeedbackThreadSheet(item: item) {
                Task { await refresh() }
            }
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            inbox = try await FeedbackService.shared.fetchInbox()
            error = nil
        } catch FeedbackService.FeedbackError.noToken {
            // Pre-login: show empty silently.
            inbox = []
            error = nil
        } catch {
            self.error = "Impossibile caricare i messaggi (\(error))"
        }
    }
}

// ─── Row ───────────────────────────────────────────────────────────

private struct ThreadRow: View {
    let item: FeedbackService.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.subject)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(relativeAge(ms: item.updated_ms))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let last = item.replies.last(where: { $0.role == "maintainer" }) {
                Text(last.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// ─── Compose ───────────────────────────────────────────────────────

private struct FeedbackComposeSheet: View {
    let onSubmitted: (FeedbackService.Item) -> Void
    @State private var kind: String = "bug"
    @State private var subject: String = ""
    @State private var body: String = ""
    @State private var submitting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Tipo", selection: $kind) {
                    Text("Problema").tag("bug")
                    Text("Idea / richiesta").tag("feature")
                    Text("Complimento").tag("praise")
                    Text("Altro").tag("other")
                }
                Section("Oggetto") {
                    TextField("Una riga di riassunto", text: $subject)
                        .textInputAutocapitalization(.sentences)
                }
                Section("Messaggio") {
                    TextEditor(text: $body)
                        .frame(minHeight: 160)
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Nuovo feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if submitting { ProgressView() } else { Text("Invia") }
                    }
                    .disabled(submitting || body.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        do {
            let item = try await FeedbackService.shared.submit(
                kind: kind,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSubmitted(item)
            dismiss()
        } catch {
            self.error = "Invio fallito: \(error)"
        }
    }
}

// ─── Thread view ───────────────────────────────────────────────────

private struct FeedbackThreadSheet: View {
    let item: FeedbackService.Item
    let onChange: () -> Void
    @State private var current: FeedbackService.Item
    @State private var replyText: String = ""
    @State private var sending = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(item: FeedbackService.Item, onChange: @escaping () -> Void) {
        self.item = item
        self.onChange = onChange
        self._current = State(initialValue: item)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(current.replies) { rep in
                            ReplyBubble(reply: rep)
                                .padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 12)
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Rispondi…", text: $replyText, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(8)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView() }
                        else { Image(systemName: "paperplane.fill") }
                    }
                    .disabled(sending || replyText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.bottom, 4)
                }
            }
            .navigationTitle(current.subject)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .task { await ackUnreadReplies() }
        }
    }

    private func ackUnreadReplies() async {
        for rep in current.replies where rep.role == "maintainer" && (rep.read_by_user != true) {
            try? await FeedbackService.shared.ack(itemId: current.id, replyId: rep.id)
        }
        onChange()
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let body = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated = try await FeedbackService.shared.reply(to: current.id, body: body)
            current = updated
            replyText = ""
            onChange()
        } catch {
            self.error = "Invio fallito: \(error)"
        }
    }
}

private struct ReplyBubble: View {
    let reply: FeedbackService.Reply
    var body: some View {
        let isUser = reply.role == "user"
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? "Tu" : "Il team")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(reply.body)
                    .font(.callout)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(isUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// ─── Helpers ───────────────────────────────────────────────────────

private func relativeAge(ms: Int64) -> String {
    let dt = Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    if dt < 90 { return "\(Int(dt))s fa" }
    if dt < 90 * 60 { return "\(Int(dt / 60))m fa" }
    if dt < 36 * 3600 { return "\(Int(dt / 3600))h fa" }
    return "\(Int(dt / 86400))g fa"
}

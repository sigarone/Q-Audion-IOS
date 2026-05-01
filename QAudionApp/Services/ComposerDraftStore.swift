import Foundation

/// W137 — per-conversation composer draft persistence.
///
/// iOS aggressively kills backgrounded apps once memory pressure spikes,
/// and a half-typed message that vanishes between app launches is one of
/// the most common chat-app annoyances. We persist whatever the user has
/// typed (post-trim non-empty) under `UserDefaults`, keyed by the
/// conversation UUID, so the next time `ChatContainer` constructs the
/// view-model the draft pre-populates the composer.
///
/// **Storage budget.** Drafts are stored as plain strings in user
/// defaults — fine because:
///   - they're plaintext that the user typed *into* the device, never
///     transmitted, never derived from peers;
///   - the per-key cap is the system 4KB (chats this long are rare —
///     for safety we still trim to 8KB before storing, mirroring the
///     edit-envelope cap);
///   - `clear(for:)` runs whenever the user actually sends or cancels,
///     so an empty composer never leaves a dangling key behind.
///
/// **Privacy.** Standard user defaults live inside the app's sandbox
/// and are not shared with extensions or other apps. Drafts are wiped
/// on full account reset (`DevResetScreen` clears the suite). For
/// privacy-mode users we honour `appState.hideMessageContent` by simply
/// not loading a draft when that flag is on — the draft remains on
/// disk so they can re-enter the chat later, but the unlocked surface
/// stays empty.
enum ComposerDraftStore {
    /// 8KiB cap mirrors the edit-envelope body cap. Above this we trim
    /// to avoid bloating user defaults with pathological pastes.
    private static let maxDraftBytes: Int = 8 * 1024

    private static func key(for conversationId: UUID) -> String {
        "qa.composer.draft.\(conversationId.uuidString)"
    }

    /// Persist the current composer text. Empty / whitespace-only input
    /// removes the key (no zombie entries). Texts above 8KiB are
    /// truncated at the last UTF-8 boundary that fits.
    static func save(_ text: String, for conversationId: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key(for: conversationId)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: k)
            return
        }
        var stored = text
        // Cap by UTF-8 byte length, not character count, since the
        // 4KB per-key user-defaults soft limit is byte-bounded.
        if let data = stored.data(using: .utf8), data.count > maxDraftBytes {
            // Walk back until we land on a valid UTF-8 boundary.
            var truncated = data.prefix(maxDraftBytes)
            while !truncated.isEmpty, String(data: truncated, encoding: .utf8) == nil {
                truncated = truncated.dropLast()
            }
            stored = String(data: truncated, encoding: .utf8) ?? ""
        }
        UserDefaults.standard.set(stored, forKey: k)
    }

    /// Read the saved draft for a conversation. Returns `""` when
    /// nothing is stored.
    static func load(for conversationId: UUID) -> String {
        UserDefaults.standard.string(forKey: key(for: conversationId)) ?? ""
    }

    /// Drop the persisted draft. Call after a successful send or when
    /// the user explicitly cancels (e.g. `clearLocalHistory`).
    static func clear(for conversationId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: conversationId))
    }
}

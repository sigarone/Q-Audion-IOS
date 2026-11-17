import Foundation
import QAudionEngine

/// W137 — per-conversation composer draft persistence.
///
/// iOS aggressively kills backgrounded apps once memory pressure spikes,
/// and a half-typed message that vanishes between app launches is one of
/// the most common chat-app annoyances. We persist whatever the user has
/// typed (post-trim non-empty) under `UserDefaults`, keyed by the
/// conversation UUID, so the next time `ChatContainer` constructs the
/// view-model the draft pre-populates the composer.
///
/// **Storage budget.** Drafts are capped the same way as before:
///   - the per-key cap is the system 4KB (chats this long are rare —
///     for safety we still trim to 8KB before storing, mirroring the
///     edit-envelope cap);
///   - `clear(for:)` runs whenever the user actually sends or cancels,
///     so an empty composer never leaves a dangling key behind.
///
/// **Privacy — W-DRAFTATREST.** The trimmed text is sealed before it is
/// written to `UserDefaults`: it is user-typed, but still full message
/// content, and `UserDefaults` is included in an unencrypted local
/// iTunes/Finder backup or iCloud device backup just like any other app
/// file. `ConversationStore` seals the content of SENT messages with a
/// device-held AES-256-GCM key before it ever reaches a row (see
/// `LocalStoreCipher`'s own header); drafts go through the exact same
/// `LocalStoreCipher` — no new crypto, same Keychain-held key, same
/// `AfterFirstUnlockThisDeviceOnly` accessibility class. What lands in
/// `UserDefaults` is ciphertext instead of plaintext, so a backup captures
/// a blob that a restore-to-new-device (or even a fresh restore on the
/// same device, since the key is `ThisDeviceOnly`) can never open. A legacy
/// unsealed row still loads verbatim (`LocalStoreCipher.open` passes
/// through anything without the seal marker) and is resealed on its very
/// next `save`, so no existing draft is lost.
///
/// `QAudionDatabase`'s SQLite store was the OTHER option for this (drafts
/// as a new table there, mirroring `messages`), but `LocalStoreCipher`
/// alone gets the actual goal — no plaintext draft content in a backup —
/// without adding a migration, a GRDB record type, or a new SQLite
/// dependency to the App target.
///
/// Drafts are wiped on full account reset (`DevResetScreen` clears the
/// suite). For privacy-mode users we honour `appState.hideMessageContent`
/// by simply not loading a draft when that flag is on — the draft remains
/// on disk so they can re-enter the chat later, but the unlocked surface
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
        // W-DRAFTATREST — seal before it ever reaches UserDefaults, same
        // AES-256-GCM device key `LocalStoreCipher` already uses for
        // message bodies and group tombstones. `seal` only throws when the
        // Keychain key itself is unreachable (e.g. before the device's
        // first unlock after a reboot); on that rare path we skip the
        // write rather than fall back to plaintext — losing this one
        // in-flight draft is a smaller regression than reopening the gap
        // this fix exists to close. `String??` because `try?` on a
        // throwing `String?`-returning function double-wraps (same pattern
        // as `GroupTombstoneStore.persist`).
        let attempt: String?? = try? LocalStoreCipher.seal(stored)
        guard let sealedOptional = attempt, let sealed = sealedOptional else {
            RTLog.error("chat", "composer draft seal failed, write skipped")
            return
        }
        UserDefaults.standard.set(sealed, forKey: k)
    }

    /// Read the saved draft for a conversation. Returns `""` when
    /// nothing is stored, or when a stored value cannot be decrypted
    /// (Keychain key gone — e.g. after a device restore). A legacy
    /// unsealed row (written before W-DRAFTATREST) is returned verbatim:
    /// `LocalStoreCipher.open` passes through anything without the seal
    /// marker unchanged.
    static func load(for conversationId: UUID) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key(for: conversationId)) else {
            return ""
        }
        return LocalStoreCipher.open(stored) ?? ""
    }

    /// Drop the persisted draft. Call after a successful send or when
    /// the user explicitly cancels (e.g. `clearLocalHistory`).
    static func clear(for conversationId: UUID) {
        UserDefaults.standard.removeObject(forKey: key(for: conversationId))
    }
}

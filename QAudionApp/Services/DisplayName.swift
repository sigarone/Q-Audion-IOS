import Foundation
import QAudionEngine

/// Central user/group display-name resolver — THE single place that decides
/// what identity string a user-facing surface may render.
///
/// Standing rule (Pavel, escalated 2026-07-20): NO raw long UUID may ever
/// appear in any user-facing UI. Every identity render resolves through:
///
///   1. local rubrica (`ContactsStore`) display name (alias-first: the
///      stored `displayName` IS the user's local name for the peer — the
///      phonebook-import/QR/edit flows all write it),
///   2. server-supplied display (`caller_display` / push `caller_name` /
///      wire `group_name`), sanitised; a bare numeric value is the PBX
///      extension and renders as "Int. NNN",
///   3. TRANSIENT last resort: "Utente a1b2c3d4…" (short8 + ellipsis) for
///      users, "Gruppo a1b2c3d4…" for groups — NEVER the 36-char UUID, and
///      (corrected rule 2026-07-20) never a steady state for users either:
///      hitting it kicks `NameResolutionService.ensureResolved`, which
///      fetches the profile and upserts server name / "Int. NNN" into the
///      rubrica (every userId has a server-guaranteed interno; a fetch that
///      yields neither is logged as a real error).
///
/// Debug/diagnostics screens (explicitly labeled) and technical-id captions
/// in QR/invite flows (small, monospaced, labeled "ID tecnico") are the only
/// exemptions.
///
/// Threading: `forUser` is nonisolated on purpose — it is injected as
/// `BCryptoGroupCallManager.nameResolver`, which fires on the WS client's
/// background thread (`ContactsStore` is a UserDefaults read, thread-safe).
/// Hot main-thread call sites pass `contacts: appState.cachedContacts` to
/// skip the UserDefaults decode. `forGroup` is @MainActor because
/// `GroupRegistry` is.
enum DisplayName {

    /// Resolve a userId to a human display string. See type kdoc for the
    /// chain. `serverDisplay` is the wire/push-supplied name when the call
    /// site has one; `contacts` is an optional pre-loaded rubrica snapshot
    /// (falls back to a fresh `ContactsStore().load()`).
    static func forUser(_ userId: String,
                        serverDisplay: String? = nil,
                        contacts: [ContactsStore.StoredContact]? = nil) -> String {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return "Sconosciuto" }
        // 1. Rubrica (alias / local display name). Skip a stored name that
        //    is itself a raw UUID (legacy rows) — it would defeat the rule.
        let stored = contacts ?? ContactsStore().load()
        if let match = stored.first(where: { $0.userId == id }) {
            let dn = match.displayName.trimmingCharacters(in: .whitespaces)
            if !dn.isEmpty && !looksLikeUUID(dn) { return dn }
        }
        // 2. Server-supplied display, sanitised. Bare digits = extension.
        if let sd = serverDisplay {
            let cleaned = StringSanitiser.displayName(sd, fallback: "")
            if !cleaned.isEmpty && !looksLikeUUID(cleaned) {
                if cleaned.allSatisfy({ $0.isNumber }) { return "Int. \(cleaned)" }
                return cleaned
            }
        }
        // 3. Legacy dev-seed convention ("user-mario" → "Mario").
        if id.hasPrefix("user-") { return String(id.dropFirst(5)).capitalized }
        // 4. Short human-scale ids (extensions etc.) pass through; long
        //    opaque ids get the humane short8 fallback — TRANSIENTLY.
        //    Pavel corrected rule (2026-07-20): "Utente short8…" is not an
        //    acceptable steady state — every userId has a server-side
        //    extension ("interno"), so kick a fire-and-forget profile
        //    fetch. NameResolutionService upserts the server name (or
        //    "Int. NNN") into the rubrica and .contactsDidChange re-renders
        //    every observer; this call stays synchronous and returns the
        //    placeholder only for the instant the fetch is in flight.
        if id.count > 12 {
            NameResolutionService.shared.ensureResolved(userId: id)
            return shortUserFallback(id)
        }
        return id
    }

    /// Last-resort user label — "Utente a1b2c3d4…". For call sites that
    /// have already exhausted their own richer chain.
    static func shortUserFallback(_ userId: String) -> String {
        "Utente " + String(userId.prefix(8)) + "…"
    }

    /// Resolve a group id (+ optional already-known name) to a display
    /// string: explicit name → GroupRegistry name → "Gruppo a1b2c3d4…".
    /// Accepts dashed-UUID or hex form.
    @MainActor
    static func forGroup(id: String, name: String? = nil) -> String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !n.isEmpty, !looksLikeUUID(n) {
            return n
        }
        let hex = id.replacingOccurrences(of: "-", with: "").lowercased()
        if let entry = GroupRegistry.shared.entry(for: hex) {
            let n = entry.name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty && !looksLikeUUID(n) { return n }
        }
        return shortGroupFallback(id)
    }

    /// Last-resort group label — "Gruppo a1b2c3d4…".
    static func shortGroupFallback(_ groupId: String) -> String {
        "Gruppo " + String(groupId.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)) + "…"
    }

    /// True for a 36-char dashed UUID or a 32-char bare hex id. Public so
    /// rubrica-first fast paths (HomeView name cache, AppState cached-contact
    /// short-circuits) can skip UUID-shaped STORED display names — legacy
    /// rows persisted before addScannedContact stopped writing the raw
    /// userId as displayName (W-UUIDSWEEP).
    static func looksLikeUUID(_ s: String) -> Bool {
        if s.count == 36 && s.filter({ $0 == "-" }).count == 4 { return true }
        if s.count == 32 && s.allSatisfy({ $0.isHexDigit }) { return true }
        return false
    }
}

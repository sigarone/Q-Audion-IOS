import Foundation
import QAudionEngine

/// Central user/group display-name resolver — THE single place that decides
/// what identity string a user-facing surface may render.
///
/// Standing rule (Pavel, escalated 2026-07-20, RE-ESCALATED 2026-07-29 —
/// "must be exactly one identical string everywhere, and probably better to
/// drop the word 'phone' entirely since it should be obvious that's the
/// number to dial"): NO raw long UUID may ever appear in any user-facing UI,
/// and — as of the 07-29 escalation — no prefix word of ANY kind ("Phone",
/// "Int.", "Ext.", "Interno", "Nebenstelle", "(ext. N)"…) may be glued onto a
/// bare PBX extension either, for a peer's identity OR for the local user's
/// own. Every identity render resolves through:
///
///   1. local rubrica (`ContactsStore`) display name (alias-first: the
///      stored `displayName` IS the user's local name for the peer — the
///      phonebook-import/QR/edit flows all write it), UNLESS it is one of
///      the recognised placeholder/legacy shapes (`isPlaceholderName`) — a
///      stale cached "Phone #100"/"Extension #100"/"New User" (this app's
///      own past bug, another platform's equivalent, or a fast-setup QR
///      minted before the fix) counts as "no name set", not a real name.
///   2. server-supplied display (`caller_display` / push `caller_name` /
///      wire `group_name`), sanitised and subject to the SAME
///      placeholder check.
///   3. a known PBX extension — rendered as BARE DIGITS, no prefix word,
///      no zero-padding ("7" stays "7", "100" stays "100"). Recovered from
///      (in priority order) an explicit caller-supplied value, the
///      rubrica's own structured `extension` field, or digits embedded in
///      a legacy placeholder string (`extensionDigits(fromLegacyLabel:)`) —
///      those legacy strings were always literally `"<label>\(extension)"`,
///      so the trailing digits ARE the real extension, never a guess.
///   4. a known phone number — already self-evidently a number, shown as-is.
///   5. TRANSIENT last resort: "Utente a1b2c3d4…" (short8 + ellipsis) for
///      users, "Gruppo a1b2c3d4…" for groups — NEVER the 36-char UUID, and
///      (corrected rule 2026-07-20) never a steady state for users either:
///      hitting it kicks `NameResolutionService.ensureResolved`, which
///      fetches the profile and upserts server name / bare extension into
///      the rubrica (every userId has a server-guaranteed interno; a fetch
///      that yields neither is logged as a real error).
///
/// Debug/diagnostics screens (explicitly labeled) and technical-id captions
/// in QR/invite flows (small, monospaced, labeled "ID tecnico") are the only
/// exemptions.
///
/// **Consolidation note (2026-07-29):** this used to be documented as "THE
/// single place" while at least 13 other call sites across the app quietly
/// reimplemented their own version of this chain (some with no
/// placeholder-awareness at all, one — the old `resolveDialInput` — a
/// documented DELIBERATE parallel implementation that ignored `displayName`
/// entirely). That is exactly why the "Phone #100" / "Int. 100" / bare
/// "100" inconsistency kept coming back after being "fixed" before: fixing
/// one copy never touched the others. Every one of those call sites has
/// been redirected to call `forUser` (or the `resolvedExtension`/
/// `isPlaceholderName` primitives below) instead of formatting its own
/// copy. If you are about to add a new `allSatisfy({ $0.isNumber })` check
/// or a new "#\\d+" regex anywhere in this app to detect/format an
/// extension — stop, this is the file that check belongs in.
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
    /// site has one; `knownExtension`/`knownPhoneNumber` are used when the
    /// caller already has that structured data in hand (e.g. a freshly
    /// dialed extension, or a `PublicUser` profile fetch) instead of only a
    /// formatted string. `contacts` is an optional pre-loaded rubrica
    /// snapshot (falls back to a fresh `ContactsStore().load()`).
    static func forUser(_ userId: String,
                        serverDisplay: String? = nil,
                        knownExtension: String? = nil,
                        knownPhoneNumber: String? = nil,
                        contacts: [ContactsStore.StoredContact]? = nil) -> String {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return "Sconosciuto" }
        let stored = contacts ?? ContactsStore().load()
        let match = stored.first(where: { $0.userId == id })

        // 1. Rubrica (alias / local display name) — a REAL human-set name
        //    wins outright. Skip anything UUID-shaped or one of the
        //    recognised placeholder shapes (rule 5 — a stale cached
        //    "Phone #100"/"New User"/etc. is "no name set", not a name).
        if let match {
            let dn = match.displayName.trimmingCharacters(in: .whitespaces)
            if !dn.isEmpty, !isPlaceholderName(dn) { return dn }
        }
        // 2. Server-supplied display, sanitised. Same placeholder check —
        //    a legacy label the SERVER (or an un-migrated peer) still
        //    sends verbatim must not leak through just because it isn't
        //    UUID-shaped.
        if let sd = serverDisplay {
            let cleaned = StringSanitiser.displayName(sd, fallback: "")
            if !cleaned.isEmpty, !isPlaceholderName(cleaned) {
                return cleaned
            }
        }
        // No real name (rubrica alias or server display) resolved above —
        // kick background enrichment NOW, regardless of which fallback tier
        // ends up rendering below. 2026-07-30 fix: this used to only fire
        // from tier 6 (the last-resort short8/UUID case), so any peer
        // reachable via a bare extension (virtually everyone — every
        // account has one) or a known phone number never triggered a
        // profile fetch at all, and stayed on that fallback forever even
        // though the real name was one `getPublicUserIfExists` away. Safe
        // to call unconditionally: deduped + cooldown-gated, no-op for
        // ids too short to be a real userId.
        NameResolutionService.shared.ensureResolved(userId: id)
        // 3. Known phone number — already self-evidently a number. 2026-07-29
        //    (Pavel, explicit product decision): a phone number only ever
        //    reaches a StoredContact/knownPhoneNumber because its owner
        //    explicitly opted in — either the server's opt-in
        //    PublicPhoneNumber profile field, or the wire `caller_display`
        //    self-disclosure that ONLY carries a phone-shaped value when
        //    the caller's own "show my phone number" preference is active
        //    (see `NameResolutionService.enrichFromCallProfile`'s
        //    `profilePhone ?? callLinkedPhone(for:)`). There is no path
        //    today for a phone number to be known WITHOUT that explicit
        //    choice — so honouring it ahead of the bare (but always-
        //    present, never explicitly chosen) extension is what "prefer
        //    showing my phone number" actually means to the person who set
        //    it. Extension moves to tier 4, still the reliable fallback
        //    for every peer who hasn't published a phone.
        if let phone = (knownPhoneNumber ?? match?.phoneNumber)?
            .trimmingCharacters(in: .whitespaces), !phone.isEmpty {
            return phone
        }
        // 4. Known extension — bare digits, no prefix, no padding. See
        //    `resolvedExtension` for the recovery priority.
        if let ext = resolvedExtension(for: id, serverDisplay: serverDisplay,
                                       knownExtension: knownExtension, contacts: stored) {
            return ext
        }
        // 5. Legacy dev-seed convention ("user-mario" → "Mario").
        if id.hasPrefix("user-") { return String(id.dropFirst(5)).capitalized }
        // 6. Short human-scale ids (extensions typed on the dialpad etc.)
        //    pass through; long opaque ids get the humane short8 fallback —
        //    TRANSIENTLY. Pavel corrected rule (2026-07-20): "Utente
        //    short8…" is not an acceptable steady state — every userId has
        //    a server-side extension ("interno"), so kick a fire-and-forget
        //    profile fetch. NameResolutionService upserts the server name
        //    (or bare extension) into the rubrica and .contactsDidChange
        //    re-renders every observer; this call stays synchronous and
        //    returns the placeholder only for the instant the fetch is in
        //    flight.
        if id.count > 12 {
            NameResolutionService.shared.ensureResolved(userId: id)
            return shortUserFallback(id)
        }
        return id
    }

    /// Best-known bare extension for an identity, independent of whatever
    /// display NAME resolution decided — used both internally by `forUser`
    /// and by any surface that shows the extension in its OWN slot
    /// separately from the main name (e.g. ContactDetailScreen's "INTERNO"
    /// metadata row, or a call-history subtitle). Returns nil rather than
    /// falling through to a phone number / short8 fallback — callers that
    /// want the FULL chain should call `forUser` instead.
    ///
    /// Recovery priority: explicit `knownExtension` → the rubrica's own
    /// structured `extension` field → digits embedded in the rubrica's
    /// displayName (bare, or a legacy "Phone #N"/"Int. N"/etc. label) →
    /// digits embedded in `serverDisplay` the same way.
    static func resolvedExtension(for userId: String,
                                  serverDisplay: String? = nil,
                                  knownExtension: String? = nil,
                                  contacts: [ContactsStore.StoredContact]? = nil) -> String? {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = contacts ?? ContactsStore().load()
        let match = stored.first(where: { $0.userId == id })

        if let ext = knownExtension ?? match?.`extension`, let bare = bareDigits(ext) {
            return bare
        }
        if let dn = match?.displayName {
            let t = dn.trimmingCharacters(in: .whitespaces)
            if let bare = bareDigits(t) ?? extensionDigits(fromLegacyLabel: t) { return bare }
        }
        if let sd = serverDisplay {
            let cleaned = StringSanitiser.displayName(sd, fallback: "")
            if let bare = bareDigits(cleaned) ?? extensionDigits(fromLegacyLabel: cleaned) { return bare }
        }
        return nil
    }

    /// Canonical extension rendering: bare digits, no prefix word of any
    /// kind, no zero-padding. Used by every self-profile screen that shows
    /// the LOCAL user's own extension — Pavel's rule applies there too, not
    /// just to peers — where the extension is already known as a plain
    /// string and there is no rubrica/peer lookup to do.
    static func formatExtension(_ raw: String) -> String {
        bareDigits(raw) ?? raw.trimmingCharacters(in: .whitespaces)
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

    /// True when `s` is one of the recognised placeholder/legacy shapes
    /// this resolver must never surface as if it were a real human-chosen
    /// name: empty, a raw UUID, our own short8/short-group transient
    /// fallback, "New User", or a legacy "Phone #N"/"Extension #N"/
    /// "Int. N"/"Interno N"/"Ext. N"/"(ext. N)"/"Nebenstelle N" label this
    /// app (an earlier build), another platform, or a fast-setup QR minted
    /// before the fix may still have lying around in a cache or on the
    /// wire (rule 5 — defense in depth: this is checked EVERY time a name
    /// is read from a stored/cached value or a peer's wire data, not just
    /// at the point where new rows are created).
    ///
    /// Deliberately does NOT flag a bare extension ("103") on its own —
    /// that IS the correct steady-state rendering (rule 3), not an absence
    /// of a name. `NameResolutionService.mayOverwrite` has its own narrower
    /// check for "is this stored value our own synthetic bare-extension
    /// fallback and therefore eligible to be upgraded to a real name later".
    static func isPlaceholderName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if looksLikeUUID(t) { return true }
        if t.hasPrefix("Utente ") && t.hasSuffix("…") { return true }
        if t.hasPrefix("Gruppo ") && t.hasSuffix("…") { return true }
        if t.caseInsensitiveCompare("New User") == .orderedSame { return true }
        if extensionDigits(fromLegacyLabel: t) != nil { return true }
        return false
    }

    /// True when `s` is nothing but digits — the bare, rule-3-compliant
    /// rendering of a PBX extension. A stored rubrica name in this exact
    /// shape was written by `NameResolutionService`'s own synthetic
    /// fallback (never typed by a human through the contact editor, which
    /// collects the extension in its own separate field) — see
    /// `NameResolutionService.mayOverwrite`, the one place this distinction
    /// (as opposed to `isPlaceholderName`) actually matters.
    static func isBareExtension(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { $0.isNumber }
    }

    /// The known legacy "<label> <digits>" shapes — see `isPlaceholderName`
    /// kdoc. Lowercased, punctuation-free label tokens only; the digit
    /// extraction itself is done by `extensionDigits(fromLegacyLabel:)`.
    private static let legacyExtensionLabels: Set<String> =
        ["phone", "extension", "ext", "int", "interno", "nebenstelle"]

    /// If `s` is a legacy "<label><sep><digits>" placeholder — "Phone #100",
    /// "Phone N100", "Extension #100", "Int. 100", "Interno 100", "Ext. 100",
    /// "(ext. 100)", "Nebenstelle 100" — returns the bare digits, else nil.
    /// These formats were always literally `"<label>\(extension)"`, so the
    /// trailing digits ARE the real extension, never a guess. Bare digits
    /// with NO label ("100" alone) deliberately return nil here — that
    /// shape is handled directly by `bareDigits`, not this legacy-label
    /// recovery path.
    static func extensionDigits(fromLegacyLabel s: String) -> String? {
        var body = s.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("("), body.hasSuffix(")"), body.count > 2 {
            body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard let firstDigitIdx = body.firstIndex(where: { $0.isNumber }) else { return nil }
        let rawLabel = body[body.startIndex..<firstDigitIdx]
        guard !rawLabel.isEmpty else { return nil }
        // Uppercase "N" only (not lowercase "n") so this strips the
        // separator in "Phone N100" without eating the trailing "n" of a
        // real label word like "Extension" or "Nebenstelle".
        let label = rawLabel
            .trimmingCharacters(in: CharacterSet(charactersIn: "#.\u{00B0}N "))
            .lowercased()
        guard legacyExtensionLabels.contains(label) else { return nil }
        let digits = body[firstDigitIdx...]
        guard digits.allSatisfy({ $0.isNumber }) else { return nil }
        return bareDigits(String(digits))
    }

    /// `s` reduced to its bare digit value with no leading-zero padding
    /// ("007" → "7"), or nil if `s` (trimmed) isn't purely digits. `Int`
    /// round-trips for the normal case; a manual leading-zero strip covers
    /// the pathological very-long-digit-string edge case `Int(_:)` would
    /// overflow on.
    static func bareDigits(_ s: String) -> String? {
        let d = s.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, d.allSatisfy({ $0.isNumber }) else { return nil }
        if let n = Int(d) { return String(n) }
        let stripped = d.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }
}

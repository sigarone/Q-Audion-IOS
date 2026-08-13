import Contacts
import Foundation
import QAudionEngine

/// W-EXTRESOLVE (Pavel corrected rule, 2026-07-20) — async backstop of the
/// central `DisplayName` chain: when a userId has NO local rubrica name, the
/// short8 placeholder ("Utente a1b2c3d4…") may appear only for the instant a
/// profile fetch is in flight. This service performs that fetch and lands the
/// result in `ContactsStore`, whose `save()` posts `.contactsDidChange` so
/// every observing surface (chat rows, banners, group-call roster via
/// `BCryptoGroupCallManager`'s re-resolve hook) re-renders reactively.
///
/// Resolution preference on fetch: server display name → extension rendered
/// as bare digits, no prefix (Pavel, 2026-07-29: "probably better to drop
/// the word 'phone' entirely" — applies to every prefix word, not just
/// that one; the server guarantees every userId has an interno). If a
/// profile comes back with NEITHER, that is a real upstream error and is
/// logged as such — never silently accepted.
///
/// Generalises the one-off fetch+upsert that `InCallContainer.bindAppState`
/// (W444) does for the 1:1 call peer, with the same endpoint
/// (`GET /api/v1/users/{id}` via `AccountApi.getPublicUser`) and the same
/// sanitisation (`StringSanitiser.displayName`).
///
/// Threading: `ensureResolved` is nonisolated and cheap — it is kicked
/// fire-and-forget from `DisplayName.forUser`, which runs on arbitrary
/// threads (WS delegate queue, main). Internal state is NSLock-guarded;
/// the `AccountApi` is obtained through a `@MainActor` source closure
/// injected once from `AppState.initialize()` (primitives-only closure
/// pattern, same as LiveLogStreamer/CarPlayBridge — AppState is never
/// touched directly).
final class NameResolutionService: @unchecked Sendable {

    static let shared = NameResolutionService()

    typealias ApiSource = @MainActor () -> AccountApi?

    private let lock = NSLock()
    private var apiSource: ApiSource?
    /// Per-id in-flight dedup — a burst of `forUser` calls for the same
    /// unresolved id (every chat-row render) coalesces into one fetch.
    private var inFlight: Set<String> = []
    /// Last attempt timestamps: failed/empty fetches are not retried more
    /// often than `retryCooldown`, so a hot render loop cannot hammer the
    /// server for a broken id.
    private var lastAttempt: [String: Date] = [:]
    private let retryCooldown: TimeInterval = 30

    /// W-NAMEREFRESH (2026-08-13) — provenance for the chat-activity refresh
    /// path (`maybeRefreshFromChatActivity`). Remembers the value/time WE
    /// last auto-wrote for an id, so a later refresh can tell "still exactly
    /// what we set — the peer may have renamed on the server, safe to
    /// re-check" apart from "changed since — a human touched this, never
    /// clobber it" (the exact guarantee `mayOverwrite` gives the placeholder
    /// path, W-NAMEOVERWRITE-DIAG 2026-08-04). In-memory only — resets on
    /// relaunch, which just costs one extra fetch cycle, not a safety hole
    /// (`retryCooldown` still throttles the network call either way).
    private var lastAutoResolvedName: [String: String] = [:]
    private var lastAutoResolvedAt: [String: Date] = [:]
    private let refreshTtl: TimeInterval = 3600

    private let contactsStore = ContactsStore()

    /// Inject the live-provider API source. Called once from
    /// `AppState.initialize()`.
    func configure(apiSource: @escaping ApiSource) {
        lock.lock()
        self.apiSource = apiSource
        lock.unlock()
    }

    /// W-ORPHANPEER — where to report "this account exists / does not exist".
    /// Same primitives-only `@MainActor` closure pattern as ``ApiSource``, so
    /// this service still never touches `AppState` directly.
    typealias OrphanSink = @MainActor (String, ProfileLookupOutcome) -> Void

    private static let sinkLock = NSLock()
    private static var orphanSink: OrphanSink?

    /// Inject the orphan sink. Called once from `AppState.initialize()`.
    func configure(orphanSink: @escaping OrphanSink) {
        Self.sinkLock.lock()
        Self.orphanSink = orphanSink
        Self.sinkLock.unlock()
    }

    /// Hop to the main actor and hand the outcome to whoever is listening.
    /// A no-op before `configure(orphanSink:)` has run, which is correct: at
    /// that point no list is on screen to hide anything from.
    private static func recordOrphanOutcome(id: String, outcome: ProfileLookupOutcome) async {
        let sink = sinkLock.withLock { orphanSink }
        guard let sink else { return }
        await MainActor.run { sink(id, outcome) }
    }

    /// Fire-and-forget: fetch the profile for `userId` (deduped, cooled
    /// down) and upsert a resolved display name into the rubrica. Safe to
    /// call from any thread, returns immediately.
    func ensureResolved(userId: String) {
        ensureResolvedInternal(userId: userId, allowRefreshOfRealName: false)
    }

    /// W-NAMEREFRESH (2026-08-13) — Android-parity chat-activity refresh
    /// (mirrors `ReceiveMessageUseCase.ensureContactResolved`, called on
    /// every inbound chat message there). Call this from the same
    /// chat-decrypt point that already fires `maybeAnnounceAvatarTo`.
    ///
    /// Root cause this closes: `ensureResolved` above only ever fetches
    /// while the rubrica still shows a placeholder/bare-extension — once
    /// ANY real name is cached, `DisplayName.forUser` never calls it again,
    /// so a chat-only peer's later server-side rename was invisible
    /// forever (confirmed 2026-08-13: iOS has no push/announce for name
    /// changes, unlike avatar's `avatar_announce`). This method MAY
    /// refresh an already-real name, but only when it is STILL exactly the
    /// value we ourselves last auto-wrote and `refreshTtl` has elapsed —
    /// anything that doesn't match what we last wrote is a human edit
    /// (manual rubrica rename, or a device-contact match) and is left
    /// alone, same guarantee `mayOverwrite` gives the placeholder path.
    /// Without that check this would resurrect the exact bug
    /// W-NAMEOVERWRITE-DIAG (2026-08-04) hardened against — a rename
    /// silently reverting.
    func maybeRefreshFromChatActivity(userId: String) {
        ensureResolvedInternal(userId: userId, allowRefreshOfRealName: true)
    }

    private func ensureResolvedInternal(userId: String, allowRefreshOfRealName: Bool) {
        let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        // Short human-scale ids (extensions typed on the dialpad etc.)
        // render as-is in DisplayName.forUser — nothing to resolve.
        guard !id.isEmpty, id.count > 12 else { return }

        lock.lock()
        let now = Date()
        if inFlight.contains(id) { lock.unlock(); return }
        if let last = lastAttempt[id], now.timeIntervalSince(last) < retryCooldown {
            lock.unlock(); return
        }
        inFlight.insert(id)
        lastAttempt[id] = now
        let src = apiSource
        lock.unlock()

        guard let src else {
            // No provider injected yet (very early startup). Cooldown map
            // already stamped — the next forUser miss after 30s retries.
            lock.lock(); inFlight.remove(id); lock.unlock()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            defer {
                _ = self.lock.withLock { self.inFlight.remove(id) }
            }
            // Re-check the rubrica inside the task: another path (QR scan,
            // discover refresh, InCallContainer's own W444 fetch) may have
            // landed a real name between the forUser miss and now.
            //
            // W-PHONEVERIFY (2026-07-30, THIRD fix same day — real-device
            // regression, account 135/b649b53f): `isPlaceholderName` alone
            // does NOT flag a bare-extension value ("135") — deliberately,
            // it's DisplayName.forUser's correct tier-4 rendering on its
            // own (see that function's kdoc). But THIS gate decides
            // whether to even ATTEMPT a fresh profile fetch — and
            // `forUser` only calls `ensureResolved` in the first place
            // when tier 1 doesn't already return something (a bare
            // extension counts, once cached). Net effect: a userId whose
            // rubrica row was ever seeded with the bare-extension fallback
            // could NEVER be re-resolved again, even after the server
            // display_name that was empty at the time is later actually
            // set (confirmed live: account 135's server display_name is
            // "Pavel Ivanov" today, yet the incoming-call screen still
            // showed "135" and the rubrica never picked it up). Also
            // check `isBareExtension`, matching `mayOverwrite`'s existing
            // rule below — a synthetic value must never block its OWN
            // upgrade path.
            if let stored = self.contactsStore.load().first(where: { $0.userId == id }),
               !DisplayName.isPlaceholderName(stored.displayName),
               !DisplayName.isBareExtension(stored.displayName) {
                // W-NAMEREFRESH: a real name is cached — only worth a fresh
                // fetch if the caller allows refreshing real names AND it
                // is still exactly what WE last wrote AND enough time has
                // passed. Otherwise this is either the placeholder-only
                // caller (never refreshes a real name) or a human edit
                // (never refreshed, at any age).
                guard allowRefreshOfRealName else { return }
                let (lastAuto, lastAt) = self.lock.withLock {
                    (self.lastAutoResolvedName[id], self.lastAutoResolvedAt[id])
                }
                guard let lastAuto, stored.displayName == lastAuto,
                      let lastAt, Date().timeIntervalSince(lastAt) >= self.refreshTtl else { return }
            }
            guard let api = await src() else {
                RTLog.warn("NameResolve", "no live provider for \(id.prefix(8))… — will retry")
                return
            }
            do {
                // W-ORPHANPEER — the `IfExists` variant so a 404 (the account
                // does not exist) is distinguishable from every other failure
                // (we could not find out). The plain throwing call, and the
                // `try? await` form used elsewhere in the app, both flatten
                // the two together and cannot drive a decision to hide.
                let pub = try await api.getPublicUserIfExists(userId: id)
                let outcome = classifyProfileLookup(succeeded: pub != nil, httpStatus: pub == nil ? 404 : nil)
                await Self.recordOrphanOutcome(id: id, outcome: outcome)
                if let pub {
                    // W-AUTOSAVE — MUST run before `apply` below: when a
                    // device-contact match seeds a REAL local name for a
                    // brand-new peer, `apply`'s own `mayOverwrite`
                    // placeholder-detection then correctly refuses to
                    // downgrade it to the synthetic "Int. NNN" fallback.
                    self.enrichFromCallProfile(pub, for: id)
                    self.apply(pub, for: id, allowRefreshOfRealName: allowRefreshOfRealName)
                } else {
                    // Not an error: the server answered, clearly, that this
                    // account is gone. Logging it as a failure is what sent
                    // people hunting a server bug that was not there.
                    RTLog.info("NameResolve", "no account on the server for \(id.prefix(8))… — hidden from pickers")
                }
            } catch {
                // Pavel rule: a userId we cannot resolve to name/extension is
                // a real error, never a silently acceptable steady state.
                // W-ORPHANPEER — but it is NOT evidence of absence: leave the
                // orphan set untouched so a dropped connection never empties
                // the address book, and a failed retry never un-hides a peer
                // we already know is gone.
                RTLog.error("NameResolve", "profile fetch FAILED for \(id.prefix(8))…: \(error)")
            }
        }
    }

    // MARK: - W-AUTOSAVE — call-driven address-book auto-population

    /// W-CALLBOOK reconciliation (2026-07-29): `ensureResolved`/
    /// `enrichFromCallProfile` are kicked from `DisplayName.forUser`, which
    /// is called from EVERYWHERE a peer name is rendered — chat rows
    /// (`HomeView`), group-call rosters, not just actual calls. Without a
    /// gate here, merely opening the chat list for a phone-verified peer
    /// not yet in the rubrica would trigger device-contact enrichment and
    /// an auto-save, violating the product rule ("populated automatically
    /// ONLY from calls made and received", phone number "ONLY through an
    /// actual encrypted call event"). `markCallLinkedPeer` is called from
    /// AppState's two call-start sites (incoming `call_incoming` handler,
    /// outgoing `dialAndCall`/`startCall`) — trivial, synchronous, in-memory
    /// `Set`/`Dictionary` writes, the same safety class as the
    /// `cachedContacts` snapshot reads already done in those same blocks.
    /// `enrichFromCallProfile` below is a no-op for any id that has never
    /// been marked this way.
    private static let callLinkLock = NSLock()
    private static var callLinkedPeerIds: Set<String> = []
    private static var callLinkedPeerPhones: [String: String] = [:]

    /// Mark `id` as "a real call with this peer is happening or just
    /// happened", optionally carrying the wire `caller_display` value from
    /// that SAME call (already sanitised by the caller) as a second phone
    /// signal alongside the peer's opt-in public-profile field — mirrors
    /// Desktop's `extractCallPhoneNumber`/`markCallLinkedPeer` and Android's
    /// `phoneNumberOf`/`CallerDisplayCache` exactly, so all three clients
    /// treat the same wire value identically.
    static func markCallLinkedPeer(_ id: String, callerDisplay: String? = nil) {
        guard !id.isEmpty else { return }
        callLinkLock.lock()
        callLinkedPeerIds.insert(id)
        if let phone = phoneNumberOf(callerDisplay) {
            callLinkedPeerPhones[id] = phone
        }
        callLinkLock.unlock()
    }

    private static func isCallLinkedPeer(_ id: String) -> Bool {
        callLinkLock.lock()
        defer { callLinkLock.unlock() }
        return callLinkedPeerIds.contains(id)
    }

    private static func callLinkedPhone(for id: String) -> String? {
        callLinkLock.lock()
        defer { callLinkLock.unlock() }
        return callLinkedPeerPhones[id]
    }

    /// Phone-shaped extraction from an arbitrary wire `caller_display`
    /// string — mirrors Desktop's `extractCallPhoneNumber` (store.svelte.ts)
    /// and Android's `phoneNumberOf` (CallPeerNameViewModel.kt) exactly: a
    /// leading `+` or at least 7 digits reads as a phone number, otherwise
    /// this is an extension/name/something else and yields nil. Pure, no
    /// I/O. `internal` (not `private`) so it is directly unit-testable.
    static func phoneNumberOf(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        let digitCount = t.filter { $0.isNumber }.count
        guard digitCount > 0 else { return nil }
        return (t.hasPrefix("+") || digitCount >= 7) ? t : nil
    }

    /// The rubrica starts EMPTY and fills in automatically from calls made
    /// and received, no manual import required (Pavel spec 2026-07-29).
    /// Runs from the SAME already-async, already-off-the-call-setup-hot-path
    /// `Task` `ensureResolved` kicks off after a real network fetch —
    /// nothing here can ever delay key generation or ringing, because by
    /// the time this executes the profile fetch (and therefore the call
    /// itself) has already happened.
    ///
    /// Two independent phases:
    ///   1. Best-effort device-address-book enrichment (name + photo) —
    ///      ONLY for a peer we have genuinely never heard of before, and
    ///      only when Contacts access is ALREADY `.authorized` (a
    ///      read-only check — this NEVER calls `requestAccess`).
    ///   2. Always fill `extension`/`phoneNumber` blanks via
    ///      `insertIfAbsentOrFillBlanks` — independent of whether phase 1
    ///      found a match. Never touches `displayName` either way.
    ///
    /// Called BEFORE `apply(_:for:)` below: when phase 1 seeds a REAL local
    /// name for a brand-new peer, `apply`'s own `mayOverwrite`
    /// placeholder-detection then correctly refuses to downgrade it to the
    /// synthetic "Int. NNN" fallback — no change needed there for that
    /// half. `apply`'s reconstruction of an EXISTING row DOES need to
    /// thread `phoneNumber`/`extension` through unchanged (see its own
    /// comment) or its very next upsert would immediately wipe what this
    /// method just wrote.
    private func enrichFromCallProfile(_ pub: PublicUser, for id: String) {
        guard Self.isCallLinkedPeer(id) else { return }
        let ext = pub.extensionNumber.map { String($0) }
        let trimmedPhone = pub.phoneNumber?.trimmingCharacters(in: .whitespaces)
        let profilePhone = (trimmedPhone?.isEmpty == false) ? trimmedPhone : nil
        // Reconciliation 2026-07-29: `pub.phoneNumber` only ever carries the
        // peer's OPT-IN public-profile field, which most accounts never set
        // — the wire `caller_display` captured at call-start time (the
        // caller's own chosen caller-id) is a second, independent signal
        // that this call itself is "from a phone number". Prefer the
        // server-confirmed opt-in value when present, else fall back to it.
        let phone = profilePhone ?? Self.callLinkedPhone(for: id)
        guard ext != nil || phone != nil else { return }

        // Phase 1 — device-contact enrichment.
        //
        // W-PHONEVERIFY (2026-07-30, real-device regression): this gate
        // used to key off "does ANY row exist" — but `insertIfAbsentOrFillBlanks`
        // deliberately never touches displayName on an EXISTING row (a real
        // human rename must never be clobbered), so once a row was
        // auto-created with only a synthetic bare-extension/placeholder
        // name (extension/phone alone, no real name yet — e.g. from Phase 2
        // below, or `apply()`'s own fallback), the device lookup was
        // skipped FOREVER for that peer — even after later adding them to
        // the native address book. Key off "does a REAL name already
        // exist" instead, the actual condition that makes the lookup
        // pointless.
        let hasRealLocalName = {
            guard let dn = self.contactsStore.load().first(where: { $0.userId == id })?.displayName else { return false }
            let trimmed = dn.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !DisplayName.isPlaceholderName(trimmed) && !DisplayName.isBareExtension(trimmed)
        }
        if CallEnrichmentGate.shouldAttemptDeviceLookup(
            hasExistingLocalRow: hasRealLocalName(),
            phoneNumber: phone,
            isContactsAuthorized: CNContactStore.authorizationStatus(for: .contacts) == .authorized
        ), let phone, let match = DeviceContactLookup.lookup(phoneNumber: phone) {
            // Race guard — re-evaluate the SAME gate immediately before
            // writing: a manual rename, a concurrent `ensureResolved` for
            // the same id, or InCallContainer's own W444 fetch may have
            // landed a REAL name in the window since the check above.
            if CallEnrichmentGate.shouldAttemptDeviceLookup(
                hasExistingLocalRow: hasRealLocalName(),
                phoneNumber: phone,
                isContactsAuthorized: CNContactStore.authorizationStatus(for: .contacts) == .authorized
            ) {
                let photoUrl = match.thumbnailData.flatMap {
                    DeviceContactLookup.cachePhoto($0, forUserId: id)
                }
                let hadExistingRow = self.contactsStore.load().first(where: { $0.userId == id }) != nil
                contactsStore.insertIfAbsentOrFillBlanks(
                    userId: id,
                    fallbackDisplayName: match.name,
                    extensionNumber: ext,
                    phoneNumber: phone,
                    avatarUrl: photoUrl
                )
                // insertIfAbsentOrFillBlanks never writes displayName onto
                // an EXISTING row — do that explicitly here, now that
                // hasRealLocalName() has already confirmed any existing
                // value is only a synthetic bare-extension/placeholder,
                // safe to upgrade to the real device-contact name.
                if hadExistingRow {
                    // W-NAMEOVERWRITE-DIAG (2026-08-04): Pavel reported a
                    // group call reverting a just-renamed contact back to
                    // an old value. hasRealLocalName() SHOULD block this
                    // path once a real rename is stored, but the only way
                    // to confirm whether THIS write is the culprit (vs.
                    // apply()'s below, vs. something in GroupCallView not
                    // yet found) is to see the before/after value on the
                    // next real occurrence — never logged before now.
                    let before = self.contactsStore.load().first(where: { $0.userId == id })?.displayName ?? "<none>"
                    RTLog.warn("NameResolve", "Phase1 overwriteDisplayName id=\(id.prefix(8)) before=\"\(before)\" after=\"\(match.name)\" (device-contact match)")
                    contactsStore.overwriteDisplayName(userId: id, to: match.name)
                }
                RTLog.info("NameResolve", "device-contact match for \(id.prefix(8))… -> \"\(match.name)\"")
            }
        }

        // Phase 2 — always fill extension/phoneNumber blanks, independent
        // of whether phase 1 found a match. Never touches displayName;
        // the fallback below is only ever used the one time this ALSO
        // happens to be the very first write for `id` (phase 1 didn't run
        // — no phone, not authorized, or no device match).
        let fallback = contactsStore.load().first(where: { $0.userId == id })?.displayName
            ?? DisplayName.shortUserFallback(id)
        contactsStore.insertIfAbsentOrFillBlanks(
            userId: id,
            fallbackDisplayName: fallback,
            extensionNumber: ext,
            phoneNumber: phone
        )
    }

    // MARK: - Internals

    private func apply(_ pub: PublicUser, for id: String, allowRefreshOfRealName: Bool) {
        let serverName = StringSanitiser.displayName(pub.displayName ?? "", fallback: "")
        let ext = pub.extensionNumber ?? 0

        // W-EXTPREFIX (Pavel, 2026-07-29 re-escalation): bare digits, no
        // "Int."/"Phone"/etc. prefix — same `DisplayName.isPlaceholderName`
        // check `forUser` uses, so a legacy-shaped `serverName` (an
        // un-migrated peer, or a stale value some other platform still
        // sends) is never persisted verbatim into the rubrica either.
        let resolved: String
        if !serverName.isEmpty && !DisplayName.isPlaceholderName(serverName) {
            resolved = serverName
        } else if ext > 0 {
            resolved = String(ext)
        } else {
            // Server guarantees every userId an extension — reaching here
            // means something is broken upstream. Real error, not a warn.
            RTLog.error("NameResolve", "profile for \(id.prefix(8))… has NEITHER display_name NOR extension — upstream data broken")
            return
        }

        let stored = contactsStore.load().first(where: { $0.userId == id })
        if let s = stored {
            // NEVER overwrite a real user-given rubrica name; only fill
            // empty/UUID-shaped/placeholder rows (and upgrade our own
            // synthetic bare-extension name to a real server name) — UNLESS
            // this is the W-NAMEREFRESH chat-activity path AND the stored
            // value is still exactly what WE last auto-wrote (re-checked
            // here, not just at the call site above, to close the race
            // between that check and this actual write — a manual edit
            // landing in between must still win).
            let placeholderOk = Self.mayOverwrite(s.displayName, with: resolved)
            let refreshOk: Bool = {
                guard allowRefreshOfRealName, !placeholderOk else { return false }
                let (lastAuto, lastAt) = self.lock.withLock {
                    (self.lastAutoResolvedName[id], self.lastAutoResolvedAt[id])
                }
                guard let lastAuto, s.displayName == lastAuto,
                      let lastAt, Date().timeIntervalSince(lastAt) >= self.refreshTtl else { return false }
                return true
            }()
            guard (placeholderOk || refreshOk), s.displayName != resolved else { return }
            // W-NAMEOVERWRITE-DIAG (2026-08-04): same incident as Phase 1's
            // twin log above — see enrichFromCallProfile. mayOverwrite
            // SHOULD block this once a real rename is stored; log the
            // before/after + WHY it was allowed (placeholder / bare
            // extension / chat-activity refresh) so the next occurrence
            // proves whether this is the actual culprit instead of guessing.
            let why = refreshOk ? "chat-activity-refresh"
                : DisplayName.isPlaceholderName(s.displayName) ? "placeholder" : "bare-extension"
            RTLog.warn("NameResolve", "apply() upsert id=\(id.prefix(8)) before=\"\(s.displayName)\" after=\"\(resolved)\" reason=\(why)")
            contactsStore.upsert(ContactsStore.StoredContact(
                userId: id,
                displayName: resolved,
                phoneHash: s.phoneHash,
                avatarUrl: s.avatarUrl,
                lastSeen: s.lastSeen,
                isVerified: s.isVerified,
                pubkey: s.pubkey,
                verifiedFingerprintHex: s.verifiedFingerprintHex,
                verifiedAtMs: s.verifiedAtMs,
                verificationMethod: s.verificationMethod,
                // W-ASSURANCE/W-FLOOR — this branch only updates displayName
                // for an EXISTING row; thread these through unchanged same as
                // every other field above (a routine name-resolution pass
                // must never silently wipe a contact's NFC presence record).
                presenceAuth: s.presenceAuth,
                presenceFloor: s.presenceFloor,
                // W-AUTOSAVE — same reasoning: `enrichFromCallProfile` (called
                // just before `apply`, above) may have just written these;
                // omitting them here would immediately wipe them again on
                // the very next line of the SAME resolution pass.
                phoneNumber: s.phoneNumber,
                extension: s.`extension`,
                // E2EE avatar transport (2026-07-30) — same reasoning as
                // presenceAuth/phoneNumber above: this branch only
                // updates displayName, and `apply()` runs on nearly
                // every resolved call/message, so omitting this would
                // wipe a peer's cached-avatar version on the very next
                // routine name resolution.
                avatarVersion: s.avatarVersion
            ))
        } else {
            contactsStore.upsert(ContactsStore.StoredContact(
                userId: id,
                displayName: resolved,
                phoneHash: "",
                avatarUrl: nil,
                lastSeen: nil,
                isVerified: false
            ))
        }
        // W-NAMEREFRESH: record what WE just wrote + when, so a later
        // chat-activity refresh can tell this value apart from a human
        // edit (see the guard above and `maybeRefreshFromChatActivity`'s
        // kdoc).
        lock.lock()
        lastAutoResolvedName[id] = resolved
        lastAutoResolvedAt[id] = Date()
        lock.unlock()
        // ContactsStore.save() posts .contactsDidChange — every observer
        // (AppState.cachedContacts, HomeView cache, group-call manager
        // re-resolve hook) refreshes from there; nothing else to do.
        RTLog.info("NameResolve", "resolved \(id.prefix(8))… -> \"\(resolved)\"")
    }

    /// W-EXTPREFIX consolidation (2026-07-29): placeholder detection now
    /// lives ONLY in `DisplayName.isPlaceholderName` — this used to be an
    /// independent copy (checking only empty/UUID/short8-shape, missing
    /// "Phone #N"/"Extension #N"/"New User" entirely) that could silently
    /// diverge from the canonical resolver's idea of "no name set".
    ///
    /// A stored name that is nothing but digits ("103") is our own
    /// synthetic bare-extension fallback — never typed by a human through
    /// the contact editor, which collects the extension in its own
    /// separate field — so it stays eligible to upgrade to a real server
    /// name too, same as before this consolidation (previously detected via
    /// the now-removed "Int. " prefix; the prefix is gone but the shape
    /// this needs to recognise, "just digits", still is).
    private static func mayOverwrite(_ storedName: String, with resolved: String) -> Bool {
        DisplayName.isPlaceholderName(storedName) || DisplayName.isBareExtension(storedName)
    }
}

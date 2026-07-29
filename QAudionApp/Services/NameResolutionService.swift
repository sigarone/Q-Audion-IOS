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
                self.lock.withLock { self.inFlight.remove(id) }
            }
            // Re-check the rubrica inside the task: another path (QR scan,
            // discover refresh, InCallContainer's own W444 fetch) may have
            // landed a real name between the forUser miss and now.
            if let stored = self.contactsStore.load().first(where: { $0.userId == id }),
               !DisplayName.isPlaceholderName(stored.displayName) {
                return
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
                    self.apply(pub, for: id)
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
        let hasLocalRow = { self.contactsStore.load().first(where: { $0.userId == id }) != nil }
        if CallEnrichmentGate.shouldAttemptDeviceLookup(
            hasExistingLocalRow: hasLocalRow(),
            phoneNumber: phone,
            isContactsAuthorized: CNContactStore.authorizationStatus(for: .contacts) == .authorized
        ), let phone, let match = DeviceContactLookup.lookup(phoneNumber: phone) {
            // Race guard — re-evaluate the SAME gate immediately before
            // writing: a manual rename, a concurrent `ensureResolved` for
            // the same id, or InCallContainer's own W444 fetch may have
            // landed a row in the window since the check above.
            if CallEnrichmentGate.shouldAttemptDeviceLookup(
                hasExistingLocalRow: hasLocalRow(),
                phoneNumber: phone,
                isContactsAuthorized: CNContactStore.authorizationStatus(for: .contacts) == .authorized
            ) {
                let photoUrl = match.thumbnailData.flatMap {
                    DeviceContactLookup.cachePhoto($0, forUserId: id)
                }
                contactsStore.insertIfAbsentOrFillBlanks(
                    userId: id,
                    fallbackDisplayName: match.name,
                    extensionNumber: ext,
                    phoneNumber: phone,
                    avatarUrl: photoUrl
                )
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

    private func apply(_ pub: PublicUser, for id: String) {
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
            // synthetic bare-extension name to a real server name).
            guard Self.mayOverwrite(s.displayName, with: resolved),
                  s.displayName != resolved else { return }
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
                `extension`: s.`extension`
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

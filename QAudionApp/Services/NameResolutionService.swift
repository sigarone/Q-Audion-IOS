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
/// as "Int. NNN" (the server guarantees every userId has an interno). If a
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
        sinkLock.lock()
        let sink = orphanSink
        sinkLock.unlock()
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
                self.lock.lock()
                self.inFlight.remove(id)
                self.lock.unlock()
            }
            // Re-check the rubrica inside the task: another path (QR scan,
            // discover refresh, InCallContainer's own W444 fetch) may have
            // landed a real name between the forUser miss and now.
            if let stored = self.contactsStore.load().first(where: { $0.userId == id }),
               !Self.isPlaceholderName(stored.displayName) {
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

    // MARK: - Internals

    private func apply(_ pub: PublicUser, for id: String) {
        let serverName = StringSanitiser.displayName(pub.displayName ?? "", fallback: "")
        let ext = pub.extensionNumber ?? 0

        let resolved: String
        if !serverName.isEmpty && !DisplayName.looksLikeUUID(serverName) {
            // A bare-numeric display name IS the extension (same convention
            // as DisplayName.forUser step 2).
            resolved = serverName.allSatisfy({ $0.isNumber }) ? "Int. \(serverName)" : serverName
        } else if ext > 0 {
            resolved = "Int. \(ext)"
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
            // synthetic "Int. NNN" to a real server name).
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
                presenceFloor: s.presenceFloor
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

    /// True when a STORED display name is one of the transient/legacy
    /// placeholder shapes the resolver is allowed to replace.
    private static func isPlaceholderName(_ dn: String) -> Bool {
        let t = dn.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if DisplayName.looksLikeUUID(t) { return true }
        if t.hasPrefix("Utente ") && t.hasSuffix("…") { return true }
        return false
    }

    private static func mayOverwrite(_ storedName: String, with resolved: String) -> Bool {
        if isPlaceholderName(storedName) { return true }
        // Our own synthetic "Int. NNN" may upgrade to a real server name,
        // but a real name never downgrades to "Int. NNN".
        let t = storedName.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Int. "), t.dropFirst(5).allSatisfy({ $0.isNumber }),
           !resolved.hasPrefix("Int. ") {
            return true
        }
        return false
    }
}

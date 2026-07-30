import Foundation

/// Local persistence for the contacts list (peppered hash → user metadata).
///
/// Stores the result of a discover-v2 fetch so subsequent app launches show
/// contacts immediately without re-fetching. Refresh re-runs the peppered
/// hash + discover-v2 flow.
public final class ContactsStore {

    public struct StoredContact: Codable, Equatable {
        public let userId: String
        public let displayName: String
        public let phoneHash: String  // peppered hash that resolved to userId
        public let avatarUrl: URL?
        public let lastSeen: Date?
        public let isVerified: Bool
        /// Long-term identity public key, when known. Populated by the QR-scan
        /// pairing flow (IdentityQrCode / DeviceLinkBinaryQR carry the pubkey
        /// alongside the userId) and by future discover-v2 results that
        /// include published pubkeys. nil for legacy rows persisted before
        /// this field was added — old JSON decodes with pubkey=nil because
        /// Optional fields are absent-tolerant in Codable synthesis.
        public let pubkey: Data?
        /// Persistent-safety-number fingerprint (SafetyNumber.Result.fingerprintHex,
        /// 60 lowercase hex chars) at the moment the user last marked this
        /// peer verified. nil when never manually verified. Compared against
        /// the FRESHLY computed fingerprint on every ContactDetailScreen open —
        /// a mismatch means the peer's `ikEdPub` rotated since the user last
        /// verified, and the UI must downgrade to `.identityChanged` rather
        /// than keep showing a stale green checkmark. Mirrors Android
        /// `PeerTrustEntity.lastSeenFingerprintHex` semantics (the "verified
        /// pin", not just a boolean).
        public let verifiedFingerprintHex: String?
        /// Wall-clock ms when `verifiedFingerprintHex` was last set. Mirrors
        /// Android `PeerTrustEntity.verifiedAtMs`.
        public let verifiedAtMs: Int64?
        /// `TrustVerificationMethod.rawValue` used for the last manual verify
        /// ("in-person" / "qr" / "nfc" / "anti-replay" / "voice"). Stored as a
        /// plain String (not the app-target enum) to keep this engine-module
        /// type decoupled from QAudionApp's UI layer, mirroring Android
        /// `PeerTrustEntity.verificationMethod`.
        public let verificationMethod: String?
        /// W-ASSURANCE (multi-PSK-mixing SYNTHESIS.md ship step 6) — the
        /// persisted "this contact has been authenticated in person before"
        /// record. `nil` for a contact that has never reached `AssuranceState
        /// .nfcAuthenticated` (S2) — which is EVERY contact today, since S2 is
        /// unreachable until ship step 7 wires real `N>=2` NFC mixing (see
        /// `AssuranceState.qualifiesForPresenceAuthWrite`'s doc). Written ONLY
        /// by `ContactsStore.applyAssuranceOutcome` — never construct this by
        /// hand outside that write path / tests.
        ///
        /// **THIS IS A DIFFERENT WIDGET from the live per-call verdict**
        /// (`AssuranceStateUI.present`, rendered by `InCallScreen`) — a
        /// historical "has this contact ever proven physical presence"
        /// record, never the verdict of the CURRENT call. `ContactDetailScreen`
        /// renders THIS field; `InCallScreen` never reads it. See this
        /// project's "two things that must never share a widget" rule.
        public let presenceAuth: PresenceAuth?
        /// Ship step 8 (W-FLOOR) — per-contact "presence floor". `true` once
        /// this contact has EVER reached `S2` (set alongside `presenceAuth`
        /// itself by `applyAssuranceOutcome`); never cleared by an ordinary
        /// call that merely fails to re-mix NFC — only by a peer identity-key
        /// change (same clearing points as `presenceAuth` above). `nil` is
        /// treated identically to `false` everywhere this is read (Optional
        /// so legacy rows persisted before this field existed decode cleanly,
        /// same Optional-absent-tolerant convention as `pubkey` above).
        public let presenceFloor: Bool?
        /// Raw phone number actually observed for this peer — populated
        /// ONLY by (a) the manual phone-book import flow (the user picked
        /// this exact device-contact row, see `PhoneContactImportView`) or
        /// (b) the automatic auto-save-from-call enrichment
        /// (`NameResolutionService.enrichFromCallProfile` +
        /// `insertIfAbsentOrFillBlanks` below), which learns it from a
        /// genuine encrypted call with this peer via the server's public
        /// profile `phone_number` field (`PublicUser.phoneNumber`).
        /// Deliberately SEPARATE from `phoneHash` (a peppered HASH, never a
        /// raw number) — `PhoneContactImportView` used to write the raw
        /// phone into `phoneHash` by mistake; this field is the fix. `nil`
        /// for contacts we have never learned a raw phone number for (the
        /// normal case for discover-v2 / QR-scan contacts, which only ever
        /// carry `phoneHash`). Never populated by any bulk/background sync
        /// of the whole device address book — only by an actual call or a
        /// user-picked manual import row.
        public let phoneNumber: String?
        /// PBX short dial extension, as text (e.g. "103"). Populated the
        /// same way, and under the same constraints, as `phoneNumber`
        /// above — learned from a genuine call's server profile fetch
        /// (`PublicUser.extensionNumber`), never bulk-synced. `nil` until
        /// learned.
        public let `extension`: String?
        /// E2EE avatar transport (2026-07-30, see
        /// `docs/E2EE_AVATAR_TRANSPORT_DESIGN.md`) — `avatarUrl` above is
        /// now a LOCAL `file://` path to the decrypted avatar cached by
        /// `AvatarAnnounceReceiver`, never a server URL. `avatarVersion`
        /// is the sender's monotonic counter from the last
        /// `avatar_announce` actually applied — lets a re-sent announce
        /// (e.g. on every call-connect) be deduped without
        /// re-downloading. `nil` for a contact with no avatar cached yet.
        public let avatarVersion: Int?

        public init(userId: String, displayName: String, phoneHash: String,
                    avatarUrl: URL?, lastSeen: Date?, isVerified: Bool,
                    pubkey: Data? = nil,
                    verifiedFingerprintHex: String? = nil,
                    verifiedAtMs: Int64? = nil,
                    verificationMethod: String? = nil,
                    presenceAuth: PresenceAuth? = nil,
                    presenceFloor: Bool? = nil,
                    phoneNumber: String? = nil,
                    `extension`: String? = nil,
                    avatarVersion: Int? = nil) {
            self.userId = userId
            self.displayName = displayName
            self.phoneHash = phoneHash
            self.avatarUrl = avatarUrl
            self.lastSeen = lastSeen
            self.isVerified = isVerified
            self.pubkey = pubkey
            self.verifiedFingerprintHex = verifiedFingerprintHex
            self.verifiedAtMs = verifiedAtMs
            self.verificationMethod = verificationMethod
            self.presenceAuth = presenceAuth
            self.presenceFloor = presenceFloor
            self.phoneNumber = phoneNumber
            self.`extension` = `extension`
            self.avatarVersion = avatarVersion
        }
    }

    /// W-ASSURANCE (ship step 6) — ranked, NEVER-MERGED presence/authentication
    /// tiers (design brief §"Persistence"). Only `.nfcPresent` is ever WRITTEN
    /// by this ship (`S2` is the only tier `AssuranceState.decide()` persists) —
    /// the others are modelled now for forward compatibility / cross-platform
    /// parity (Android/Desktop ports of this same enum) rather than left for a
    /// later type change. `.none` from the design's ranked list is represented
    /// by `presenceAuth == nil` (absence) — there is deliberately no `.none`
    /// case here, mirroring this file's existing nil-means-absent convention.
    public enum PresenceTier: String, Codable, Equatable {
        case sasConfirmed = "SAS_CONFIRMED"
        /// Reserved token per the design brief ("do not build, future") —
        /// never constructed by any code in this ship.
        case scanPresent = "SCAN_PRESENT"
        case nfcPresent = "NFC_PRESENT"
        /// Separate axis (earbud hw_only) — never rendered as a presence tier
        /// per the design brief; modelled here only for the shared enum shape.
        case hwKey = "HW_KEY"
    }

    /// W-ASSURANCE (ship step 6) — the persisted "this contact has been
    /// authenticated in person before" record. See `StoredContact.presenceAuth`'s
    /// doc for the widget-separation rule and `ContactsStore
    /// .applyAssuranceOutcome` for the only sanctioned write path.
    public struct PresenceAuth: Codable, Equatable {
        /// A live call's `security_event` side effect this record can be
        /// transitioned into: S1/S7 SUSPEND (greyed, "non usata nell'ultima
        /// chiamata" — record kept, `confirmedCallCount` untouched); S3
        /// REVOKEs the whole record instead (see `applyAssuranceOutcome`'s
        /// doc for why revoke, not suspend, for S3 specifically). `.active`
        /// is the default/healthy state for a freshly (re-)confirming call.
        public enum Status: String, Codable, Equatable {
            case active
            case suspended
            case revoked
        }

        public let tier: PresenceTier
        /// 64-char lowercase-hex fingerprint of the NFC secret mixed when
        /// this record was (most recently) confirmed.
        public let keyFingerprint: String
        /// Raw Ed25519 identity pubkey this record is bound to — the value
        /// `applyAssuranceOutcome` compares against on every subsequent call
        /// before treating an existing record as "the same contact,
        /// continuing" vs. starting a fresh one.
        public let peerIdentityKey: Data
        /// callId of the call that FIRST reached S2 for this contact under
        /// the CURRENT `peerIdentityKey`. Never overwritten by a later
        /// confirming call — an identity-key change clears the whole record
        /// (see `StoredContact.presenceAuth` doc), so this is never stale
        /// relative to a rotated key.
        public let firstConfirmedCallId: String
        /// Epoch ms of that first confirming call. Never overwritten.
        public let firstConfirmedAt: Int64
        /// How many DISTINCT calls (including the first) have reached S2 for
        /// this contact under the SAME `peerIdentityKey`. Incremented, never
        /// reset, until an identity change clears the whole record.
        public let confirmedCallCount: Int
        /// Free-form description of the NFC secret's attestation provenance
        /// at the time of the LAST confirming call (`AssuranceState.decide`'s
        /// `witnessOk` input) — e.g. `"secure_element"` vs. `"backup_restore"`.
        /// Deliberately a free-form String, not the {@link PresenceTier}
        /// union: this is a SEPARATE attestation axis, not another tier.
        public let witnessTier: String
        public let status: Status

        public init(tier: PresenceTier, keyFingerprint: String, peerIdentityKey: Data,
                    firstConfirmedCallId: String, firstConfirmedAt: Int64,
                    confirmedCallCount: Int, witnessTier: String, status: Status = .active) {
            self.tier = tier
            self.keyFingerprint = keyFingerprint
            self.peerIdentityKey = peerIdentityKey
            self.firstConfirmedCallId = firstConfirmedCallId
            self.firstConfirmedAt = firstConfirmedAt
            self.confirmedCallCount = confirmedCallCount
            self.witnessTier = witnessTier
            self.status = status
        }
    }

    private let defaults: UserDefaults
    private let key = "qaudion.contacts.list"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [StoredContact] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([StoredContact].self, from: data)) ?? []
    }

    public func save(_ contacts: [StoredContact]) {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        defaults.set(data, forKey: key)
        // Notify observers (e.g. AppState.cachedContacts) so they can
        // refresh without polling. All writes funnel through save(), so
        // a single post here covers upsert(), remove(), and bulk saves.
        NotificationCenter.default.post(name: .contactsDidChange, object: nil)
    }

    public func upsert(_ contact: StoredContact) {
        var current = load()
        if let idx = current.firstIndex(where: { $0.userId == contact.userId }) {
            current[idx] = contact
        } else {
            current.append(contact)
        }
        save(current)
    }

    public func remove(userId: String) {
        var current = load()
        current.removeAll { $0.userId == userId }
        save(current)
    }

    // MARK: - Auto-save-from-call (call-driven address-book enrichment)

    /// The rubrica starts EMPTY and fills in automatically from calls made
    /// and received — no manual import required for that (manual import
    /// via `PhoneContactImportView` stays available, separately, unchanged).
    /// This is the ONLY sanctioned write path for that auto-save mechanism,
    /// deliberately narrower than `upsert()`:
    ///   - Absent row   → inserted fresh, using `fallbackDisplayName`.
    ///   - Existing row → ONLY the currently-`nil` fields among
    ///     `extension` / `phoneNumber` / `avatarUrl` are filled in.
    ///     `displayName` — and every other already-set field — is NEVER
    ///     touched, so a user's manual rename (or any name a more
    ///     authoritative resolution already set) can never be clobbered by
    ///     background enrichment.
    /// Contrast with `upsert()`, which stays a full-record overwrite for
    /// its existing server-truth-refresh callers (e.g.
    /// `ContactsRefreshService`) — this method changes nothing about that.
    ///
    /// - Parameter fallbackDisplayName: used ONLY when inserting a
    ///   brand-new row — there is no existing displayName to protect in
    ///   that case.
    @discardableResult
    public func insertIfAbsentOrFillBlanks(
        userId: String,
        fallbackDisplayName: String,
        extensionNumber: String? = nil,
        phoneNumber: String? = nil,
        avatarUrl: URL? = nil
    ) -> StoredContact {
        var current = load()
        if let idx = current.firstIndex(where: { $0.userId == userId }) {
            let existing = current[idx]
            let patched = StoredContact(
                userId: existing.userId,
                displayName: existing.displayName,
                phoneHash: existing.phoneHash,
                avatarUrl: existing.avatarUrl ?? avatarUrl,
                lastSeen: existing.lastSeen,
                isVerified: existing.isVerified,
                pubkey: existing.pubkey,
                verifiedFingerprintHex: existing.verifiedFingerprintHex,
                verifiedAtMs: existing.verifiedAtMs,
                verificationMethod: existing.verificationMethod,
                presenceAuth: existing.presenceAuth,
                presenceFloor: existing.presenceFloor,
                phoneNumber: existing.phoneNumber ?? phoneNumber,
                extension: existing.`extension` ?? extensionNumber,
                avatarVersion: existing.avatarVersion
            )
            current[idx] = patched
            save(current)
            return patched
        } else {
            let inserted = StoredContact(
                userId: userId,
                displayName: fallbackDisplayName,
                phoneHash: "",
                avatarUrl: avatarUrl,
                lastSeen: nil,
                isVerified: false,
                phoneNumber: phoneNumber,
                extension: extensionNumber
            )
            current.append(inserted)
            save(current)
            return inserted
        }
    }

    /// W-PHONEVERIFY (2026-07-30): directly overwrites `displayName` for an
    /// EXISTING row — `insertIfAbsentOrFillBlanks` deliberately never
    /// touches displayName on an existing row (a real, human-set name must
    /// never be silently replaced), which also means a row auto-created
    /// with a synthetic bare-extension/placeholder name could never be
    /// upgraded later (e.g. once a device-contact match or a real server
    /// name becomes available) — the real-device mechanism behind "the
    /// name I set is ignored". This module has no access to the
    /// placeholder-detection rules (`DisplayName.isPlaceholderName`/
    /// `isBareExtension` live in QAudionApp, which imports this module, not
    /// the other way around) — callers MUST have already decided the
    /// overwrite is safe before calling this. No-op (returns false) if no
    /// row exists for `userId`.
    @discardableResult
    public func overwriteDisplayName(userId: String, to newName: String) -> Bool {
        var current = load()
        guard let idx = current.firstIndex(where: { $0.userId == userId }) else { return false }
        let existing = current[idx]
        current[idx] = StoredContact(
            userId: existing.userId,
            displayName: newName,
            phoneHash: existing.phoneHash,
            avatarUrl: existing.avatarUrl,
            lastSeen: existing.lastSeen,
            isVerified: existing.isVerified,
            pubkey: existing.pubkey,
            verifiedFingerprintHex: existing.verifiedFingerprintHex,
            verifiedAtMs: existing.verifiedAtMs,
            verificationMethod: existing.verificationMethod,
            presenceAuth: existing.presenceAuth,
            presenceFloor: existing.presenceFloor,
            phoneNumber: existing.phoneNumber,
            extension: existing.`extension`,
            avatarVersion: existing.avatarVersion
        )
        save(current)
        return true
    }

    /// E2EE avatar transport (2026-07-30) — the ONE write path for a
    /// freshly decrypted avatar. Sets `avatarUrl` to a LOCAL `file://`
    /// path (the caller has already written the decrypted bytes there —
    /// this method never touches the filesystem itself) and bumps
    /// `avatarVersion` to the sender's announced version. No-op (returns
    /// false) if no row exists for `userId` — same contract as
    /// `overwriteDisplayName`, this never creates a contact.
    ///
    /// Security-review fix (2026-07-30): the caller (`AppState
    /// .handleInboundAvatarAnnounce`) only checks "is this version newer"
    /// ONCE, synchronously, before spawning an async download+decrypt
    /// Task — two overlapping announces for the same sender (e.g. two
    /// avatar changes in quick succession, or a re-sent announce racing
    /// a slow in-flight download) can therefore have their Tasks finish
    /// out of order, and without a guard HERE the slower-finishing
    /// (older) one would win and silently regress avatarVersion
    /// backwards. This method is the single source of truth for the
    /// contact row, so the monotonic check belongs here, atomically with
    /// the write, not only at the caller's one-time pre-Task check.
    /// No-op (returns false, does NOT touch the row) if `version` is not
    /// strictly greater than the currently-stored `avatarVersion`.
    @discardableResult
    public func setAvatarLocalPath(userId: String, path: URL, version: Int) -> Bool {
        var current = load()
        guard let idx = current.firstIndex(where: { $0.userId == userId }) else { return false }
        let existing = current[idx]
        guard version > (existing.avatarVersion ?? -1) else { return false }
        current[idx] = StoredContact(
            userId: existing.userId,
            displayName: existing.displayName,
            phoneHash: existing.phoneHash,
            avatarUrl: path,
            lastSeen: existing.lastSeen,
            isVerified: existing.isVerified,
            pubkey: existing.pubkey,
            verifiedFingerprintHex: existing.verifiedFingerprintHex,
            verifiedAtMs: existing.verifiedAtMs,
            verificationMethod: existing.verificationMethod,
            presenceAuth: existing.presenceAuth,
            presenceFloor: existing.presenceFloor,
            phoneNumber: existing.phoneNumber,
            extension: existing.`extension`,
            avatarVersion: version
        )
        save(current)
        return true
    }

    public func wipeAll() {
        defaults.removeObject(forKey: key)
    }

    /// Convenience: look up a stored contact's pubkey by userId. Returns nil
    /// if the contact is unknown or was persisted before pubkey was tracked.
    /// Used by the contact-detail surface to render the canonical fingerprint
    /// without requiring callers to walk the full contact list themselves.
    public func findPubkey(userId: String) -> Data? {
        load().first(where: { $0.userId == userId })?.pubkey
    }

    // MARK: - W-ASSURANCE/W-FLOOR (ship steps 6/8) — the ONLY sanctioned
    // presenceAuth/presenceFloor write path

    /// Apply one call's final `AssuranceState` verdict to `peerUserId`'s
    /// persisted `presenceAuth`/`presenceFloor`. This is the MECHANISM half
    /// of ship steps 6/8 — `AssuranceState.qualifiesForPresenceAuthWrite`
    /// (POLICY: does this verdict even qualify) already gates whether a
    /// fresh S2 verdict is eligible; this method also owns the S1/S3/S7
    /// side effects the design brief's Persistence section documents.
    ///
    /// No-op (returns `nil`) if `peerUserId` has no existing contact row —
    /// this never CREATES a contact, only annotates one that's already there.
    ///
    /// - `S2` (`.nfcAuthenticated`) with `mediaDwellMs >=
    ///   AssuranceState.presenceAuthDwellFloorMs`: writes/updates
    ///   `presenceAuth` and sets `presenceFloor = true`. A record already
    ///   bound to the SAME `peerIdentityKey` has its `confirmedCallCount`
    ///   incremented and `firstConfirmedCallId`/`firstConfirmedAt` preserved
    ///   (never overwritten); any other existing record (different identity
    ///   key, or a `nil`/dwell-short verdict) starts a brand-new one instead
    ///   — first confirmation pins THIS call.
    /// - `S3` (`.nfcIdentityMismatch`): REVOKES — clears `presenceAuth` AND
    ///   `presenceFloor` entirely. This is a stronger response than S1/S7's
    ///   suspend deliberately: S3 means the NFC secret mixed this call was
    ///   bound to a DIFFERENT peer identity than the one on this call — the
    ///   credential itself is compromised/wrong, not merely "not used this
    ///   time", so the physical ceremony must be re-established from scratch
    ///   rather than just re-confirmed.
    /// - `S1` (`.kcFailed`) / `S7` (`.expectedNfcStripped`): SUSPENDS an
    ///   EXISTING `presenceAuth` record (`status -> .suspended`) but leaves
    ///   it, its `confirmedCallCount`, and `presenceFloor` untouched — "never
    ///   downgraded by a single call that merely failed to mix" (design
    ///   brief). No-op if there is no existing record (nothing to suspend).
    /// - Every other state (S0/S4/S5/S6/S8/S9/S10): no persistence side
    ///   effect — returns the contact unchanged. In particular S4/S5/S6 (all
    ///   still `kcStatus == .verified` with NFC genuinely mixed, just missing
    ///   one OTHER precondition) stay silent on the persisted record exactly
    ///   like a plain non-mixing call would.
    @discardableResult
    public func applyAssuranceOutcome(
        peerUserId: String,
        peerIdentityKey: Data,
        keyFingerprint: String,
        callId: String,
        state: AssuranceState,
        witnessOk: Bool,
        mediaDwellMs: Int,
        now: Date = Date()
    ) -> StoredContact? {
        guard let existing = load().first(where: { $0.userId == peerUserId }) else { return nil }

        switch state {
        case .nfcAuthenticated:
            guard AssuranceState.qualifiesForPresenceAuthWrite(state: state, mediaDwellMs: mediaDwellMs) else {
                return existing
            }
            let witnessTierTag = witnessOk ? "secure_element" : "backup_restore"
            let auth: PresenceAuth
            if let prior = existing.presenceAuth, prior.peerIdentityKey == peerIdentityKey {
                auth = PresenceAuth(
                    tier: .nfcPresent,
                    keyFingerprint: keyFingerprint,
                    peerIdentityKey: peerIdentityKey,
                    firstConfirmedCallId: prior.firstConfirmedCallId,
                    firstConfirmedAt: prior.firstConfirmedAt,
                    confirmedCallCount: prior.confirmedCallCount + 1,
                    witnessTier: witnessTierTag,
                    status: .active
                )
            } else {
                auth = PresenceAuth(
                    tier: .nfcPresent,
                    keyFingerprint: keyFingerprint,
                    peerIdentityKey: peerIdentityKey,
                    firstConfirmedCallId: callId,
                    firstConfirmedAt: Int64(now.timeIntervalSince1970 * 1000),
                    confirmedCallCount: 1,
                    witnessTier: witnessTierTag,
                    status: .active
                )
            }
            let updated = Self.rebuild(existing, presenceAuth: auth, presenceFloor: true)
            upsert(updated)
            return updated

        case .nfcIdentityMismatch:
            guard existing.presenceAuth != nil || existing.presenceFloor == true else { return existing }
            let updated = Self.rebuild(existing, presenceAuth: nil, presenceFloor: false)
            upsert(updated)
            return updated

        case .kcFailed, .expectedNfcStripped:
            guard let prior = existing.presenceAuth, prior.status != .suspended else { return existing }
            let suspended = PresenceAuth(
                tier: prior.tier, keyFingerprint: prior.keyFingerprint, peerIdentityKey: prior.peerIdentityKey,
                firstConfirmedCallId: prior.firstConfirmedCallId, firstConfirmedAt: prior.firstConfirmedAt,
                confirmedCallCount: prior.confirmedCallCount, witnessTier: prior.witnessTier, status: .suspended
            )
            let updated = Self.rebuild(existing, presenceAuth: suspended, presenceFloor: existing.presenceFloor)
            upsert(updated)
            return updated

        default:
            return existing
        }
    }

    /// Reconstruct a `StoredContact` identical to `base` except for
    /// `presenceAuth`/`presenceFloor` — every OTHER field threaded through
    /// unchanged. Centralised here (rather than repeated inline at each
    /// `applyAssuranceOutcome` branch) specifically so this is the ONE place
    /// that must stay in sync with `StoredContact`'s field list — see the
    /// type doc's warning about other reconstruction call sites across the
    /// app that must remember to thread these two fields through too.
    private static func rebuild(_ base: StoredContact, presenceAuth: PresenceAuth?, presenceFloor: Bool?) -> StoredContact {
        StoredContact(
            userId: base.userId,
            displayName: base.displayName,
            phoneHash: base.phoneHash,
            avatarUrl: base.avatarUrl,
            lastSeen: base.lastSeen,
            isVerified: base.isVerified,
            pubkey: base.pubkey,
            verifiedFingerprintHex: base.verifiedFingerprintHex,
            verifiedAtMs: base.verifiedAtMs,
            verificationMethod: base.verificationMethod,
            presenceAuth: presenceAuth,
            presenceFloor: presenceFloor,
            phoneNumber: base.phoneNumber,
            extension: base.`extension`,
            avatarVersion: base.avatarVersion
        )
    }
}

// MARK: - Call-driven enrichment policy (pure, no Contacts-framework dependency)

/// Pure decision logic for whether the auto-save-from-call path
/// (`NameResolutionService.enrichFromCallProfile` on the app side) should
/// even attempt the on-device Contacts lookup for a freshly-learned phone
/// number. Kept separate from any `CNContactStore` call — and out of the
/// `Contacts` framework entirely — so it is unit-testable here in
/// `QAudionEngine` without a device/simulator address book, and so this
/// module gains no new framework dependency.
public enum CallEnrichmentGate {
    /// - Parameters:
    ///   - hasExistingLocalRow: `true` if `ContactsStore` already has ANY
    ///     row for this peer, regardless of what its `displayName` is —
    ///     `insertIfAbsentOrFillBlanks` can never repurpose a device-
    ///     contact name onto a row that already exists, so there is
    ///     nothing to gain from a lookup once a row exists. This doubles
    ///     as the "no local name is set yet" condition.
    ///   - phoneNumber: the freshly-learned raw phone number, if any.
    ///   - isContactsAuthorized: the caller's own
    ///     `CNContactStore.authorizationStatus(for: .contacts) ==
    ///     .authorized` check, passed in as a plain `Bool` — this type has
    ///     zero Contacts-framework dependency. Callers must NEVER call
    ///     `requestAccess` to make this `true`; it must be a read-only
    ///     check of the CURRENT status.
    /// - Returns: `true` only when a phone number is present, no local row
    ///   exists yet, and the OS already granted Contacts access.
    public static func shouldAttemptDeviceLookup(
        hasExistingLocalRow: Bool,
        phoneNumber: String?,
        isContactsAuthorized: Bool
    ) -> Bool {
        guard let phoneNumber,
              !phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !hasExistingLocalRow else { return false }
        guard isContactsAuthorized else { return false }
        return true
    }
}

// MARK: - Notification names

public extension Notification.Name {
    /// Posted by ContactsStore.save() (and transitively by upsert/remove)
    /// whenever the persisted contacts list changes. Observers can use this
    /// to refresh in-memory caches without polling.
    static let contactsDidChange = Notification.Name("qaudion.contactsDidChange")
}

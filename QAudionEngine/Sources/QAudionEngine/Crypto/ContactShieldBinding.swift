import Foundation

// MARK: - The contact shield over the keys the chat sessions are bound to
//
// Pure: no store, no clock, no network. The caller gathers the facts (the pinned keys of the contact with their verification, the keys the
// live CHAT / CONTROL sessions are bound to, what the server publishes for the contact) and this file decides. It lives in the engine
// because the CI job that runs on every push compiles the engine tests.

/// One pinned key of a contact (a device pin, or the legacy account-level pin) reduced to the facts the contact shield reads.
public struct ContactShieldRow: Equatable, Sendable {
    /// The device the pin belongs to; empty for the legacy account-level pin.
    public let deviceId: String
    /// The safety-number fingerprint of the pinned key (lowercase hex).
    public let fingerprintHex: String
    /// A verification applies to exactly this key.
    public let verified: Bool
    /// An unsettled change is recorded for exactly this key.
    public let changePending: Bool
    /// The last ACCEPTED traffic with this device or key; nil = none recorded.
    public let lastTrafficAtMs: Int64?

    public init(deviceId: String, fingerprintHex: String, verified: Bool, changePending: Bool = false, lastTrafficAtMs: Int64? = nil) {
        self.deviceId = deviceId
        self.fingerprintHex = fingerprintHex
        self.verified = verified
        self.changePending = changePending
        self.lastTrafficAtMs = lastTrafficAtMs
    }
}

/// What the server currently publishes for a contact: the device ids, and the safety-number fingerprint of each published key (empty when
/// they could not be computed, in which case a legacy row is never dropped).
public struct PublishedDevices: Equatable, Sendable {
    public let deviceIds: Set<String>
    public let fingerprints: Set<String>

    public init(deviceIds: Set<String>, fingerprints: Set<String>) {
        self.deviceIds = deviceIds
        self.fingerprints = fingerprints
    }
}

extension IdentityShieldRules {

    /// Contact-level shield over the rows of a contact.
    ///
    /// - `bound`: the fingerprints of the peer keys the live 1:1 sessions are bound to, or nil when unknown (a session without a believable
    ///   binding, an older ratchet, an unreadable store). Nil is exactly the plain rule over every row: nothing that is green today turns
    ///   purple because of it.
    /// - Known: every bound key must be a VERIFIED row. A bound key whose row has an unsettled change gives `.changed`; a bound key on an
    ///   unverified row, or on no row at all, gives `.toVerify`. A row whose key is bound is never ignored.
    /// - Other rows: an unverified row without a marker is ignored only when it is a leftover (see `withoutStaleDevices`).
    /// - `contactChangePending`: the contact-level marker, read as it always was (a recorded change turns a contact with a verified key red).
    /// - `verifiedAtMs`: when the contact was last verified.
    public static func contactShield(
        rows: [ContactShieldRow],
        contactChangePending: Bool,
        verifiedAtMs: Int64?,
        published: PublishedDevices?,
        bound: Set<String>?
    ) -> IdentityShield {
        guard let bound else { return plainContactShield(rows, contactChangePending: contactChangePending) }
        let boundPrints = Set(bound.map { $0.lowercased() })
        if rows.isEmpty { return boundPrints.isEmpty ? .pending : .toVerify }
        var boundUnverified = false
        for boundPrint in boundPrints {
            let matching = rows.filter { $0.fingerprintHex.lowercased() == boundPrint }
            if matching.contains(where: { $0.changePending }) { return .changed }
            if !matching.contains(where: { $0.verified }) { boundUnverified = true }
        }
        let counted = withoutStaleDevices(rows, published: published, verifiedAtMs: verifiedAtMs, boundPrintsLowercase: boundPrints)
        if contactChangePending && counted.contains(where: { $0.verified }) { return .changed }
        if boundUnverified { return .toVerify }
        return plainContactShield(counted, contactChangePending: contactChangePending)
    }

    /// The rule over exactly the given rows: `.pending` without rows, `.changed` when a change is recorded and a key is verified,
    /// `.verified` only when every row is verified, else `.toVerify`.
    static func plainContactShield(_ counted: [ContactShieldRow], contactChangePending: Bool) -> IdentityShield {
        if counted.isEmpty { return .pending }
        if contactChangePending && counted.contains(where: { $0.verified }) { return .changed }
        return counted.allSatisfy { $0.verified } ? .verified : .toVerify
    }

    /// Drops the leftovers of a reinstall: a row under its own device id that is never removed, and an old account-level pin that holds
    /// a key the contact no longer publishes. Given what the server CURRENTLY publishes (`published`), a row is dropped only when it is
    /// unverified, has no marker, is not bound, and either has a device id that is not published, or is the legacy row (no device id)
    /// whose fingerprint matches none of the published keys (when those could be computed).
    ///
    /// The set comes from the server, which end-to-end encryption does not trust: a server that leaves a device out must not turn the
    /// shield green while that device is in use. So a row is NEVER dropped once it has had accepted traffic at or after the contact's
    /// last verification. An unknown set (nil, or one without device ids) counts every row, and if dropping would leave nothing every
    /// row counts (toward purple, never green).
    public static func withoutStaleDevices(
        _ rows: [ContactShieldRow],
        published: PublishedDevices?,
        verifiedAtMs: Int64?,
        boundPrintsLowercase: Set<String> = []
    ) -> [ContactShieldRow] {
        guard let published, !published.deviceIds.isEmpty else { return rows }
        let ids = Set(published.deviceIds.map { $0.lowercased() })
        let prints = Set(published.fingerprints.map { $0.lowercased() })
        let kept = rows.filter { row in
            if boundPrintsLowercase.contains(row.fingerprintHex.lowercased()) { return true }
            return !isStaleDeviceRow(row, publishedIdsLowercase: ids, publishedPrintsLowercase: prints, verifiedAtMs: verifiedAtMs)
        }
        return kept.isEmpty ? rows : kept
    }

    /// True when `row` is an unverified, unmarked leftover, absent from the published set and without traffic since `verifiedAtMs`.
    public static func isStaleDeviceRow(
        _ row: ContactShieldRow,
        publishedIdsLowercase: Set<String>,
        publishedPrintsLowercase: Set<String>,
        verifiedAtMs: Int64?
    ) -> Bool {
        if row.verified || row.changePending { return false }
        if let traffic = row.lastTrafficAtMs {
            guard let verified = verifiedAtMs else { return false } // never verified: any traffic counts
            if traffic >= verified { return false }
        }
        if !row.deviceId.isEmpty { return !publishedIdsLowercase.contains(row.deviceId.lowercased()) }
        return !row.fingerprintHex.isEmpty && !publishedPrintsLowercase.isEmpty
            && !publishedPrintsLowercase.contains(row.fingerprintHex.lowercased())
    }
}

// MARK: - Rows from the stores

extension IdentityShieldRules {

    /// The rows of a contact from what the stores hold: one per pinned key. A row is verified when the stored verification applies to its
    /// key (`IdentityVerificationRecord.applies`), carries a marker when a change is recorded for exactly its fingerprint, and carries the
    /// latest accepted traffic recorded for its device or its key.
    public static func contactShieldRows(
        pins: [PeerIdentityPinStore.PinnedRow],
        record: IdentityVerificationRecord,
        selfUserId: String?,
        selfIdentityKey: Data?,
        peerUserId: String,
        pendingChangeFingerprints: [String],
        traffic: [String: Int64]
    ) -> [ContactShieldRow] {
        let pending = Set(pendingChangeFingerprints.map { $0.lowercased() })
        return pins.filter { $0.key.count == 32 }.map { pin -> ContactShieldRow in
            var fingerprint = ""
            if let me = selfUserId, let mine = selfIdentityKey,
               let fp = SasPinVerification.fingerprintHex(selfUserId: me, selfIdentityKey: mine, peerUserId: peerUserId, peerIdentityKey: pin.key) {
                fingerprint = fp.lowercased()
            }
            let verified = record.applies(to: pin.key, selfUserId: selfUserId, selfIdentityKey: selfIdentityKey, peerUserId: peerUserId)
            var lastTraffic: Int64?
            if !pin.deviceId.isEmpty, let t = traffic[ContactsStore.StoredContact.trafficKey(deviceId: pin.deviceId)] { lastTraffic = t }
            if !fingerprint.isEmpty, let t = traffic[ContactsStore.StoredContact.trafficKey(fingerprintHex: fingerprint)] {
                lastTraffic = max(lastTraffic ?? t, t)
            }
            return ContactShieldRow(
                deviceId: pin.deviceId, fingerprintHex: fingerprint, verified: verified,
                changePending: !fingerprint.isEmpty && pending.contains(fingerprint), lastTrafficAtMs: lastTraffic)
        }
    }
}

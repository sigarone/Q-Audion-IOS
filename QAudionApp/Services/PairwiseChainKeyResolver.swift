import Foundation
import CryptoKit
import QAudionEngine

/// Shared, fail-closed pairwise-PSK ladder + domain-separated chain-key
/// derivation.
///
/// FIX H1-PARITY (2026-07-30): `ChatAttachAnnounceSender` and
/// `ChatAttachAnnounceReceiver` each had their OWN copy-pasted
/// `deterministicChainKey` — one of which quietly derived its "key"
/// from the two public userIds alone (no real secret), the exact
/// vulnerability class `ChatMessageSendService` already fixed once
/// under the name FIX H1. Two independent copies of the same
/// resolution logic is exactly the failure mode this project keeps
/// tripping over (see the 17-copies-of-DisplayName.forUser sweep) —
/// this is the THIRD near-identical PSK-ladder implementation about to
/// be written (for `AvatarAnnounceSender`/`Receiver`), so it is factored
/// out once here instead of copy-pasted again.
///
/// `infoLabel` provides HKDF domain separation between features that
/// share the same underlying PSK (e.g. `"attach-chain-v1"` vs.
/// `"avatar-chain-v1"`) — every caller MUST use a distinct, stable
/// label so a key derived for one purpose can never double as a valid
/// key for another, even though both derive from the same PSK.
enum PairwiseChainKeyResolver {

    enum ResolveError: Error, LocalizedError, Equatable {
        /// No real pairwise PSK bound yet for this peer (checked both
        /// the ContactKeyExchange `auto:<prefix>:<peerId>` name and the
        /// legacy bare `peerId` name). Callers must trigger a key
        /// exchange and fail the operation — NEVER fall back to a
        /// derivation of the public userIds alone.
        case pskMissing

        var errorDescription: String? {
            switch self {
            case .pskMissing: return "Scambio chiavi in corso — riprova tra poco."
            }
        }
    }

    /// Candidate PSK names bound to `peerId`, newest-first.
    ///
    /// 1. `auto:<peerIdPrefix8>:<peerId>` — ContactKeyExchange-derived PSK.
    /// 2. Bare `peerId` — legacy / manually-bound.
    /// 3. `msg-psk:<peerId>` — the CALL-derived message PSK, peer-bound by
    ///    `AppState.persistMessagePsk`.
    ///
    /// W-AVATARPSK (2026-08-02). Entry 3 is the fix for the reason a call
    /// between two devices exchanged no avatar even after the trigger and
    /// cooldown work landed. Android's resolver is
    /// `SovereignKeyVault.findNewestForContact(contactId)`, and its call
    /// handshake (`PqcHandshake`, line ~1483) persists the call-derived
    /// message PSK with `contactId = peerContactId` — so on Android a
    /// COMPLETED CALL is by itself sufficient to have a pairwise PSK bound
    /// to that peer, which is exactly why call-only Android contacts
    /// exchange avatars. iOS derives the identical secret
    /// (`HKDF(sessionKey, salt: callId, info: "q-audion-msg-psk-v1")`, same
    /// bytes on both ends of the same call) but filed it ONLY under
    /// `call-<callIdPrefix8>` — keyed on the CALL, with no peer binding —
    /// so this resolver could never find it and every avatar attempt on a
    /// call-only relationship failed `.pskMissing`, silently, forever.
    ///
    /// Ordering mirrors Android's `maxWithOrNull(compareBy { ratchetVersion
    /// }.thenBy { createdAt })` as closely as the iOS vault allows: it has
    /// no per-entry ratchetVersion, so recency alone decides, with the
    /// list order above as a deterministic tie-break when the Keychain
    /// reports no creation date. Converging on "newest wins" is what makes
    /// the two platforms pick the SAME key: right after a call both sides
    /// have just written the same call-derived PSK, so it is the newest
    /// entry on both.
    private static func candidatesNewestFirst(peerId: String, vault: SovereignKeyVault) -> [String] {
        let prefix = peerId.count > 8 ? String(peerId.prefix(8)) : peerId
        let ranked: [String] = ["auto:\(prefix):\(peerId)", peerId, "msg-psk:\(peerId)"]
        var dates: [String: Date] = [:]
        for entry in vault.listPskEntries() {
            if let created = entry.createdAt { dates[entry.name] = created }
        }
        var rows: [(name: String, rank: Int, date: Date?)] = []
        for (i, name) in ranked.enumerated() {
            rows.append((name: name, rank: i, date: dates[name]))
        }
        rows.sort { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (l?, r?):
                if l != r { return l > r }
                return lhs.rank < rhs.rank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.rank < rhs.rank
            }
        }
        return rows.map { $0.name }
    }

    /// Resolves the newest PSK genuinely bound to `peerId`. Throws
    /// `.pskMissing` — never a guessable fallback — when none is bound.
    static func resolvePsk(peerId: String, vault: SovereignKeyVault) throws -> Data {
        for name in candidatesNewestFirst(peerId: peerId, vault: vault) {
            if let stored = try vault.loadPsk(name: name), !stored.isEmpty {
                return stored
            }
        }
        throw ResolveError.pskMissing
    }

    /// Every PSK bound to `peerId`, newest first, de-duplicated by value.
    ///
    /// W-MSGPSKPICK (2026-08-02) — the 1:1 message path needs the whole list,
    /// not just the winner. Android re-binds a call-derived PSK to the
    /// contact after every call and decrypts with
    /// `findNewestForContact`, while iOS used a fixed
    /// `auto:` → bare ladder on both send and receive. After any call the
    /// two picked DIFFERENT keys and every iOS→Android message failed with
    /// "MessageCrypto.decrypt returned null — invalid key/payload"; the
    /// avatar envelope rides inside those messages, which is why the
    /// announce never reached Android's handler even though iOS sent it.
    ///
    /// Ordering by recency makes the two platforms agree on the common case.
    /// Handing the caller the full list makes the receive side tolerant of a
    /// peer that still picks differently — trying the remaining candidates
    /// costs one AEAD open each and can only turn a hard failure into a
    /// success, never the reverse.
    static func orderedPskCandidates(peerId: String, vault: SovereignKeyVault) -> [Data] {
        var out: [Data] = []
        for name in candidatesNewestFirst(peerId: peerId, vault: vault) {
            guard let stored = (try? vault.loadPsk(name: name)) ?? nil, !stored.isEmpty else { continue }
            if !out.contains(stored) { out.append(stored) }
        }
        return out
    }

    /// Resolves the real pairwise PSK (throws `.pskMissing` if none
    /// bound) and derives a 32-byte chain key via
    /// `HKDF-SHA256(psk, salt: "qaudion-attach-salt-v1", info: "<infoLabel>:<sortedPair>")`.
    /// `selfId`/`peerId` order doesn't matter — the sorted-pair tuple
    /// makes both ends derive the same bytes.
    static func deriveChainKey(
        selfId: String, peerId: String, infoLabel: String, vault: SovereignKeyVault
    ) throws -> Data {
        let psk = try resolvePsk(peerId: peerId, vault: vault)
        return deriveChainKey(psk: psk, selfId: selfId, peerId: peerId, infoLabel: infoLabel)
    }

    /// Same derivation as above, from an ALREADY-RESOLVED PSK — for callers
    /// that must try more than one candidate on receive (see
    /// `orderedPskCandidates`'s kdoc: a call rebinds a fresh call-derived
    /// PSK per contact, so "newest" can disagree between sender and
    /// receiver by a few seconds around a call). A sender never needs this
    /// overload — it always encrypts under its own single newest PSK, no
    /// ambiguity — so `deriveChainKey(selfId:peerId:infoLabel:vault:)`
    /// above stays the right call for every send-side site.
    static func deriveChainKey(
        psk: Data, selfId: String, peerId: String, infoLabel: String
    ) -> Data {
        let pair = [selfId, peerId].sorted().joined(separator: ":")
        let info = Data("\(infoLabel):\(pair)".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: psk),
            salt: Data("qaudion-attach-salt-v1".utf8),
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

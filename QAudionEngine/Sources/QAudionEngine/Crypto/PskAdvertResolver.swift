import Foundation

/// PskAdvertResolver — read a peer's PSK advertisement in EITHER dialect
/// (WIRE_SPEC §3.3 static, §3.3.1 blinded) and translate the result back into the
/// local static-fingerprint vocabulary every downstream consumer already speaks.
///
/// Mirrored in Android `PskAdvertResolver.kt` and Desktop `PskAdvertResolver.ts`.
///
/// ## Why a resolver instead of a flag
///
/// The v3 rollout needs no capability bit and no negotiation, because the
/// advertisement describes its own dialect: a receiver tries v3 first, then
/// static, and whichever produced the match IS the dialect the peer speaks. The
/// two attempts cannot conflict — a 32-byte HMAC tag equals `SHA-256(psk)` only
/// with negligible probability — so trying static after v3 only widens what can be
/// matched and never yields a wrong match.
///
/// That buys three things a capability bit would not:
///
/// * The ACCEPT leg has no mixed window. The responder mirrors the dialect it
///   detected, so it is always speaking whatever the initiator speaks.
/// * There is no field for a relay to strip in order to force the static
///   (correlatable) dialect back onto the wire. Downgrading would mean rewriting
///   the initiator's advertisement, which the §3.2 signature covers — and a relay
///   cannot produce static fingerprints anyway, not holding the keys.
/// * The signed capability set (`caps7`) does not have to grow, so no lockstep
///   transcript change across three platforms.
///
/// ## Why the translation matters more than the matching
///
/// Under v3 the wire values are per-call tags. Several consumers downstream of
/// selection treat the advertised strings as durable identities:
///
/// * the §D4 hw_only gate intersects the peer's advertised set with our held
///   hw_only fingerprints — handed raw tags it would intersect to EMPTY and
///   quietly stop enforcing a requirement;
/// * the "NFC in comune" signal answers "do we share an NFC-origin secret", which
///   under v3 cannot come from the wire role array (omitted) and must come from
///   which preimage reproduced the tag;
/// * `kc_mac`'s `mixedFingerprints` and the session-KDF's `selected_fp` must be
///   byte-equal on both legs, and only the static fingerprint is.
///
/// So `resolve` returns the static fingerprint of the selected secret AND the full
/// translated mutual set, and the call site hands those on. `wireValue` is kept
/// separately for the one thing that genuinely is a wire value: the
/// `selectedPskFingerprint` echo, which must go back verbatim.
///
/// Pure — no Keychain access; candidates are passed in — so the selection rule is
/// testable without a real `SovereignKeyVault`.
public enum PskAdvertResolver {

    public enum Dialect: Equatable {
        /// §3.3.1 per-call HMAC tags.
        case v3Blinded

        /// §3.3 `lc_hex(SHA-256(psk))`.
        case v2Static

        /// Nothing matched. NOT an error: the overwhelmingly common cause is that
        /// the two sides share no secret at all. A responder mirroring this falls
        /// back to static, which loses nothing — with no shared secret there is no
        /// PSK to protect.
        case unknown
    }

    /// One locally-held eligible secret.
    public struct Candidate: Equatable {
        public let staticFp: String
        public let psk: Data
        /// The role THIS device recorded it under — used only when WE advertise. The
        /// peer's own role is recovered from its tag, never assumed to equal ours.
        public let localRole: Int

        public init(staticFp: String, psk: Data, localRole: Int) {
            self.staticFp = staticFp
            self.psk = psk
            self.localRole = localRole
        }
    }

    public struct Resolution: Equatable {
        /// Which dialect produced the match; a responder MUST mirror it.
        public let dialect: Dialect
        /// The RECEIVED element to echo verbatim in `selectedPskFingerprint`.
        public let wireValue: String?
        /// Local static fingerprint of the selected secret — the value for `kc_mac`'s
        /// `mixedFingerprints`, the session-KDF `selected_fp`, the §D4 intersect, the UI.
        public let staticFp: String?
        /// The selected secret's material.
        public let psk: Data?
        /// The role the PEER recorded the selected secret under: under v3 recovered
        /// from its tag, under static read from the wire role array.
        public let peerRole: Int?
        /// Every secret we share with the peer as `(staticFp, peerRole)`, in the
        /// peer's advertised order. The translated replacement for "intersect the
        /// peer's advertised list with ours".
        public let mutual: [(String, Int)]

        /// Static fingerprints we share with the peer — the §D4 intersect input.
        public var mutualStaticFps: Set<String> { Set(mutual.map { $0.0 }) }

        /// Roles the peer recorded for secrets we ALSO hold — `1` means NFC.
        public var mutualPeerRoles: Set<Int> { Set(mutual.map { $0.1 }) }

        static let none = Resolution(
            dialect: .unknown, wireValue: nil, staticFp: nil, psk: nil, peerRole: nil, mutual: []
        )

        public static func == (a: Resolution, b: Resolution) -> Bool {
            a.dialect == b.dialect && a.wireValue == b.wireValue && a.staticFp == b.staticFp
                && a.psk == b.psk && a.peerRole == b.peerRole
                && a.mutual.count == b.mutual.count
                && zip(a.mutual, b.mutual).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    /// Resolve a received advertisement.
    ///
    /// - Parameters:
    ///   - receivedAdvert: the peer's `pskFingerprints`, verbatim and in wire order.
    ///   - receivedRoles: the peer's `pskRoles`; absent/short entries read as 0, the
    ///     same "absent means ordinary" convention the wire codec and `advEnc` use.
    ///     Ignored under v3, where the role lives in the tag.
    ///   - senderEphemeralX25519Pub: the SENDER's ephemeral X25519 public key — OFFER
    ///     `x25519PublicKey`, ACCEPT `ciphertext.x25519`. Nil (or wrong width) skips
    ///     the v3 attempt entirely and goes straight to static, which is what a
    ///     legacy/unsigned path wants.
    ///   - candidates: locally-held eligible secrets IN LOCAL PRIORITY ORDER.
    ///
    /// SELECTION IS FIRST-MATCH IN THE PEER'S ADVERTISED ORDER, in both dialects. The
    /// advertiser ranks its list by priority and the receiver is required to honour
    /// that ranking; scanning our own list first would move the priority to the
    /// receiver, which is the defect the v1 `?.sorted()` had.
    public static func resolve(
        receivedAdvert: [String]?,
        receivedRoles: [Int]?,
        callId: String,
        senderEphemeralX25519Pub: Data?,
        candidates: [Candidate]
    ) -> Resolution {
        // Deliberately NOT filtered. `pskRoles` is a PARALLEL array indexed by
        // advertised position, so dropping malformed entries here would shift every
        // subsequent role by one and silently mislabel an NFC secret as ordinary.
        // Malformed entries are already harmless: they match no tag and no
        // fingerprint, so they fall through as misses on their own.
        guard let advert = receivedAdvert, !advert.isEmpty, !candidates.isEmpty else {
            return .none
        }

        // ── v3 first ──
        if let pub = senderEphemeralX25519Pub, pub.count == PskAdvertV3.x25519PubBytes,
           let nonce = PskAdvertV3.deriveNonce(callId: callId, senderEphemeralX25519Pub: pub) {
            // matchAll, not match: the mutual set feeds the §D4 gate and the
            // NFC-in-common signal, and stopping at the first hit would silently
            // under-report a shared secret to both.
            let hits = PskAdvertV3.matchAll(
                receivedTagsHex: advert,
                callId: callId,
                senderNonce: nonce,
                localPsks: candidates.map { $0.psk }
            )
            if let first = hits.first {
                return Resolution(
                    dialect: .v3Blinded,
                    wireValue: advert[first.receivedIndex],
                    staticFp: candidates[first.localIndex].staticFp,
                    psk: candidates[first.localIndex].psk,
                    peerRole: first.role,
                    mutual: hits.map { (candidates[$0.localIndex].staticFp, $0.role) }
                )
            }
        }

        // ── §3.3 static fallback ──
        var byFp: [String: Candidate] = [:]
        for c in candidates where byFp[c.staticFp] == nil { byFp[c.staticFp] = c }
        var mutual: [(String, Int)] = []
        var firstIdx = -1
        for (i, wire) in advert.enumerated() {
            guard let c = byFp[wire] else { continue }
            mutual.append((c.staticFp, roleAt(receivedRoles, i)))
            if firstIdx < 0 { firstIdx = i }
        }
        guard firstIdx >= 0, let chosen = byFp[advert[firstIdx]] else { return .none }
        return Resolution(
            dialect: .v2Static,
            wireValue: advert[firstIdx],
            staticFp: chosen.staticFp,
            psk: chosen.psk,
            peerRole: roleAt(receivedRoles, firstIdx),
            mutual: mutual
        )
    }

    /// Build OUR advertisement in `dialect` — the responder mirroring what it
    /// detected, or an initiator emitting its build's default.
    ///
    /// Returns the `pskFingerprints` list plus the `pskRoles` list to send alongside:
    /// under v3 that is nil, because the roles are inside the tags.
    ///
    /// - Parameter ownEphemeralX25519Pub: OUR ephemeral X25519 public key for this
    ///   leg. Nil (or wrong width) under `.v3Blinded` degrades to static rather than
    ///   emitting an advertisement no peer could match.
    public static func buildAdvertisement(
        dialect: Dialect,
        callId: String,
        ownEphemeralX25519Pub: Data?,
        candidates: [Candidate]
    ) -> (fingerprints: [String], roles: [Int]?) {
        if dialect == .v3Blinded, let pub = ownEphemeralX25519Pub,
           pub.count == PskAdvertV3.x25519PubBytes,
           let tags = PskAdvertV3.buildAdvertisement(
               callId: callId,
               ownEphemeralX25519Pub: pub,
               orderedEntries: candidates.map {
                   PskAdvertV3.Entry(psk: $0.psk, role: $0.localRole)
               }
           ) {
            return (tags, nil)
        }
        // .unknown mirrors as static: nothing is lost, because .unknown means we found
        // no shared secret, so there is no PSK for the static form to expose. A nil
        // ephemeral under .v3Blinded lands here too — better static than an
        // advertisement nobody can match, which would read as "we hold no keys".
        return (candidates.map { $0.staticFp }, candidates.map { $0.localRole })
    }

    private static func roleAt(_ roles: [Int]?, _ i: Int) -> Int {
        guard let roles, i >= 0, i < roles.count else { return 0 }
        return roles[i]
    }
}

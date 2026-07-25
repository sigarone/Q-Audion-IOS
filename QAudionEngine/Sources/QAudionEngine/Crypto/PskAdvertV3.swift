import Foundation
import CryptoKit

/// PskAdvertV3 — the blinded PSK advertisement (WIRE_SPEC §3.3.1).
///
/// Byte-exact contract, mirrored in Android `PskAdvertV3.kt` and Desktop
/// `PskAdvertV3.ts`, pinned by `tools/kat/psk-advert-v3/psk-advert-v3-kat.json`.
/// Edit the generator (`bcrypto-server/tools/kat/gen_psk_advert_v3_kat.py`),
/// never the JSON — it writes all six copies in one run so they cannot drift.
///
/// ## What this replaces, and why
///
/// The v1/v2 wire advertised `pskFingerprints[j] = lc_hex(SHA-256(psk_j))` plus a
/// parallel `pskRoles[j]` marking which entries came from an NFC tap. Two leaks,
/// both to the relay and to anyone passively logging signalling:
///
/// 1. `SHA-256(psk)` is a CONSTANT. The same two devices advertised the same hex
///    string on every call for the life of the key — a permanent
///    per-relationship correlator. Anyone with the signalling log could partition
///    the user base into "who shares a secret with whom" without touching a key.
/// 2. `pskRoles` said which of those secrets came from an NFC tap, i.e. which
///    pairs of users had physically met. That is exactly the metadata this
///    product exists not to produce.
///
/// v3 sends, for each eligible secret, a per-call HMAC tag instead:
///
///     tag = HMAC-SHA256( key = psk, msg = preimage )[0..<32]
///
///     preimage = "qa-psk-advert-v3"        16 B ASCII
///             || u8(len(callId_utf8)) || callId_utf8
///             || nonce_sender             32 B
///             || u8(role)                  1 B
///
/// and sends `pskRoles` as nil. A relay sees 32 fresh bytes per key per call and
/// can neither link two calls by the same pair nor tell an NFC secret from a KMS
/// one.
///
/// ## The nonce is DERIVED, never sent
///
///     nonce_sender = SHA-256( "qa-psk-advert-nonce-v3"     22 B ASCII
///                           || u8(len(callId_utf8)) || callId_utf8
///                           || sender_ephemeral_x25519_pub )   32 B, fixed, last
///
/// `sender_ephemeral_x25519_pub` is the SENDER's own ephemeral X25519 public key
/// as it appears in the SIGNED bundle: the OFFER's `x25519PublicKey`, and on the
/// ACCEPT leg `ciphertext.x25519`. Both are already bound by the v2 transcript
/// (`HandshakeTranscript.offerV2` binds `lp(x25519PublicKey)`, `acceptV2` binds
/// `lp(ctX25519)`).
///
/// That is the whole reason the nonce is not a new wire field. An unauthenticated
/// nonce would be a silent PSK-downgrade oracle: a relay flips one byte, the
/// receiver derives different candidate tags, nothing matches, the PSK quietly
/// drops out of the session key, and both users still see a connected call with
/// no warning. Deriving it from a value the existing signature already covers
/// means tampering invalidates the signature instead — and it costs zero new wire
/// bytes and zero transcript change, so the three platforms never have to
/// re-agree on a transcript layout. Freshness is free: the ephemeral is per call.
///
/// ## The role is recovered by brute force, not read off the wire
///
/// The sender folds its own role byte into the preimage. The receiver computes
/// each local key's tag under EVERY role value `0...255` and looks each up among
/// the received tags; whichever value matches IS the sender's recorded role,
/// recovered exactly without it ever being on the wire.
///
/// The full byte range rather than just the three defined roles, for two reasons:
///
/// * A role disagreement must not cost the PSK. If the two sides recorded the
///   same material under different origins (obtained by different routes, or a
///   future build renumbers), matching only the local role would find nothing and
///   the PSK would silently drop — the same class of silent failure as an
///   unauthenticated nonce.
/// * A role added later interoperates with an older build automatically, with no
///   lockstep release.
///
/// The cost is nothing: `roleSearchSpace * m` HMAC-SHA256 for m local keys,
/// milliseconds for the single-digit m this vault holds. The tag's secrecy rests
/// on the psk, not on the role, so a 256-wide search over the role is intended
/// behaviour rather than a weakness.
///
/// ## advEnc is unchanged
///
/// `advEnc(list) = u8(m) || (u8(role) || 32B)*m`. A 32-byte tag occupies the slot
/// the 32-byte fingerprint had, and `pskRoles = nil` already encodes as all-zero
/// role bytes, so the existing signature covers the advertisement byte-for-byte
/// with no format change on any platform.
///
/// ## The static fingerprint does NOT go away
///
/// `lc_hex(SHA-256(psk))` — `PskAdvertising.canonicalFingerprint(forPsk:)` — stays
/// the LOCAL identifier everywhere off the wire: vault names, `kc_mac`'s
/// `mixedFingerprints`, `PskMix.mixId`, the UI, the hw_only §D4 intersect. Only
/// the wire changes. A receiver MUST translate a matched tag back to its own
/// static fingerprint before handing it to any of those, or they silently see a
/// value they have never heard of — which for the §D4 hw_only gate would mean an
/// empty intersect and a requirement quietly not enforced.
///
/// ## Honest limits
///
/// v3 does not hide HOW MANY secrets a pair shares (the list length is still
/// visible — pad to a fixed length if that ever matters), and it does not stop a
/// peer who already holds key X from testing whether you also hold X. The second
/// is inherent to any matchable advertisement: the knowledge gained is nil, since
/// they already have the key, but the capability remains. It also does nothing
/// about the server knowing who calls whom; that is a different layer.
public enum PskAdvertV3 {

    public static let pskBytes = 32
    public static let tagBytes = 32
    public static let nonceBytes = 32
    public static let x25519PubBytes = 32

    /// Role values the receiver walks when recovering the sender's role.
    public static let roleSearchSpace = 256

    public static let roleOrdinary = 0
    public static let roleNfc = 1
    public static let roleQr = 2

    /// ASCII "qa-psk-advert-v3" — exactly 16 bytes, so the preimage needs no separator.
    private static let domainTag = Data("qa-psk-advert-v3".utf8)

    /// ASCII "qa-psk-advert-nonce-v3" — exactly 22 bytes.
    private static let domainNonce = Data("qa-psk-advert-nonce-v3".utf8)

    /// One local secret and the role THIS device recorded it under.
    public struct Entry: Equatable {
        public let psk: Data
        public let role: Int

        public init(psk: Data, role: Int) {
            self.psk = psk
            self.role = role
        }
    }

    /// A successful match.
    ///
    /// - `receivedIndex`: index into the peer's advertised tag list — the peer's
    ///   own priority position, which is what the responder must echo back.
    /// - `localIndex`: index into the local candidate list the caller passed, so
    ///   the caller can recover the secret and its static fingerprint.
    /// - `role`: the role the PEER recorded this secret under, recovered from
    ///   which preimage reproduced the tag. This is the value that used to arrive
    ///   in `pskRoles[j]`.
    public struct Match: Equatable {
        public let receivedIndex: Int
        public let localIndex: Int
        public let role: Int

        public init(receivedIndex: Int, localIndex: Int, role: Int) {
            self.receivedIndex = receivedIndex
            self.localIndex = localIndex
            self.role = role
        }
    }

    /// One-byte length prefix. Returns nil rather than truncating — a callId over
    /// 255 UTF-8 bytes is a bug to surface, not to mangle into a collision.
    private static func lp8(_ b: Data) -> Data? {
        guard b.count <= 0xFF else { return nil }
        return Data([UInt8(b.count)]) + b
    }

    /// `nonce_sender = SHA-256(domainNonce || u8(len(callId)) || callId || senderEphemeralPub)`.
    ///
    /// Pass the SENDER's ephemeral X25519 public key — the one that appears in the
    /// bundle whose advertisement you are building or matching. On the OFFER leg
    /// that is `x25519PublicKey`; on the ACCEPT leg it is `ciphertext.x25519`.
    /// Using the wrong side's key is the mistake that makes two v3 peers silently
    /// fail to find a secret they both hold, so it is a required explicit argument
    /// rather than something inferred here.
    ///
    /// Returns nil on a malformed input instead of trapping: this runs on wire
    /// data, and a relay must not be able to crash a client by corrupting a field.
    public static func deriveNonce(callId: String, senderEphemeralX25519Pub: Data) -> Data? {
        guard senderEphemeralX25519Pub.count == x25519PubBytes,
              let lp = lp8(Data(callId.utf8)) else { return nil }
        var h = SHA256()
        h.update(data: domainNonce)
        h.update(data: lp)
        h.update(data: senderEphemeralX25519Pub)
        return Data(h.finalize())
    }

    /// `tag = HMAC-SHA256(psk, domainTag || u8(len(callId)) || callId || nonce || u8(role))`.
    public static func tag(psk: Data, callId: String, nonce: Data, role: Int) -> Data? {
        guard psk.count == pskBytes, nonce.count == nonceBytes,
              (0...0xFF).contains(role),
              let lp = lp8(Data(callId.utf8)) else { return nil }
        var msg = Data()
        msg.reserveCapacity(domainTag.count + lp.count + nonce.count + 1)
        msg.append(domainTag)
        msg.append(lp)
        msg.append(nonce)
        msg.append(UInt8(role))
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: psk))
        // HMAC-SHA256 is already 32 bytes; the prefix keeps `tagBytes` the single
        // source of truth if the width is ever revisited.
        return Data(mac).prefix(tagBytes)
    }

    /// The wire value for `pskFingerprints`: one 64-lowercase-hex tag per entry,
    /// IN THE ORDER GIVEN.
    ///
    /// Order is priority and the peer is required to honour it, so the caller must
    /// pass entries already in its advertise order — this never re-sorts. Send
    /// `pskRoles = nil` alongside; the roles are inside the tags.
    ///
    /// Returns nil if any entry is malformed, so a partially-built advertisement
    /// (which would look like "we hold fewer keys than we do") can never ship.
    public static func buildAdvertisement(
        callId: String,
        ownEphemeralX25519Pub: Data,
        orderedEntries: [Entry]
    ) -> [String]? {
        guard let nonce = deriveNonce(callId: callId, senderEphemeralX25519Pub: ownEphemeralX25519Pub)
        else { return nil }
        var out: [String] = []
        out.reserveCapacity(orderedEntries.count)
        for e in orderedEntries {
            guard let t = tag(psk: e.psk, callId: callId, nonce: nonce, role: e.role) else { return nil }
            out.append(hex(t))
        }
        return out
    }

    /// Find the first peer-advertised tag any local secret reproduces.
    ///
    /// - Parameters:
    ///   - receivedTagsHex: the peer's `pskFingerprints`, verbatim and in wire order.
    ///   - senderNonce: from `deriveNonce` over the PEER's ephemeral key.
    ///   - localPsks: candidate secrets in the caller's own order; only used to
    ///     report `Match.localIndex` back.
    ///
    /// RECEIVED ORDER IS THE OUTER LOOP, and that is load-bearing rather than
    /// stylistic: the advertiser orders its list by priority and the responder is
    /// required to pick the first entry it also holds, so iterating local secrets
    /// first would silently move the priority to the receiver — the exact defect
    /// the v1 `?.sorted()` had.
    ///
    /// Candidates are precomputed once (`roleSearchSpace * localPsks.count` HMACs)
    /// and then scanned with a constant-time compare, so a candidate's own bytes
    /// never steer the timing. The outer walk does stop at the first received tag
    /// that matched; that reveals only WHICH advertised position won, which the
    /// peer is about to be told explicitly in `selectedPskFingerprint` anyway.
    public static func match(
        receivedTagsHex: [String],
        callId: String,
        senderNonce: Data,
        localPsks: [Data]
    ) -> Match? {
        guard !receivedTagsHex.isEmpty, !localPsks.isEmpty else { return nil }

        var candidateTags: [Data] = []
        var candidateLocalIndex: [Int] = []
        var candidateRole: [Int] = []
        candidateTags.reserveCapacity(localPsks.count * roleSearchSpace)
        for (li, psk) in localPsks.enumerated() {
            for role in 0..<roleSearchSpace {
                guard let t = tag(psk: psk, callId: callId, nonce: senderNonce, role: role) else { continue }
                candidateTags.append(t)
                candidateLocalIndex.append(li)
                candidateRole.append(role)
            }
        }
        guard !candidateTags.isEmpty else { return nil }

        for (ri, hexTag) in receivedTagsHex.enumerated() {
            // A malformed entry from the peer is a miss, never a throw: a relay must
            // not be able to abort a handshake by corrupting one list element.
            guard let received = hexOrNil(hexTag), received.count == tagBytes else { continue }
            var hit = -1
            for i in 0..<candidateTags.count {
                // No early exit inside this scan — record and keep going.
                if constantTimeEqual(candidateTags[i], received), hit < 0 { hit = i }
            }
            if hit >= 0 {
                return Match(receivedIndex: ri, localIndex: candidateLocalIndex[hit], role: candidateRole[hit])
            }
        }
        return nil
    }

    /// `match` with the nonce derived for you from the peer's ephemeral key. The
    /// convenience most call sites want, since forgetting whose ephemeral key to
    /// use is the one way to get a silent no-match.
    public static func matchAgainstPeer(
        receivedTagsHex: [String],
        callId: String,
        peerEphemeralX25519Pub: Data,
        localPsks: [Data]
    ) -> Match? {
        guard let nonce = deriveNonce(callId: callId, senderEphemeralX25519Pub: peerEphemeralX25519Pub)
        else { return nil }
        return match(receivedTagsHex: receivedTagsHex, callId: callId, senderNonce: nonce, localPsks: localPsks)
    }

    /// `lc_hex(SHA-256(psk))` — the STATIC fingerprint, unchanged from v1/v2 and
    /// still the local identifier off the wire. Delegates to
    /// `PskAdvertising.canonicalFingerprint(forPsk:)` rather than recomputing, so
    /// there is exactly one definition of that value on this platform.
    public static func staticFingerprintHex(psk: Data) -> String {
        PskAdvertising.canonicalFingerprint(forPsk: psk)
    }

    // MARK: - Helpers

    /// Length-independent only after the count check; both inputs here are the
    /// same fixed width by construction.
    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    private static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// Lenient hex decode: nil on anything malformed, so a bad peer value is a miss.
    private static func hexOrNil(_ s: String) -> Data? {
        let chars = Array(s)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue,
                  hi < 16, lo < 16 else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }
}

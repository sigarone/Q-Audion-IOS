import Foundation

/// The signed promotion token of a 1:1 call that is promoted to a group call
/// (GROUP_CALLS_V2 2.7, docs/GROUP_CALLS_V2_SPEC.md item 28).
///
/// The creator signs it with the identity key that signed its handshake bundle of the live 1:1 call
/// and sends it to the 1:1 peer as an `opaque_message` before it creates the group:
///
///     <callId>|GRPPROMO:<base64(TOKEN)>
///
/// The peer joins the group without a ring only when it holds a valid token from its current,
/// verified 1:1 peer. Everything here is a pure function of its arguments: the builder (creator),
/// the strict parser and verifier (receiver, steps R6 to R10 of the spec), and the freshness test.
/// The state around it (the anchor of the live 1:1, the book of received tokens, the decision) is in
/// `GroupPromotionBook.swift` and `GroupPromotionDecision.swift`. The vectors are pinned by
/// `GroupPromotionTokenTests` against `Resources/kat/promotion-token-kat.json`.
public enum GroupPromotionToken {

    // MARK: - Constants (GROUP_CALLS_V2 2.7, Promotion token)

    /// `PROMO_DOMAIN`: ASCII, 26 bytes, not length-prefixed.
    public static let domain = Data("qaudion-group-promotion-v1".utf8)
    /// `PROMO_VERSION`.
    public static let version: UInt8 = 0x01
    /// `PROMO_CALL_AUDIO`: the only valid call type.
    public static let callTypeAudio: UInt8 = 0x01
    /// What a sender writes as the token's lifetime.
    public static let senderLifetimeMs: UInt32 = 60_000
    /// The smallest and the largest lifetime a verifier accepts, inclusive.
    public static let minLifetimeMs: UInt32 = 1_000
    public static let maxLifetimeMs: UInt32 = 60_000
    /// `PROMO_SKEW_MS`: the tolerance between the two devices' wall clocks.
    public static let skewMs: Int64 = 15_000
    /// `PROMO_INVITE_WAIT_MS`: how long a promotion candidate is held, without a ring, for its token.
    public static let inviteWaitMs: Int64 = 3_000
    /// `PROMO_MAX_INVITEES`: the server's 64 participants minus the creator.
    public static let maxInvitees = 63
    /// `PROMO_MAX_DATA`: characters of the whole opaque `data`.
    public static let maxDataLength = 4_096
    /// `PROMO_MAX_HELD`: tokens held per live 1:1 call.
    public static let maxHeld = 4
    /// `PROMO_TAG`, case-sensitive ASCII.
    public static let tag = "GRPPROMO:"
    public static let signatureLength = 64
    public static let bindingLength = 32
    public static let keyLength = 32

    // MARK: - Fields

    /// The signed fields of a token.
    public struct Fields: Equatable, Sendable {
        /// Canonical ids (`GroupCallIds.isCanonical`).
        public let groupCallId: String
        public let fromCallId: String
        public let acceptBinding1: Data
        public let creatorUserId: String
        public let signerKey: Data
        public let callType: UInt8
        public let issuedAtMs: UInt64
        public let lifetimeMs: UInt32
        /// Canonical ids, strictly ascending as byte strings, the creator not among them.
        public let invitees: [String]

        public init(groupCallId: String, fromCallId: String, acceptBinding1: Data, creatorUserId: String,
                    signerKey: Data, callType: UInt8, issuedAtMs: UInt64, lifetimeMs: UInt32, invitees: [String]) {
            self.groupCallId = groupCallId
            self.fromCallId = fromCallId
            self.acceptBinding1 = acceptBinding1
            self.creatorUserId = creatorUserId
            self.signerKey = signerKey
            self.callType = callType
            self.issuedAtMs = issuedAtMs
            self.lifetimeMs = lifetimeMs
            self.invitees = invitees
        }
    }

    /// A parsed token: its fields, the bytes that were signed and the signature.
    public struct Parsed: Equatable, Sendable {
        public let fields: Fields
        public let tbs: Data
        public let signature: Data
        public let token: Data
    }

    // MARK: - Drop codes (docs/GROUP_CALLS_V2_SPEC.md item 32)

    /// Why a received token is dropped. Every drop is silent: no reply, no hang-up, no change to the
    /// 1:1 call. The number is what the phone log carries (`GroupDiagnostics.promoReceivedLine`).
    public enum Drop: Int, Error, Equatable, Sendable {
        case tooLong = 1
        case noCall = 2
        case notPeer = 3
        case noAnchor = 4
        case malformed = 5
        case badVersion = 6
        case signerDiff = 7
        case badSig = 8
        case fromDiff = 9
        case bindDiff = 10
        case creatorDiff = 11
        case notInvited = 12
        case future = 13
        case stale = 14
        case dupGroup = 15

        /// The code of the spec.
        public var name: String {
            switch self {
            case .tooLong: return "too_long"
            case .noCall: return "no_call"
            case .notPeer: return "not_peer"
            case .noAnchor: return "no_anchor"
            case .malformed: return "malformed"
            case .badVersion: return "bad_version"
            case .signerDiff: return "signer_diff"
            case .badSig: return "bad_sig"
            case .fromDiff: return "from_diff"
            case .bindDiff: return "bind_diff"
            case .creatorDiff: return "creator_diff"
            case .notInvited: return "not_invited"
            case .future: return "future"
            case .stale: return "stale"
            case .dupGroup: return "dup_group"
            }
        }

        public init?(name: String) {
            let all: [Drop] = [.tooLong, .noCall, .notPeer, .noAnchor, .malformed, .badVersion, .signerDiff, .badSig,
                               .fromDiff, .bindDiff, .creatorDiff, .notInvited, .future, .stale, .dupGroup]
            guard let found = all.first(where: { $0.name == name }) else { return nil }
            self = found
        }
    }

    // MARK: - Builder (creator, GROUP_CALLS_V2 2.7, Promotion token)

    public enum BuildError: Error, Equatable, Sendable {
        case invalidId
        case invalidInvitees
        case invalidBinding
        case invalidSignerKey
        case invalidLifetime
        case invalidCallType
        case signFailed
    }

    /// A token ready to send.
    public struct Built: Equatable, Sendable {
        public let fields: Fields
        public let tbs: Data
        public let token: Data
        /// `base64(TOKEN)`, canonical.
        public let encoded: String

        /// The `opaque_message.data` for the 1:1 call `callId` (as that call's transcript spells it).
        public func wireData(callId: String) -> String {
            return GroupPromotionToken.wireData(callId: callId, encoded: encoded)
        }
    }

    /// Builds and signs a token.
    ///
    /// Every id is mapped to canonical form and must be a UUID after that. `invitees` are the
    /// recipients of the `group_call_create` that follows, as they will be sent: no duplicate after case
    /// folding, the creator not among them, the 1:1 peer among them, 1 to 63 of them; they are sorted
    /// here. `sign` signs `PROMO_TBS` with the identity key whose public half is `signerKey`.
    public static func build(
        groupCallId: String,
        fromCallId: String,
        acceptBinding1: Data,
        creatorUserId: String,
        signerKey: Data,
        peerUserId: String,
        invitees: [String],
        issuedAtMs: UInt64,
        lifetimeMs: UInt32 = GroupPromotionToken.senderLifetimeMs,
        callType: UInt8 = GroupPromotionToken.callTypeAudio,
        sign: (Data) -> Data?
    ) throws -> Built {
        guard let group = GroupCallIds.canonical(groupCallId),
              let from = GroupCallIds.canonical(fromCallId),
              let creator = GroupCallIds.canonical(creatorUserId),
              let peer = GroupCallIds.canonical(peerUserId) else { throw BuildError.invalidId }
        guard acceptBinding1.count == bindingLength else { throw BuildError.invalidBinding }
        guard signerKey.count == keyLength else { throw BuildError.invalidSignerKey }
        guard lifetimeMs >= minLifetimeMs, lifetimeMs <= maxLifetimeMs else { throw BuildError.invalidLifetime }
        guard callType == callTypeAudio else { throw BuildError.invalidCallType }
        guard !invitees.isEmpty, invitees.count <= maxInvitees else { throw BuildError.invalidInvitees }
        var canonicalInvitees: [String] = []
        for invitee in invitees {
            guard let id = GroupCallIds.canonical(invitee) else { throw BuildError.invalidId }
            canonicalInvitees.append(id)
        }
        let sorted = canonicalInvitees.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for index in 1..<max(sorted.count, 1) where sorted[index] == sorted[index - 1] {
            throw BuildError.invalidInvitees
        }
        guard !sorted.contains(creator), sorted.contains(peer) else { throw BuildError.invalidInvitees }
        let fields = Fields(
            groupCallId: group, fromCallId: from, acceptBinding1: acceptBinding1, creatorUserId: creator,
            signerKey: signerKey, callType: callType, issuedAtMs: issuedAtMs, lifetimeMs: lifetimeMs, invitees: sorted)
        guard let tbs = encodeTbs(fields) else { throw BuildError.invalidInvitees }
        guard let signature = sign(tbs), signature.count == signatureLength else { throw BuildError.signFailed }
        let token = tbs + signature
        return Built(fields: fields, tbs: tbs, token: token, encoded: token.base64EncodedString())
    }

    /// `PROMO_TBS`, the bytes that are signed, or nil when a length does not fit its field.
    static func encodeTbs(_ fields: Fields) -> Data? {
        var out = Data()
        out.append(domain)
        out.append(version)
        guard appendLP(&out, Data(fields.groupCallId.utf8)),
              appendLP(&out, Data(fields.fromCallId.utf8)) else { return nil }
        out.append(fields.acceptBinding1)
        guard appendLP(&out, Data(fields.creatorUserId.utf8)) else { return nil }
        out.append(fields.signerKey)
        out.append(fields.callType)
        appendBigEndian(&out, fields.issuedAtMs, byteCount: 8)
        appendBigEndian(&out, UInt64(fields.lifetimeMs), byteCount: 4)
        guard fields.invitees.count <= 255 else { return nil }
        out.append(UInt8(fields.invitees.count))
        for invitee in fields.invitees {
            guard appendLP(&out, Data(invitee.utf8)) else { return nil }
        }
        return out
    }

    private static func appendLP(_ out: inout Data, _ bytes: Data) -> Bool {
        guard bytes.count <= 0xFFFF else { return false }
        out.append(UInt8(bytes.count >> 8))
        out.append(UInt8(bytes.count & 0xFF))
        out.append(bytes)
        return true
    }

    private static func appendBigEndian(_ out: inout Data, _ value: UInt64, byteCount: Int) {
        var shift = (byteCount - 1) * 8
        while shift >= 0 {
            out.append(UInt8((value >> UInt64(shift)) & 0xFF))
            shift -= 8
        }
    }

    // MARK: - Wire (GROUP_CALLS_V2 2.7, Promotion token)

    /// `<callId>|GRPPROMO:<base64(TOKEN)>`.
    public static func wireData(callId: String, encoded: String) -> String {
        return callId + "|" + tag + encoded
    }

    /// The call id and the base64 text of a `GRPPROMO:` payload, or nil when `data` is not one.
    public static func splitWire(_ data: String) -> (callId: String, encoded: String)? {
        guard let pipe = data.firstIndex(of: "|") else { return nil }
        let callId = String(data[data.startIndex..<pipe])
        let rest = String(data[data.index(after: pipe)...])
        guard rest.hasPrefix(tag) else { return nil }
        return (callId, String(rest.dropFirst(tag.count)))
    }

    // MARK: - Parser (receiver, GROUP_CALLS_V2 2.7, Promotion token, steps R6 to R8)

    /// R6: `encoded` is canonical base64 (standard alphabet, padded, `base64(decode(B)) == B`, no
    /// white space) of more than 64 bytes.
    public static func decodeCanonical(_ encoded: String) -> Data? {
        guard let raw = Data(base64Encoded: encoded), raw.count > signatureLength else { return nil }
        guard raw.base64EncodedString() == encoded else { return nil }
        return raw
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var remaining: Int { return bytes.count - offset }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, remaining >= count else { return nil }
            let slice = Array(bytes[offset..<(offset + count)])
            offset += count
            return slice
        }

        mutating func readU8() -> UInt8? {
            guard let one = take(1) else { return nil }
            return one[0]
        }

        mutating func readUInt(byteCount: Int) -> UInt64? {
            guard let chunk = take(byteCount) else { return nil }
            var value: UInt64 = 0
            for byte in chunk { value = (value << 8) | UInt64(byte) }
            return value
        }

        mutating func readLP() -> [UInt8]? {
            guard let length = readUInt(byteCount: 2) else { return nil }
            return take(Int(length))
        }
    }

    private static func readCanonicalId(_ reader: inout Reader) -> String? {
        guard let bytes = reader.readLP() else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        guard GroupCallIds.isCanonical(text), Array(text.utf8) == bytes else { return nil }
        return text
    }

    /// R6 to R8: the base64 text to a parsed token, or the drop code. Signature, signer key and
    /// bindings are not looked at here.
    public static func parse(encoded: String) -> Result<Parsed, Drop> {
        guard let raw = decodeCanonical(encoded) else { return .failure(.malformed) }
        let bytes = Array(raw)
        let domainBytes = Array(domain)
        guard bytes.count > domainBytes.count + 1, Array(bytes[0..<domainBytes.count]) == domainBytes else {
            return .failure(.malformed)
        }
        guard bytes[domainBytes.count] == version else { return .failure(.badVersion) }
        var reader = Reader(bytes)
        reader.offset = domainBytes.count + 1
        guard let group = readCanonicalId(&reader),
              let from = readCanonicalId(&reader),
              let binding = reader.take(bindingLength),
              let creator = readCanonicalId(&reader),
              let signerKey = reader.take(keyLength),
              let callType = reader.readU8(), callType == callTypeAudio,
              let issued = reader.readUInt(byteCount: 8),
              let lifetime = reader.readUInt(byteCount: 4),
              lifetime >= UInt64(minLifetimeMs), lifetime <= UInt64(maxLifetimeMs),
              let count = reader.readU8(), count >= 1, Int(count) <= maxInvitees else { return .failure(.malformed) }
        var invitees: [String] = []
        var previous: [UInt8]?
        for _ in 0..<Int(count) {
            guard let id = readCanonicalId(&reader), id != creator else { return .failure(.malformed) }
            let current = Array(id.utf8)
            if let before = previous, !before.lexicographicallyPrecedes(current) { return .failure(.malformed) }
            previous = current
            invitees.append(id)
        }
        guard reader.remaining == signatureLength, let signature = reader.take(signatureLength) else {
            return .failure(.malformed)
        }
        let signedLength = bytes.count - signatureLength
        let fields = Fields(
            groupCallId: group, fromCallId: from, acceptBinding1: Data(binding), creatorUserId: creator,
            signerKey: Data(signerKey), callType: callType, issuedAtMs: issued, lifetimeMs: UInt32(lifetime),
            invitees: invitees)
        return .success(Parsed(
            fields: fields, tbs: Data(bytes[0..<signedLength]), signature: Data(signature), token: raw))
    }

    // MARK: - Signature (R10)

    /// The little-endian group order l of Ed25519, 2^252 + 27742317777372353535851937790883648493.
    private static let groupOrder: [UInt8] = [
        0xED, 0xD3, 0xF5, 0x5C, 0x1A, 0x63, 0x12, 0x58, 0xD6, 0x9C, 0xF7, 0xA2, 0xDE, 0xF9, 0xDE, 0x14,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
    ]

    /// Whether the scalar S of a 64-byte Ed25519 signature is below the group order (RFC 8032 section
    /// 5.1.7). A library that accepts S + l verifies a malleated signature; this check refuses it.
    public static func scalarIsCanonical(_ signature: Data) -> Bool {
        let bytes = Array(signature)
        guard bytes.count == signatureLength else { return false }
        var index = 31
        while index >= 0 {
            let value = bytes[32 + index]
            let limit = groupOrder[index]
            if value < limit { return true }
            if value > limit { return false }
            index -= 1
        }
        return false
    }

    /// R10: pure RFC 8032 verification of the signature over `PROMO_TBS` under `signerKey`, the same
    /// verifier and strictness as `sigV6`, plus the explicit S < l test.
    public static func verifySignature(_ parsed: Parsed, signerKey: Data) -> Bool {
        guard scalarIsCanonical(parsed.signature) else { return false }
        return HandshakeTranscript.verify(
            transcript: parsed.tbs, signature: parsed.signature, signerIdentityKey: signerKey)
    }

    // MARK: - Freshness (R12)

    /// R12: `now` is this device's wall clock in ms. Both bounds are inclusive on the accepting side.
    public static func freshnessDrop(issuedAtMs: UInt64, lifetimeMs: UInt32, nowWallMs: Int64) -> Drop? {
        let issued = Int64(clamping: min(issuedAtMs, UInt64(1) << 60))
        if nowWallMs < issued - skewMs { return .future }
        if nowWallMs > issued + Int64(lifetimeMs) + skewMs { return .stale }
        return nil
    }
}

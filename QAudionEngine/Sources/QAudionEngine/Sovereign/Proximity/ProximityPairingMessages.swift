import Foundation

// Proximity pairing v1 — protocol messages (spec §8).
//
//   message = u8(type) ‖ body
//
//   0x01 HELLO   S→D  u32be(frameIndex) ‖ xpk_S[32] ‖ nonce_S[32] ‖ tag[32]      (100 B)
//   0x02 OFFER   D→S  ek_D[1568] ‖ xpk_D[32] ‖ nonce_D[32]                        (1632 B)
//   0x03 ACCEPT  S→D  ct[1568] ‖ sealed_S                                          (1746 + n B)
//   0x04 FINISH  D→S  sealed_D                                                     (178 + n B)
//   0x05 CONFIRM both mac[32]
//   0x06 ABORT   both u8(reason)
//   0x07 BUSY    D→S  (empty)
//
//   idBlock  = idPub[32] ‖ encPub[32] ‖ u16be(n) ‖ userId[n]                    (66 + n B)
//   sealed_X = AES-256-GCM(K_enc_X, zero nonce, aad, idBlock_X ‖ sig_X[64] ‖ mac_X[32])
//              as ciphertext ‖ tag[16]                                           (178 + n B)
//
// SIGMA-I identity hiding: no identity is ever on the air in clear. OFFER
// carries ephemeral keys only; each identity travels inside a sealed box that
// only the two ends of this exchange can open. The message decoder therefore
// treats a sealed box as opaque bytes and checks only that its length is one a
// valid box can have (178 + n, 1 ≤ n ≤ 256). The box is parsed — strictly —
// by `decodeSealedPlaintext` once the session has opened it.
//
// The decoder is strict: exact lengths, no trailing bytes, no unknown type.
// Every rejection is `ProximityPairingError.protocolViolation`. Direction and
// ordering are enforced by the session state machines, not here.
//
// The encoders assume well-formed field lengths (the sessions only ever
// build messages from values of the exact sizes); a malformed value encodes
// to bytes that every strict decoder, ours included, rejects.

public enum ProximityMessage: Equatable {

    case hello(Hello)
    case offer(Offer)
    case accept(Accept)
    case finish(Finish)
    case confirm(mac: Data)
    case abort(reason: UInt8)
    case busy

    public struct Hello: Equatable {
        public let frameIndex: UInt32
        public let scannerEphemeralX25519: Data
        public let scannerNonce: Data
        public let tag: Data

        public init(frameIndex: UInt32, scannerEphemeralX25519: Data, scannerNonce: Data, tag: Data) {
            self.frameIndex = frameIndex
            self.scannerEphemeralX25519 = Data(scannerEphemeralX25519)
            self.scannerNonce = Data(scannerNonce)
            self.tag = Data(tag)
        }
    }

    /// The displayer's ephemeral keys only. Its identity is sent later, sealed, in FINISH.
    public struct Offer: Equatable {
        public let mlKemPublicKey: Data
        public let displayerEphemeralX25519: Data
        public let displayerNonce: Data

        public init(mlKemPublicKey: Data, displayerEphemeralX25519: Data, displayerNonce: Data) {
            self.mlKemPublicKey = Data(mlKemPublicKey)
            self.displayerEphemeralX25519 = Data(displayerEphemeralX25519)
            self.displayerNonce = Data(displayerNonce)
        }
    }

    public struct Accept: Equatable {
        public let mlKemCiphertext: Data
        /// `sealed_S`: AES-256-GCM ciphertext ‖ tag of `idBlock_S ‖ sig_S ‖ mac_S`
        /// under K_enc_S with aad TH1. Opaque until opened.
        public let sealed: Data

        public init(mlKemCiphertext: Data, sealed: Data) {
            self.mlKemCiphertext = Data(mlKemCiphertext)
            self.sealed = Data(sealed)
        }
    }

    public struct Finish: Equatable {
        /// `sealed_D`: AES-256-GCM ciphertext ‖ tag of `idBlock_D ‖ sig_D ‖ mac_D`
        /// under K_enc_D with aad TH_S. Opaque until opened.
        public let sealed: Data

        public init(sealed: Data) {
            self.sealed = Data(sealed)
        }
    }

    /// The plaintext of a sealed box once opened: the sender's identity, its
    /// Ed25519 signature and its transcript MAC (spec §8, §10).
    public struct SealedIdentity: Equatable {
        public let identity: ProximityPeerIdentity
        /// `idPub ‖ encPub ‖ u16be(n) ‖ userId` exactly as received: the
        /// bytes TH_S / TH_D are computed over.
        public let idBlock: Data
        public let signature: Data
        public let mac: Data

        public init(identity: ProximityPeerIdentity, idBlock: Data, signature: Data, mac: Data) {
            self.identity = identity
            self.idBlock = Data(idBlock)
            self.signature = Data(signature)
            self.mac = Data(mac)
        }
    }

    // MARK: - Layout constants (derived from ProximityPairing sizes)

    private static let u16Bytes: Int = 2
    private static let u32Bytes: Int = 4

    /// `sig ‖ mac` after the idBlock inside a sealed box.
    private static var sealedTrailerBytes: Int {
        return ProximityPairing.ed25519SignatureBytes + ProximityPairing.macBytes
    }

    /// Smallest valid sealed box (n = 1).
    public static var minSealedBytes: Int {
        return ProximityPairing.sealedIdentityFixedBytes + 1
    }

    /// Largest valid sealed box (n = 256).
    public static var maxSealedBytes: Int {
        return ProximityPairing.sealedIdentityFixedBytes + ProximityPairing.maxUserIdBytes
    }

    // MARK: - Encoding

    /// `u8(type) ‖ body` (spec §8).
    public func encoded() -> Data {
        var out = Data()
        switch self {
        case .hello(let hello):
            out.append(ProximityPairing.MessageType.hello.rawValue)
            out.append(ProximityMessage.helloBody(hello))
        case .offer(let offer):
            out.append(ProximityPairing.MessageType.offer.rawValue)
            out.append(ProximityMessage.offerBody(offer))
        case .accept(let accept):
            out.append(ProximityPairing.MessageType.accept.rawValue)
            out.append(accept.mlKemCiphertext)
            out.append(accept.sealed)
        case .finish(let finish):
            out.append(ProximityPairing.MessageType.finish.rawValue)
            out.append(finish.sealed)
        case .confirm(mac: let mac):
            out.append(ProximityPairing.MessageType.confirm.rawValue)
            out.append(mac)
        case .abort(reason: let reason):
            out.append(ProximityPairing.MessageType.abort.rawValue)
            out.append(reason)
        case .busy:
            out.append(ProximityPairing.MessageType.busy.rawValue)
        }
        return out
    }

    /// `u32be(frameIndex) ‖ xpk_S ‖ nonce_S ‖ tag` — the HELLO body as it enters the transcript.
    public static func helloBody(_ hello: Hello) -> Data {
        var out = Data(capacity: ProximityPairing.helloBodyBytes)
        out.append(ProximityBytes.u32be(hello.frameIndex))
        out.append(hello.scannerEphemeralX25519)
        out.append(hello.scannerNonce)
        out.append(hello.tag)
        return out
    }

    /// `ek_D ‖ xpk_D ‖ nonce_D` — committed to by the QR, enters TH1.
    public static func offerBody(_ offer: Offer) -> Data {
        var out = Data(capacity: ProximityPairing.offerBodyBytes)
        out.append(offer.mlKemPublicKey)
        out.append(offer.displayerEphemeralX25519)
        out.append(offer.displayerNonce)
        return out
    }

    /// `idPub ‖ encPub ‖ u16be(n) ‖ userId` (spec §8). A `ProximityPeerIdentity`
    /// is validated on construction, so this is always a well-formed idBlock.
    public static func idBlock(_ identity: ProximityPeerIdentity) -> Data {
        let userId: Data = Data(identity.userId.utf8)
        let length: UInt16 = UInt16(truncatingIfNeeded: userId.count)
        var out = Data(capacity: ProximityPairing.idBlockFixedBytes + userId.count)
        out.append(identity.signingPublicKey)
        out.append(identity.encryptionPublicKey)
        out.append(ProximityBytes.u16be(length))
        out.append(userId)
        return out
    }

    /// `idBlock ‖ sig[64] ‖ mac[32]` — the plaintext a side seals (spec §8).
    public static func sealedPlaintext(idBlock: Data, signature: Data, mac: Data) -> Data {
        var out = Data(capacity: idBlock.count + sealedTrailerBytes)
        out.append(idBlock)
        out.append(signature)
        out.append(mac)
        return out
    }

    // MARK: - Decoding

    /// Strict decode of one reassembled message. Accepts a `Data` slice.
    public static func decode(_ message: Data) throws -> ProximityMessage {
        let bytes: Data = Data(message)
        guard !bytes.isEmpty else {
            throw ProximityPairingError.protocolViolation("empty message")
        }
        guard bytes.count <= ProximityPairing.maxMessageBytes else {
            throw ProximityPairingError.protocolViolation("message too large")
        }
        guard let type = ProximityPairing.MessageType(rawValue: bytes[bytes.startIndex]) else {
            throw ProximityPairingError.protocolViolation("unknown message type")
        }
        let body: Data = Data(bytes.subdata(in: (bytes.startIndex + 1)..<bytes.endIndex))

        switch type {
        case .hello:
            return .hello(try decodeHello(body))
        case .offer:
            return .offer(try decodeOffer(body))
        case .accept:
            return .accept(try decodeAccept(body))
        case .finish:
            guard isValidSealedLength(body.count) else {
                throw ProximityPairingError.protocolViolation("FINISH length")
            }
            return .finish(Finish(sealed: body))
        case .confirm:
            guard body.count == ProximityPairing.macBytes else {
                throw ProximityPairingError.protocolViolation("CONFIRM length")
            }
            return .confirm(mac: body)
        case .abort:
            guard body.count == 1 else {
                throw ProximityPairingError.protocolViolation("ABORT length")
            }
            return .abort(reason: body[body.startIndex])
        case .busy:
            guard body.isEmpty else {
                throw ProximityPairingError.protocolViolation("BUSY length")
            }
            return .busy
        }
    }

    /// Strict parse of a whole idBlock: exact length `66 + n`, `1 ≤ n ≤ 256`,
    /// userId in the §8 grammar, no trailing bytes.
    public static func decodeIdBlock(_ block: Data) throws -> ProximityPeerIdentity {
        let bytes: Data = Data(block)
        return try decodeIdentity(bytes, at: 0, trailerBytes: 0)
    }

    /// Strict parse of an opened sealed box: exactly `idBlock ‖ sig[64] ‖ mac[32]`,
    /// i.e. `66 + n + 96` bytes where `n` is the idBlock's own length field.
    /// Any other length, or an invalid idBlock, is a protocol violation.
    public static func decodeSealedPlaintext(_ plaintext: Data) throws -> SealedIdentity {
        let bytes: Data = Data(plaintext)
        let trailer: Int = sealedTrailerBytes
        let minimum: Int = ProximityPairing.idBlockFixedBytes + 1 + trailer
        guard bytes.count >= minimum else {
            throw ProximityPairingError.protocolViolation("sealed plaintext length")
        }
        // Exact-length check: decodeIdentity requires the idBlock's userId to
        // end exactly `trailer` bytes before the end of the plaintext.
        let identity: ProximityPeerIdentity = try decodeIdentity(bytes, at: 0, trailerBytes: trailer)
        let blockLength: Int = bytes.count - trailer
        let block: Data = slice(bytes, 0, blockLength)
        let signature: Data = slice(bytes, blockLength, ProximityPairing.ed25519SignatureBytes)
        let macOffset: Int = blockLength + ProximityPairing.ed25519SignatureBytes
        let mac: Data = slice(bytes, macOffset, ProximityPairing.macBytes)
        return SealedIdentity(identity: identity, idBlock: block, signature: signature, mac: mac)
    }

    /// A sealed box is `178 + n` bytes for some `1 ≤ n ≤ 256`.
    private static func isValidSealedLength(_ count: Int) -> Bool {
        return count >= minSealedBytes && count <= maxSealedBytes
    }

    private static func decodeHello(_ body: Data) throws -> Hello {
        guard body.count == ProximityPairing.helloBodyBytes else {
            throw ProximityPairingError.protocolViolation("HELLO length")
        }
        guard let frameIndex = ProximityBytes.readU32be(body, at: 0) else {
            throw ProximityPairingError.protocolViolation("HELLO frame index")
        }
        var offset: Int = u32Bytes
        let xpk: Data = slice(body, offset, ProximityPairing.x25519PublicKeyBytes)
        offset += ProximityPairing.x25519PublicKeyBytes
        let nonce: Data = slice(body, offset, ProximityPairing.nonceBytes)
        offset += ProximityPairing.nonceBytes
        let tag: Data = slice(body, offset, ProximityPairing.macBytes)
        return Hello(frameIndex: frameIndex, scannerEphemeralX25519: xpk, scannerNonce: nonce, tag: tag)
    }

    /// Exactly 1632 bytes: an OFFER that carries anything beyond the ephemeral
    /// keys (e.g. a pre-SIGMA identity) is rejected.
    private static func decodeOffer(_ body: Data) throws -> Offer {
        guard body.count == ProximityPairing.offerBodyBytes else {
            throw ProximityPairingError.protocolViolation("OFFER length")
        }
        var offset: Int = 0
        let ek: Data = slice(body, offset, ProximityPairing.mlKemPublicKeyBytes)
        offset += ProximityPairing.mlKemPublicKeyBytes
        let xpk: Data = slice(body, offset, ProximityPairing.x25519PublicKeyBytes)
        offset += ProximityPairing.x25519PublicKeyBytes
        let nonce: Data = slice(body, offset, ProximityPairing.nonceBytes)
        return Offer(mlKemPublicKey: ek, displayerEphemeralX25519: xpk, displayerNonce: nonce)
    }

    /// `ct[1568] ‖ sealed_S` with a sealed part of a length a valid box can have.
    private static func decodeAccept(_ body: Data) throws -> Accept {
        let ctBytes: Int = ProximityPairing.mlKemCiphertextBytes
        guard body.count > ctBytes, isValidSealedLength(body.count - ctBytes) else {
            throw ProximityPairingError.protocolViolation("ACCEPT length")
        }
        let ct: Data = slice(body, 0, ctBytes)
        let sealed: Data = slice(body, ctBytes, body.count - ctBytes)
        return Accept(mlKemCiphertext: ct, sealed: sealed)
    }

    /// Parses `idPub ‖ encPub ‖ u16be(n) ‖ userId[n]` at `offset` and requires
    /// that exactly `trailerBytes` bytes follow `userId` (no more, no fewer).
    private static func decodeIdentity(_ body: Data, at offset: Int, trailerBytes: Int) throws -> ProximityPeerIdentity {
        let keysBytes: Int = ProximityPairing.ed25519PublicKeyBytes + ProximityPairing.x25519PublicKeyBytes
        let lengthOffset: Int = offset + keysBytes
        guard offset >= 0, body.count >= lengthOffset + u16Bytes else {
            throw ProximityPairingError.protocolViolation("identity length")
        }
        guard let rawLength = ProximityBytes.readU16be(body, at: lengthOffset) else {
            throw ProximityPairingError.protocolViolation("userId length field")
        }
        let userIdLength: Int = Int(rawLength)
        guard userIdLength >= 1, userIdLength <= ProximityPairing.maxUserIdBytes else {
            throw ProximityPairingError.protocolViolation("userId length")
        }
        let userIdOffset: Int = lengthOffset + u16Bytes
        let expectedTotal: Int = userIdOffset + userIdLength + trailerBytes
        guard body.count == expectedTotal else {
            throw ProximityPairingError.protocolViolation("identity length")
        }
        let signingKey: Data = slice(body, offset, ProximityPairing.ed25519PublicKeyBytes)
        let encryptionKey: Data = slice(body, offset + ProximityPairing.ed25519PublicKeyBytes,
                                        ProximityPairing.x25519PublicKeyBytes)
        let userIdBytes: Data = slice(body, userIdOffset, userIdLength)
        guard let userId = String(data: userIdBytes, encoding: .utf8) else {
            throw ProximityPairingError.protocolViolation("userId encoding")
        }
        // Byte-exact round trip: rejects anything Foundation normalised or dropped (e.g. a BOM).
        let reencoded: Data = Data(userId.utf8)
        guard reencoded == userIdBytes else {
            throw ProximityPairingError.protocolViolation("userId encoding")
        }
        do {
            return try ProximityPeerIdentity(userId: userId,
                                             signingPublicKey: signingKey,
                                             encryptionPublicKey: encryptionKey)
        } catch {
            throw ProximityPairingError.protocolViolation("identity")
        }
    }

    /// `count` bytes at the zero-based `offset` of a normalized (startIndex 0) buffer.
    /// Callers check bounds first.
    private static func slice(_ data: Data, _ offset: Int, _ count: Int) -> Data {
        let start: Int = data.startIndex + offset
        return Data(data.subdata(in: start..<(start + count)))
    }
}

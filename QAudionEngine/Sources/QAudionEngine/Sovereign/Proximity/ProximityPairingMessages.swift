import Foundation

// Proximity pairing v1 — protocol messages (spec §8).
//
//   message = u8(type) ‖ body
//
//   0x01 HELLO   S→D  u32be(frameIndex) ‖ xpk_S[32] ‖ nonce_S[32] ‖ tag[32]                       (100 B)
//   0x02 OFFER   D→S  ek_D[1568] ‖ xpk_D[32] ‖ nonce_D[32] ‖ idPub_D[32] ‖ encPub_D[32] ‖ u16be(n) ‖ userId_D[n]
//   0x03 ACCEPT  S→D  ct[1568] ‖ idPub_S[32] ‖ encPub_S[32] ‖ u16be(n) ‖ userId_S[n] ‖ sig_S[64] ‖ mac_S[32]
//   0x04 FINISH  D→S  sig_D[64] ‖ mac_D[32]
//   0x05 CONFIRM both mac[32]
//   0x06 ABORT   both u8(reason)
//   0x07 BUSY    D→S  (empty)
//
// The decoder is strict: exact lengths, 1 ≤ n ≤ 256, valid UTF-8 that
// round-trips byte-for-byte, no trailing bytes, no unknown type. Every
// rejection is `ProximityPairingError.protocolViolation`. Direction and
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

    public struct Offer: Equatable {
        public let mlKemPublicKey: Data
        public let displayerEphemeralX25519: Data
        public let displayerNonce: Data
        public let identity: ProximityPeerIdentity

        public init(mlKemPublicKey: Data, displayerEphemeralX25519: Data, displayerNonce: Data,
                    identity: ProximityPeerIdentity) {
            self.mlKemPublicKey = Data(mlKemPublicKey)
            self.displayerEphemeralX25519 = Data(displayerEphemeralX25519)
            self.displayerNonce = Data(displayerNonce)
            self.identity = identity
        }
    }

    public struct Accept: Equatable {
        public let mlKemCiphertext: Data
        public let identity: ProximityPeerIdentity
        public let signature: Data
        public let mac: Data

        public init(mlKemCiphertext: Data, identity: ProximityPeerIdentity, signature: Data, mac: Data) {
            self.mlKemCiphertext = Data(mlKemCiphertext)
            self.identity = identity
            self.signature = Data(signature)
            self.mac = Data(mac)
        }
    }

    public struct Finish: Equatable {
        public let signature: Data
        public let mac: Data

        public init(signature: Data, mac: Data) {
            self.signature = Data(signature)
            self.mac = Data(mac)
        }
    }

    // MARK: - Layout constants (derived from ProximityPairing sizes)

    private static let u16Bytes: Int = 2
    private static let u32Bytes: Int = 4

    /// OFFER bytes before `userId_D`: ek ‖ xpk ‖ nonce ‖ idPub ‖ encPub ‖ u16be(n).
    private static var offerFixedBytes: Int {
        let keys: Int = ProximityPairing.mlKemPublicKeyBytes + ProximityPairing.x25519PublicKeyBytes
        let rest: Int = ProximityPairing.nonceBytes + ProximityPairing.ed25519PublicKeyBytes
            + ProximityPairing.x25519PublicKeyBytes
        return keys + rest + u16Bytes
    }

    /// ACCEPT bytes before `userId_S`: ct ‖ idPub ‖ encPub ‖ u16be(n).
    private static var acceptFixedBytes: Int {
        let head: Int = ProximityPairing.mlKemCiphertextBytes + ProximityPairing.ed25519PublicKeyBytes
        return head + ProximityPairing.x25519PublicKeyBytes + u16Bytes
    }

    /// ACCEPT bytes after `userId_S`: sig ‖ mac.
    private static var acceptTrailerBytes: Int {
        return ProximityPairing.ed25519SignatureBytes + ProximityPairing.macBytes
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
            out.append(ProximityMessage.acceptUnsignedBody(mlKemCiphertext: accept.mlKemCiphertext,
                                                           identity: accept.identity))
            out.append(accept.signature)
            out.append(accept.mac)
        case .finish(let finish):
            out.append(ProximityPairing.MessageType.finish.rawValue)
            out.append(finish.signature)
            out.append(finish.mac)
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

    /// `ek_D ‖ xpk_D ‖ nonce_D ‖ idPub_D ‖ encPub_D ‖ u16be(n) ‖ userId_D` — committed to by the QR.
    public static func offerBody(_ offer: Offer) -> Data {
        var out = Data()
        out.append(offer.mlKemPublicKey)
        out.append(offer.displayerEphemeralX25519)
        out.append(offer.displayerNonce)
        out.append(identityBytes(offer.identity))
        return out
    }

    /// `ct ‖ idPub_S ‖ encPub_S ‖ u16be(n) ‖ userId_S` — the ACCEPT unsigned part (spec §8).
    public static func acceptUnsignedBody(mlKemCiphertext: Data, identity: ProximityPeerIdentity) -> Data {
        var out = Data()
        out.append(mlKemCiphertext)
        out.append(identityBytes(identity))
        return out
    }

    /// `idPub ‖ encPub ‖ u16be(n) ‖ userId`.
    private static func identityBytes(_ identity: ProximityPeerIdentity) -> Data {
        let userId: Data = Data(identity.userId.utf8)
        let length: UInt16 = UInt16(truncatingIfNeeded: userId.count)
        var out = Data()
        out.append(identity.signingPublicKey)
        out.append(identity.encryptionPublicKey)
        out.append(ProximityBytes.u16be(length))
        out.append(userId)
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
            let expected: Int = ProximityPairing.ed25519SignatureBytes + ProximityPairing.macBytes
            guard body.count == expected else {
                throw ProximityPairingError.protocolViolation("FINISH length")
            }
            let signature: Data = slice(body, 0, ProximityPairing.ed25519SignatureBytes)
            let mac: Data = slice(body, ProximityPairing.ed25519SignatureBytes, ProximityPairing.macBytes)
            return .finish(Finish(signature: signature, mac: mac))
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

    private static func decodeOffer(_ body: Data) throws -> Offer {
        let fixed: Int = offerFixedBytes
        guard body.count > fixed else {
            throw ProximityPairingError.protocolViolation("OFFER length")
        }
        var offset: Int = 0
        let ek: Data = slice(body, offset, ProximityPairing.mlKemPublicKeyBytes)
        offset += ProximityPairing.mlKemPublicKeyBytes
        let xpk: Data = slice(body, offset, ProximityPairing.x25519PublicKeyBytes)
        offset += ProximityPairing.x25519PublicKeyBytes
        let nonce: Data = slice(body, offset, ProximityPairing.nonceBytes)
        offset += ProximityPairing.nonceBytes
        let identity: ProximityPeerIdentity = try decodeIdentity(body, at: offset, trailerBytes: 0)
        return Offer(mlKemPublicKey: ek, displayerEphemeralX25519: xpk, displayerNonce: nonce, identity: identity)
    }

    private static func decodeAccept(_ body: Data) throws -> Accept {
        let minimum: Int = acceptFixedBytes + acceptTrailerBytes
        guard body.count > minimum else {
            throw ProximityPairingError.protocolViolation("ACCEPT length")
        }
        let ct: Data = slice(body, 0, ProximityPairing.mlKemCiphertextBytes)
        let identityOffset: Int = ProximityPairing.mlKemCiphertextBytes
        let identity: ProximityPeerIdentity = try decodeIdentity(body, at: identityOffset,
                                                                 trailerBytes: acceptTrailerBytes)
        let signatureOffset: Int = body.count - acceptTrailerBytes
        let signature: Data = slice(body, signatureOffset, ProximityPairing.ed25519SignatureBytes)
        let macOffset: Int = signatureOffset + ProximityPairing.ed25519SignatureBytes
        let mac: Data = slice(body, macOffset, ProximityPairing.macBytes)
        return Accept(mlKemCiphertext: ct, identity: identity, signature: signature, mac: mac)
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
            throw ProximityPairingError.protocolViolation("message length")
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

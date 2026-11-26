import Foundation
import CryptoKit

/// The in-call announcement of the contact-voice check, version 1: plaintext, seal and open. Sealed like the confidence announce with
/// its own label: AES-256-GCM, key = HKDF-SHA256(session key, empty salt, info = label + lowercase call id, 32 bytes), a random 12-byte
/// nonce, no associated data, sealed = nonce (12) + ciphertext (16) + tag (16), padded standard Base64 on send (60 characters).
public enum VoiceVconsCodec {
    public static let label = "voice-consent-announce-v1|"
    static let nonceLen = 12
    static let tagLen = 16
    static let plaintextLen = 16
    static let sealedLen = nonceLen + plaintextLen + tagLen
    static let version: UInt8 = 1
    public static let flagAllow = 1
    public static let flagWithdraw = 2
    public static let flagLearning = 4
    public static let flagVerifying = 8
    static let reservedFlags = 0xF0
    static let maxRouteClass = 5
    /// This app's platform word (1 Android, 2 iOS).
    public static let platformIos = 2

    public enum Effect: String, Equatable, Sendable { case allow, off, withdraw }

    /// The fields of one message. `seq` is an unsigned 32-bit number.
    public struct Fields: Equatable, Sendable {
        public var seq: UInt32
        public var allow: Bool
        public var withdraw: Bool
        public var learning: Bool
        public var verifying: Bool
        public var routeClass: Int
        public var platform: Int
        public var unixMs: Int64

        public init(seq: UInt32, allow: Bool, withdraw: Bool, learning: Bool, verifying: Bool, routeClass: Int, platform: Int, unixMs: Int64) {
            self.seq = seq
            self.allow = allow
            self.withdraw = withdraw
            self.learning = learning
            self.verifying = verifying
            self.routeClass = routeClass
            self.platform = platform
            self.unixMs = unixMs
        }

        /// Withdraw wins whatever the allow bit says.
        public var effect: Effect { withdraw ? .withdraw : (allow ? .allow : .off) }
    }

    /// The fields, or the reason the message was dropped (`base64`, `length`, `tag`, `version`, `flags`).
    public enum Opened: Equatable, Sendable {
        case ok(Fields)
        case rejected(String)
    }

    private struct Rejection: Error { let reason: String }

    static func lowerAscii(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.value >= 65 && u.value <= 90, let low = Unicode.Scalar(u.value + 32) { out.append(low) } else { out.append(u) }
        }
        return String(out)
    }

    static func deriveKey(sessionKey: Data, callId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionKey), salt: Data(),
            info: Data((label + lowerAscii(callId)).utf8), outputByteCount: 32)
    }

    static func plaintext(_ f: Fields) -> Data {
        var flags = 0
        if f.allow { flags |= flagAllow }
        if f.withdraw { flags |= flagWithdraw }
        if f.learning { flags |= flagLearning }
        if f.verifying { flags |= flagVerifying }
        var d = Data([version])
        withUnsafeBytes(of: f.seq.bigEndian) { d.append(contentsOf: $0) }
        d.append(UInt8(flags))
        d.append(UInt8(truncatingIfNeeded: f.routeClass))
        d.append(UInt8(truncatingIfNeeded: f.platform))
        withUnsafeBytes(of: f.unixMs.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    /// The padded Base64 string. `nonce` is random unless a test pins it. Nil only when the cipher fails.
    public static func seal(sessionKey: Data, callId: String, fields: Fields, nonce: Data? = nil) -> String? {
        var copy = Data([UInt8](sessionKey)) // a copy of the key bytes, cleared after use
        defer { CryptoConstants.zeroize(&copy) }
        do {
            let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
            let box = try AES.GCM.seal(plaintext(fields), using: deriveKey(sessionKey: copy, callId: callId), nonce: n)
            var out = Data(box.nonce)
            out.append(box.ciphertext)
            out.append(box.tag)
            return out.base64EncodedString()
        } catch {
            return nil
        }
    }

    /// Opens with the current key and, when its tag fails, with the previous one. Never throws.
    public static func open(current: Data?, previous: Data?, callId: String, string: String) -> Opened {
        let keys = [current, previous].compactMap { $0 }
        if keys.isEmpty { return .rejected("tag") }
        do {
            return .ok(try openOrThrow(keys, callId, string))
        } catch let r as Rejection {
            return .rejected(r.reason)
        } catch {
            return .rejected("tag")
        }
    }

    public static func open(sessionKey: Data, callId: String, string: String) -> Opened {
        open(current: sessionKey, previous: nil, callId: callId, string: string)
    }

    private static func openOrThrow(_ keys: [Data], _ callId: String, _ string: String) throws -> Fields {
        let sealed = try decodeStrict(string)
        if sealed.count != sealedLen { throw Rejection(reason: "length") }
        var pt: Data?
        for k in keys {
            if let p = tryOpen(k, callId, sealed) {
                pt = p
                break
            }
        }
        guard let p = pt else { throw Rejection(reason: "tag") }
        let b = [UInt8](p)
        if b.count != plaintextLen { throw Rejection(reason: "length") }
        if b[0] != version { throw Rejection(reason: "version") }
        let seq = b[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let flags = Int(b[5])
        if flags & reservedFlags != 0 { throw Rejection(reason: "flags") }
        let route = Int(b[6])
        let platform = Int(b[7])
        let ms = b[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Fields(
            seq: seq, allow: flags & flagAllow != 0, withdraw: flags & flagWithdraw != 0,
            learning: flags & flagLearning != 0, verifying: flags & flagVerifying != 0,
            routeClass: route <= maxRouteClass ? route : 0, platform: (platform == 1 || platform == 2) ? platform : 0,
            unixMs: Int64(bitPattern: ms))
    }

    private static func tryOpen(_ sessionKey: Data, _ callId: String, _ sealed: Data) -> Data? {
        var copy = Data([UInt8](sessionKey)) // a copy of the key bytes, cleared after use
        defer { CryptoConstants.zeroize(&copy) }
        let key = deriveKey(sessionKey: copy, callId: callId)
        do {
            let s = [UInt8](sealed)
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(s[0..<nonceLen])), ciphertext: Data(s[nonceLen..<(s.count - tagLen)]),
                tag: Data(s[(s.count - tagLen)...]))
            return try AES.GCM.open(box, using: key)
        } catch {
            return nil
        }
    }

    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    /// Strict standard Base64 with optional padding: only 59 or 60 characters hold the 44 sealed bytes. The string is padded to a
    /// multiple of 4 before decoding, and the decoded bytes must encode back to it (no spare bits).
    static func decodeStrict(_ s: String) throws -> Data {
        guard s.utf8.allSatisfy({ $0 < 128 }) else { throw Rejection(reason: "base64") }
        var body = s
        while body.hasSuffix("=") { body.removeLast() }
        let pad = s.count - body.count
        if pad > 2 || body.contains(where: { !alphabet.contains($0) }) { throw Rejection(reason: "base64") }
        if body.count % 4 == 1 || (pad > 0 && (body.count + pad) % 4 != 0) { throw Rejection(reason: "base64") }
        let padded = body + String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let raw = Data(base64Encoded: padded), raw.base64EncodedString() == padded else { throw Rejection(reason: "base64") }
        return raw
    }
}

/// The route class word of a local audio route: 0 unknown, 1 ear, 2 speaker, 3 bt, 4 wired, 5 car.
public enum VoiceRouteClass {
    public static let unknown = 0
    public static let ear = 1
    public static let speaker = 2
    public static let bluetooth = 3
    public static let wired = 4
    public static let car = 5
}

import Foundation
import CryptoKit

// The live frame (WIRE_SPEC section 14.6.3): 37 bytes, `0x01 || ctr (uint32 BE) || AES-256-GCM(ciphertext 16 || tag 16)`, sealed under a
// key that is derived from the share id and the share key of the start message.
//
//     okm      = HKDF-SHA256(salt = sid, ikm = k, info = "qa-loc v1 frame key", L = 44)
//     K_frame  = okm[0..<32]          N_base = okm[32..<44]
//     nonce    = N_base XOR (0x00 x 8 || ctr as uint32 BE)
//     aad      = "qa-loc v1 frame" || 0x00 || sid || ctr (uint32 BE)
//                || len8(sender_user_id) || sender_user_id || len8(recipient_user_id) || recipient_user_id
//
// The user ids are the bytes of the strings exactly as the server sends them (the 36-character lowercase UUID text). They are NEVER
// re-serialised through a platform UUID type (`UUID.uuidString` is upper case): such an id is another id and the frame fails to
// authenticate. This type takes `String`s and uses their UTF-8 bytes as they are.
//
// CryptoKit only. Nothing here keeps state: the counter is owned by `LocationFrameSealer`, the one sealer of a share.

/// The 16 bytes of plaintext of a frame (big endian), section 14.6.3.
public struct LocationFramePlaintext: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Bit 0 `FINAL`, bit 1 `APPROX`; bits 2 to 7 MUST be 0.
    public var flags: UInt8
    /// MUST be 0.
    public var reserved: UInt8
    /// Seconds until the next frame, `IV_MIN`...`IV_MAX` (a sender writes 30 or 60); 0 in a final frame.
    public var iv: UInt16
    public var lat: Int32
    public var lon: Int32
    public var acc: UInt16
    public var age: UInt16

    public init(flags: UInt8, reserved: UInt8, iv: UInt16, lat: Int32, lon: Int32, acc: UInt16, age: UInt16) {
        self.flags = flags
        self.reserved = reserved
        self.iv = iv
        self.lat = lat
        self.lon = lon
        self.acc = acc
        self.age = age
    }

    /// A position frame: the newest fix and its age (already clamped to 65 535), the interval of the tick in force.
    public static func position(latE7: Int32, lonE7: Int32, accuracy: UInt16, age: UInt16, approximate: Bool,
                                interval: UInt16) -> LocationFramePlaintext {
        LocationFramePlaintext(flags: approximate ? LocationWire.flagApprox : 0, reserved: 0, iv: interval, lat: latE7, lon: lonE7,
                               acc: accuracy, age: age)
    }

    /// A final frame: `flags` exactly `FINAL`, every other field zero.
    public static var finalFrame: LocationFramePlaintext {
        LocationFramePlaintext(flags: LocationWire.flagFinal, reserved: 0, iv: 0, lat: 0, lon: 0, acc: 0, age: 0)
    }

    public var isFinal: Bool { flags & LocationWire.flagFinal != 0 }
    public var isApproximate: Bool { flags & LocationWire.flagApprox != 0 }

    /// The 16 bytes on the wire.
    public var bytes: Data {
        var out = Data()
        out.reserveCapacity(LocationWire.framePlaintextLength)
        out.append(flags)
        out.append(reserved)
        out.append(contentsOf: LocationFrameCodec.bigEndian(UInt32(iv), width: 2))
        out.append(contentsOf: LocationFrameCodec.bigEndian(UInt32(bitPattern: lat), width: 4))
        out.append(contentsOf: LocationFrameCodec.bigEndian(UInt32(bitPattern: lon), width: 4))
        out.append(contentsOf: LocationFrameCodec.bigEndian(UInt32(acc), width: 2))
        out.append(contentsOf: LocationFrameCodec.bigEndian(UInt32(age), width: 2))
        return out
    }

    public var description: String { "LocationFramePlaintext(redacted)" }
    public var debugDescription: String { description }
}

/// Why a received frame is dropped, with the stage of section 14.6.4 that dropped it.
public enum LocationFrameFailure: Error, Equatable, Sendable {
    /// Step 1: not canonical base64 of 37 bytes, or a version this receiver does not know. Reasons `length` and `version`.
    case format(reason: String)
    /// Step 2: the frame does not authenticate under this share (a flipped bit, other ids, another share or another direction).
    case auth
    /// Step 4: authenticated, but the plaintext breaks a rule of section 14.6.3. Reasons: `flags`, `reserved`, `iv`, `lat`, `lon`, `acc`,
    /// `final.nonzero`.
    case plaintext(reason: String)

    /// The stage names of the vector file.
    public var stage: String {
        switch self {
        case .format: return "format"
        case .auth: return "auth"
        case .plaintext: return "plaintext"
        }
    }
}

/// `K_frame` and `N_base` of one share: derived once, held only in the memory of the process that seals or opens frames.
public struct LocationFrameKeys {
    let frameKey: SymmetricKey
    let nonceBase: Data
    let sid: Data

    /// The key schedule of section 14.6.3. `nil` when `sid` is not 16 bytes or `k` is not 32.
    public init?(sid: Data, shareKey: Data) {
        guard sid.count == LocationWire.sidLength, shareKey.count == LocationWire.keyLength else { return nil }
        let okm = LocationFrameCodec.deriveOKM(sid: sid, shareKey: shareKey)
        self.frameKey = SymmetricKey(data: okm.prefix(32))
        self.nonceBase = Data(okm.suffix(12))
        self.sid = sid
    }
}

public enum LocationFrameCodec {

    // MARK: Key schedule

    /// `HKDF-SHA256(salt = sid, ikm = k, info, L = 44)`: `K_frame` then `N_base`. Exposed to the known-answer tests only.
    static func deriveOKM(sid: Data, shareKey: Data) -> Data {
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: shareKey), salt: sid)
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(LocationWire.hkdfInfo), outputByteCount: 44)
        return okm.withUnsafeBytes { Data($0) }
    }

    /// `N_base XOR (0x00 x 8 || ctr as uint32 BE)`.
    static func nonce(base: Data, counter: UInt32) -> Data {
        var out = [UInt8](base)
        let tail = bigEndian(counter, width: 4)
        for offset in 0..<4 { out[8 + offset] ^= tail[offset] }
        return Data(out)
    }

    /// The additional data of a frame (section 14.6.3). `nil` when an id is longer than 255 bytes (it cannot be written with a
    /// one-byte length).
    static func aad(sid: Data, counter: UInt32, senderId: String, recipientId: String) -> Data? {
        let sender = Array(senderId.utf8)
        let recipient = Array(recipientId.utf8)
        guard sender.count <= 255, recipient.count <= 255 else { return nil }
        var out = Data(LocationWire.aadLabel)
        out.append(0x00)
        out.append(sid)
        out.append(contentsOf: bigEndian(counter, width: 4))
        out.append(UInt8(sender.count))
        out.append(contentsOf: sender)
        out.append(UInt8(recipient.count))
        out.append(contentsOf: recipient)
        return out
    }

    static func bigEndian(_ value: UInt32, width: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(width)
        var shift = (width - 1) * 8
        while shift >= 0 {
            out.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
            shift -= 8
        }
        return out
    }

    // MARK: Seal

    /// A sealed frame: its 37 bytes, its counter and whether it is a final frame. The sealer hands it over; whatever happens to the
    /// write, the counter is spent.
    public struct Sealed: Equatable, Sendable {
        public let bytes: Data
        public let counter: UInt32
        public let isFinal: Bool

        /// The canonical base64 of the frame (52 characters), the `encrypted_payload` of `eph_relay`.
        public var base64: String { bytes.base64EncodedString() }
    }

    /// Seals `plaintext` under `counter`: `0x01 || ctr || ciphertext || tag`. The caller owns the counter rule (one sealer per share, a
    /// counter sealed at most once under one key): use `LocationFrameSealer`, not this function, in the running app.
    static func seal(_ plaintext: LocationFramePlaintext, counter: UInt32, keys: LocationFrameKeys, senderId: String,
                     recipientId: String) -> Sealed? {
        guard let additional = aad(sid: keys.sid, counter: counter, senderId: senderId, recipientId: recipientId),
              let gcmNonce = try? AES.GCM.Nonce(data: nonce(base: keys.nonceBase, counter: counter)),
              let box = try? AES.GCM.seal(plaintext.bytes, using: keys.frameKey, nonce: gcmNonce, authenticating: additional) else {
            return nil
        }
        var out = Data()
        out.reserveCapacity(LocationWire.frameLength)
        out.append(LocationWire.frameVersion)
        out.append(contentsOf: bigEndian(counter, width: 4))
        out.append(box.ciphertext)
        out.append(box.tag)
        return Sealed(bytes: out, counter: counter, isFinal: plaintext.isFinal)
    }

    // MARK: Open

    /// The result of opening a frame that authenticated: its counter and its 16 plaintext bytes (not yet judged).
    struct Opened {
        let counter: UInt32
        let plaintext: Data
    }

    /// Step 1 of section 14.6.4: `FRAME_LEN` bytes and `FRAME_VERSION`. A version this receiver does not know is dropped (another
    /// version takes labels of its own and is never opened under these).
    static func checkFormat(_ frame: Data) -> LocationFrameFailure? {
        guard frame.count == LocationWire.frameLength else { return .format(reason: "length") }
        guard frame[frame.startIndex] == LocationWire.frameVersion else { return .format(reason: "version") }
        return nil
    }

    /// The counter of a frame whose format is right.
    static func counter(of frame: Data) -> UInt32 {
        let base = frame.startIndex + 1
        var value: UInt32 = 0
        for offset in 0..<4 { value = (value << 8) | UInt32(frame[base + offset]) }
        return value
    }

    /// Step 2 of section 14.6.4 for one candidate share: derive the nonce and the aad from the frame's own counter and open. `nil` when
    /// the frame does not authenticate under these keys and ids.
    static func open(_ frame: Data, keys: LocationFrameKeys, senderId: String, recipientId: String) -> Opened? {
        let counter = Self.counter(of: frame)
        let start = frame.startIndex
        guard let additional = aad(sid: keys.sid, counter: counter, senderId: senderId, recipientId: recipientId),
              let gcmNonce = try? AES.GCM.Nonce(data: nonce(base: keys.nonceBase, counter: counter)) else { return nil }
        let ciphertext = frame.subdata(in: (start + 5)..<(start + 21))
        let tag = frame.subdata(in: (start + 21)..<(start + 37))
        guard let box = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(box, using: keys.frameKey, authenticating: additional),
              plain.count == LocationWire.framePlaintextLength else { return nil }
        return Opened(counter: counter, plaintext: plain)
    }

    /// Step 4 of section 14.6.4: the plaintext checks of section 14.6.3 (reserved bits and byte, ranges, an all-zero final frame).
    static func judge(_ plaintext: Data) -> Result<LocationFramePlaintext, LocationFrameFailure> {
        let bytes = [UInt8](plaintext)
        guard bytes.count == LocationWire.framePlaintextLength else { return .failure(.plaintext(reason: "length")) }
        func unsigned(_ from: Int, _ width: Int) -> UInt32 {
            var value: UInt32 = 0
            for offset in 0..<width { value = (value << 8) | UInt32(bytes[from + offset]) }
            return value
        }
        let flags = bytes[0]
        let reserved = bytes[1]
        let iv = unsigned(2, 2)
        let lat = Int32(bitPattern: unsigned(4, 4))
        let lon = Int32(bitPattern: unsigned(8, 4))
        let acc = unsigned(12, 2)
        let age = unsigned(14, 2)
        let decoded = LocationFramePlaintext(flags: flags, reserved: reserved, iv: UInt16(iv), lat: lat, lon: lon, acc: UInt16(acc),
                                             age: UInt16(age))
        // Bits 2 to 7 of the flags and the reserved byte MUST be 0.
        if flags & ~(LocationWire.flagFinal | LocationWire.flagApprox) != 0 { return .failure(.plaintext(reason: "flags")) }
        if reserved != 0 { return .failure(.plaintext(reason: "reserved")) }
        if flags & LocationWire.flagFinal != 0 {
            // A final frame carries no position: its flags are exactly FINAL and every other field is zero.
            if flags != LocationWire.flagFinal || iv != 0 || lat != 0 || lon != 0 || acc != 0 || age != 0 {
                return .failure(.plaintext(reason: "final.nonzero"))
            }
            return .success(decoded)
        }
        if Int64(iv) < LocationWire.ivMin || Int64(iv) > LocationWire.ivMax { return .failure(.plaintext(reason: "iv")) }
        if Int64(lat) < LocationWire.latE7Min || Int64(lat) > LocationWire.latE7Max { return .failure(.plaintext(reason: "lat")) }
        if Int64(lon) < LocationWire.lonE7Min || Int64(lon) > LocationWire.lonE7Max { return .failure(.plaintext(reason: "lon")) }
        if Int64(acc) < LocationWire.accMin || Int64(acc) > LocationWire.accMax { return .failure(.plaintext(reason: "acc")) }
        return .success(decoded)
    }

    /// Opens a frame under ONE share and judges the plaintext (steps 1, 2 and 4; the counter rule of step 3 belongs to the receiver
    /// that knows `lastCtr`). Used by the known-answer tests for the positive and negative vectors.
    static func openAndJudge(_ frame: Data, keys: LocationFrameKeys, senderId: String,
                             recipientId: String) -> Result<(counter: UInt32, plaintext: LocationFramePlaintext), LocationFrameFailure> {
        if let failure = checkFormat(frame) { return .failure(failure) }
        guard let opened = open(frame, keys: keys, senderId: senderId, recipientId: recipientId) else { return .failure(.auth) }
        switch judge(opened.plaintext) {
        case .failure(let failure): return .failure(failure)
        case .success(let plain): return .success((counter: opened.counter, plaintext: plain))
        }
    }
}

/// The ONE sealer of a share inside a process (section 14.6.1 rule 9): it owns the share key and the counter of the next frame, and
/// sealing a frame reads the counter and advances it in one serialized step. The counter is taken BEFORE the frame is sealed and is
/// never given back: whether the write of the frame succeeds, fails or is never attempted, that counter value is spent, and nothing in
/// this class can seal it a second time.
///
/// `k` and the counter live only in the memory of this object. There is no `Codable`, no `NSCoding`, no way to read the key back and no
/// copy constructor: a copy handed to another process by the platform (state restoration, an intent, a backup) cannot exist.
public final class LocationFrameSealer: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: LocationFrameKeys?
    private var next: UInt64 = 1
    private let senderId: String
    private let recipientId: String

    /// `nil` when `sid` or `shareKey` has the wrong length.
    public init?(sid: Data, shareKey: Data, senderId: String, recipientId: String) {
        guard let derived = LocationFrameKeys(sid: sid, shareKey: shareKey) else { return nil }
        self.keys = derived
        self.senderId = senderId
        self.recipientId = recipientId
    }

    /// Whether the share key is still held (`false` after `wipe()`).
    public var holdsKey: Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys != nil
    }

    /// The counter the next frame will carry, or `nil` when the key was wiped (a share that ended has no next counter).
    public var nextCounter: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        guard keys != nil, next <= UInt64(UInt32.max) else { return nil }
        return UInt32(next)
    }

    /// Seals one frame under the next counter and advances the counter in the same serialized step. `nil` after `wipe()` or when the
    /// counter space is used up (a share ends long before 2^32 - 1: 24 hours at one frame per 30 seconds is 2 880 frames).
    public func seal(_ plaintext: LocationFramePlaintext) -> LocationFrameCodec.Sealed? {
        lock.lock()
        defer { lock.unlock() }
        guard let keys = keys, next <= UInt64(UInt32.max) else { return nil }
        let counter = UInt32(next)
        // The counter is spent here, before the frame exists: nothing below can give it back.
        next += 1
        return LocationFrameCodec.seal(plaintext, counter: counter, keys: keys, senderId: senderId, recipientId: recipientId)
    }

    /// Deletes the share key and the counter. Idempotent.
    public func wipe() {
        lock.lock()
        keys = nil
        lock.unlock()
    }
}

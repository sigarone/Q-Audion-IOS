import Foundation
import CryptoKit

/// Test-target-ONLY reference implementation of the native FrameCryptor wire and of the P12
/// receiver anti-replay window (WIRE_SPEC §11). Nothing of this ships in the app: the real
/// transformer is the native one in the M150 WebRTC binary, and it is exercised by the build
/// repo's own gtests (`FrameCryptorKat.*`, `FrameReplayWindow.*`, `FrameCryptorReplay.*`).
///
/// This file lets the iOS test target check the shared KAT (`group-calls-v2-frame-crypto.json`,
/// version 2) independently of the native binary: the IV formula, the AES-256-GCM wire layout, the
/// RBSP handling of H.264 bodies, the key ring, and the replay window with its verdicts.
///
/// Wire (WIRE_SPEC §11.1):
/// ```
/// frame   = header(U) || AES-256-GCM(key_slot, iv, aad=header, payload) [ct||tag16] || iv(12) || trailer(2)
/// trailer = 0x0C || keyIndex
/// iv      = BE32(ssrc) || BE32(rtpTs) || BE32((rtpTs - counter) mod 2^32)        counter = full uint32
/// ```
/// For H.264/H.265 the tail `ct||tag||iv||trailer` is RBSP-escaped by the sender; the receiver
/// MUST unescape the whole body BEFORE it reads the trailer and the IV.
enum FrameCryptoKatReference {

    static let ivLength = 12
    static let tagLength = 16
    static let trailerLength = 2

    enum RefError: Error {
        case tooShort
        case badIvLength
        case authenticationFailed
    }

    // MARK: - Key derivation

    /// `aes_key = HKDF-SHA256(ikm = key material, salt = empty, info = 128 x 0x00, L = 32)` — the
    /// stage-2 derivation the native FrameCryptor runs on top of the installed key material.
    static func aesKey(fromMaterial material: Data) -> SymmetricKey {
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data(),
            info: Data(count: 128),
            outputByteCount: 32)
    }

    // MARK: - IV

    /// The v2 IV (P12 decision D2): `ssrc || rtpTs || ((rtpTs - counter) mod 2^32)`, big-endian.
    static func iv(ssrc: UInt32, rtpTimestamp: UInt32, counter: UInt32) -> Data {
        var out = Data()
        for word in [ssrc, rtpTimestamp, rtpTimestamp &- counter] {
            out.append(UInt8((word >> 24) & 0xFF))
            out.append(UInt8((word >> 16) & 0xFF))
            out.append(UInt8((word >> 8) & 0xFF))
            out.append(UInt8(word & 0xFF))
        }
        return out
    }

    private static func word(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return value
    }

    // MARK: - Clear header length (native get_unencrypted_bytes)

    /// `U`: 1 for Opus, 10 for a VP8 key frame, 3 for a VP8 delta frame, 0 for VP9/AV1, and for
    /// H.264/H.265 the offset of the first VCL NALU payload + 2.
    static func unencryptedBytes(codec: String, isKeyFrame: Bool, data: Data) -> Int {
        switch codec {
        case "opus":
            return 1
        case "vp8":
            return isKeyFrame ? 10 : 3
        case "h264":
            let offset = firstVclPayloadStart(data: data, h265: false)
            return offset >= 0 ? offset + 2 : 0
        case "h265":
            let offset = firstVclPayloadStart(data: data, h265: true)
            return offset >= 0 ? offset + 2 : 0
        default:
            return 0
        }
    }

    private static func firstVclPayloadStart(data: Data, h265: Bool) -> Int {
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        while i + 3 <= n {
            var startCodeLength = 0
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                startCodeLength = 3
            } else if i + 4 <= n && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                startCodeLength = 4
            }
            if startCodeLength == 0 {
                i += 1
                continue
            }
            let payloadStart = i + startCodeLength
            if payloadStart >= n { break }
            let first = bytes[payloadStart]
            if h265 {
                if ((first >> 1) & 0x3F) <= 31 { return payloadStart }
            } else {
                let type = first & 0x1F
                if type == 1 || type == 5 { return payloadStart }
            }
            i = payloadStart
        }
        return -1
    }

    // MARK: - RBSP (H.264 / H.265 emulation prevention)

    /// Insert 0x03 after every `00 00` run followed by a byte <= 0x03.
    static func escapeRbsp(_ input: Data) -> Data {
        var out = Data()
        var zeroRun = 0
        for byte in input {
            if zeroRun >= 2 && byte <= 0x03 {
                out.append(0x03)
                zeroRun = 0
            }
            out.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return out
    }

    /// Remove the 0x03 of every `00 00 03` sequence (inverse of `escapeRbsp`).
    static func unescapeRbsp(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var out = Data()
        var i = 0
        while i < bytes.count {
            if i + 2 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0x03 {
                out.append(0)
                out.append(0)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func isAnnexB(_ codec: String) -> Bool {
        return codec == "h264" || codec == "h265"
    }

    // MARK: - Seal / open

    /// Seal `plaintext` (the whole encoded frame, header included) into the wire format.
    static func seal(
        plaintext: Data, keyMaterial: Data, keyIndex: UInt8, codec: String, isKeyFrame: Bool,
        ssrc: UInt32, rtpTimestamp: UInt32, counter: UInt32
    ) throws -> Data {
        let headerLength = unencryptedBytes(codec: codec, isKeyFrame: isKeyFrame, data: plaintext)
        let header = Data(plaintext.prefix(headerLength))
        let payload = Data(plaintext.dropFirst(headerLength))
        let nonceBytes = iv(ssrc: ssrc, rtpTimestamp: rtpTimestamp, counter: counter)
        let box = try AES.GCM.seal(
            payload, using: aesKey(fromMaterial: keyMaterial),
            nonce: AES.GCM.Nonce(data: nonceBytes), authenticating: header)
        var tail = Data()
        tail.append(box.ciphertext)
        tail.append(box.tag)
        tail.append(nonceBytes)
        tail.append(contentsOf: [UInt8(ivLength), keyIndex])
        var out = header
        out.append(isAnnexB(codec) ? escapeRbsp(tail) : tail)
        return out
    }

    /// What a receiver reads off a frame BEFORE it authenticates it.
    struct Parsed {
        let header: Data
        let ciphertextAndTag: Data
        let iv: Data
        let keyIndex: UInt8
        let ivSsrc: UInt32
        let counter: UInt32
    }

    /// Parse a frame the P12 way: unescape the body first (H.264/H.265), THEN read the trailer and
    /// the IV from the unescaped tail. `counter = (IV word 2 - IV word 3) mod 2^32`.
    static func parse(wire: Data, codec: String, isKeyFrame: Bool, headerLength: Int) throws -> Parsed {
        guard wire.count >= headerLength else { throw RefError.tooShort }
        let header = Data(wire.prefix(headerLength))
        var body = Data(wire.dropFirst(headerLength))
        if isAnnexB(codec) { body = unescapeRbsp(body) }
        guard body.count >= tagLength + ivLength + trailerLength else { throw RefError.tooShort }
        let trailerStart = body.count - trailerLength
        guard Int(body[body.startIndex + trailerStart]) == ivLength else { throw RefError.badIvLength }
        let keyIndex = body[body.startIndex + trailerStart + 1]
        let ivStart = trailerStart - ivLength
        let ivBytes = Data(body[(body.startIndex + ivStart)..<(body.startIndex + trailerStart)])
        let ciphertextAndTag = Data(body.prefix(ivStart))
        return Parsed(
            header: header, ciphertextAndTag: ciphertextAndTag, iv: ivBytes, keyIndex: keyIndex,
            ivSsrc: word(ivBytes, at: 0), counter: word(ivBytes, at: 4) &- word(ivBytes, at: 8))
    }

    /// Authenticate and decrypt a parsed frame under `keyMaterial`. Returns the whole plaintext
    /// frame (header || payload).
    static func open(_ parsed: Parsed, keyMaterial: Data) throws -> Data {
        guard parsed.ciphertextAndTag.count >= tagLength else { throw RefError.tooShort }
        let tagStart = parsed.ciphertextAndTag.count - tagLength
        let ciphertext = Data(parsed.ciphertextAndTag.prefix(tagStart))
        let tag = Data(parsed.ciphertextAndTag.suffix(tagLength))
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: parsed.iv), ciphertext: ciphertext, tag: tag)
            let payload = try AES.GCM.open(
                box, using: aesKey(fromMaterial: keyMaterial), authenticating: parsed.header)
            var out = parsed.header
            out.append(payload)
            return out
        } catch {
            throw RefError.authenticationFailed
        }
    }
}

/// The P12 receiver replay window of one participant (`ParticipantKeyHandler`), WIRE_SPEC §11.3:
/// a sliding bitmap of W = 256 frames per `ivSsrc`, at most 64 streams, a reflection guard on the
/// handler's local send ssrcs, and window garbage collection tied to the key ring.
final class ReplayHandlerReference {

    enum Verdict: String {
        case ok
        case duplicate
        case tooOld = "too_old"
        case reflected
        case cap
        case decryptFailed = "decrypt_failed"
        case missingKey = "missing_key"
    }

    static let windowSize = 256
    static let maxStreams = 64

    private struct Window {
        var top: UInt32
        /// `seen[d]` is true when counter `top - d` was accepted.
        var seen: [Bool]
        var slots: Set<Int>
    }

    private var windows: [UInt32: Window] = [:]
    private var ring: [Int: Data] = [:]
    let localSendSsrcs: Set<UInt32>

    init(localSendSsrcs: Set<UInt32> = []) {
        self.localSendSsrcs = localSendSsrcs
    }

    var windowCount: Int { windows.count }

    /// `SetKeyFromMaterial` (§3.5): an IDENTICAL key at the slot is a no-op (resetting would
    /// re-open replay); a DIFFERENT one clears the slot from every window and erases the windows
    /// left with no slot (every frame they accepted was sealed under a key no longer installed).
    func install(key: Data, slot: Int) {
        if let existing = ring[slot], existing == key { return }
        ring[slot] = key
        for (ssrc, var window) in windows {
            window.slots.remove(slot)
            if window.slots.isEmpty {
                windows.removeValue(forKey: ssrc)
            } else {
                windows[ssrc] = window
            }
        }
    }

    /// Receive one frame: key lookup -> reflection/duplicate/too-old pre-check -> AEAD -> commit.
    func receive(wire: Data, codec: String, isKeyFrame: Bool, unencryptedBytes: Int) -> Verdict {
        guard let parsed = try? FrameCryptoKatReference.parse(
            wire: wire, codec: codec, isKeyFrame: isKeyFrame, headerLength: unencryptedBytes) else {
            return .decryptFailed
        }
        let slot = Int(parsed.keyIndex)
        guard let key = ring[slot] else { return .missingKey }
        if let refused = preCheck(ssrc: parsed.ivSsrc, counter: parsed.counter) { return refused }
        guard (try? FrameCryptoKatReference.open(parsed, keyMaterial: key)) != nil else {
            return .decryptFailed
        }
        return commit(ssrc: parsed.ivSsrc, counter: parsed.counter, slot: slot)
    }

    private func preCheck(ssrc: UInt32, counter: UInt32) -> Verdict? {
        if localSendSsrcs.contains(ssrc) { return .reflected }
        guard let window = windows[ssrc] else { return nil }
        if counter > window.top { return nil }
        let distance = Int(window.top - counter)
        if distance >= Self.windowSize { return .tooOld }
        if window.seen[distance] { return .duplicate }
        return nil
    }

    private func commit(ssrc: UInt32, counter: UInt32, slot: Int) -> Verdict {
        guard var window = windows[ssrc] else {
            if windows.count >= Self.maxStreams { return .cap }
            var seen = [Bool](repeating: false, count: Self.windowSize)
            seen[0] = true
            windows[ssrc] = Window(top: counter, seen: seen, slots: [slot])
            return .ok
        }
        if counter > window.top {
            let shift = Int(counter - window.top)
            if shift >= Self.windowSize {
                window.seen = [Bool](repeating: false, count: Self.windowSize)
            } else {
                var shifted = [Bool](repeating: false, count: Self.windowSize)
                for i in shift..<Self.windowSize { shifted[i] = window.seen[i - shift] }
                window.seen = shifted
            }
            window.seen[0] = true
            window.top = counter
        } else {
            window.seen[Int(window.top - counter)] = true
        }
        window.slots.insert(slot)
        windows[ssrc] = window
        return .ok
    }
}

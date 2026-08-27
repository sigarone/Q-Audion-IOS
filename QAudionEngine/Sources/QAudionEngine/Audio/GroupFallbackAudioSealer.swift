import Foundation

/// W-GRPFALLBACKAUDIO-IOS (2026-08-27) — AES-256-GCM seal/open for one
/// directed leg of the group-call SFU-outage fallback audio path.
///
/// This is a standalone extraction of the EXACT byte scheme
/// `QAudionEngine.processOutgoingAudio`/`processIncomingAudio` already run
/// under `useAdaptivePadding = true` (the "AdaptivePaddingController-
/// compatible" mode that path uses for Android-peer 1:1 calls — see that
/// file's W479 comments) — same raw-session-key AES-256-GCM, same 2-byte
/// big-endian length header, same fixed-size random-tail padding, same
/// `AeadCipher`/`FrameEncoder` building blocks. It does NOT reuse
/// `QAudionEngine` itself: that class carries a full ratchet/session-manager
/// state machine (`SessionManager`, `.initialized`/`.sessionActive`
/// transitions, CallKit-oriented lifecycle) that has nothing to do with a
/// group-call peer's fallback slot, and instantiating one per roster member
/// just to reach one private branch would be a much larger, harder-to-audit
/// surface than the ~40 lines of framing logic this class actually needs.
/// `AeadCipher` (raw AES-256-GCM) and `FrameEncoder` (the wire frame
/// serializer already proven byte-compatible with Android's relay format,
/// see `QAudionEngine.processIncomingAudio`'s `FrameEncoder.isValid` /
/// `WireRelayFrameCodec.decode` dual-detection) ARE reused directly — no
/// crypto primitive here is hand-rolled.
///
/// **Cross-platform contract** — mirrors Desktop's `AdaptivePaddingController`
/// (`qaudion-desktop/src/main/calling/AdaptivePaddingController.ts`, itself a
/// TypeScript port of Android's `AdaptivePaddingController.kt`):
///   - Plaintext, always exactly `blockBytes` (120 standard / 256 long):
///     `[0..1] uint16 BE true-Opus-length` + `[2..2+L] Opus frame` +
///     `[2+L..blockBytes] CSPRNG padding`.
///   - AES-256-GCM(plaintext, key = RAW 32-byte pairwise session key, nonce,
///     aad = none). The raw key is used directly — no HKDF layer — because
///     that is what the sender (Desktop's `GroupFallbackAudioSession.sendPcm`
///     → `AdaptivePaddingController.sealAudio(opus, sessionKey)`) does.
///   - A declared length of ZERO is the sender's own block-overflow sentinel
///     (`W-PADOVERFLOW` on every platform this scheme ships on) — route to
///     PLC concealment, never to the Opus decoder.
///
/// **What is NOT byte-identical to Desktop, and why it doesn't need to be**:
/// Desktop derives its outgoing nonce as `[4B random session prefix || 8B
/// seq BE]`; `AeadCipher.encrypt` instead lets CryptoKit generate a fully
/// random 96-bit nonce per call. AES-GCM only requires the (key, nonce) pair
/// never repeat for a given key — both schemes satisfy that — and the nonce
/// travels on the wire as an explicit field either way (`FrameEncoder`
/// serializes it), so the receiver never has to reconstruct it from a
/// convention. Nothing about this difference affects interop.
///
/// **Sequencing**: one instance is TX-only or RX-only, matching
/// `PqcRtpFrameSealer`'s own documented discipline — sharing one instance's
/// counter across both directions of a pairwise leg would let two
/// independent frame streams collide on the same (key, nonce) space. A
/// `GroupCallController` fallback slot owns one instance per (peer,
/// direction).
public final class GroupFallbackAudioSealer: @unchecked Sendable {

    public enum SealError: Error, Equatable {
        case wrongKeyLength(Int)
        case malformedFrame(String)
        case openFailed
    }

    /// The zero-length W-PADOVERFLOW sentinel, decoded. `openAudio` returns
    /// this (rather than throwing) so a caller's normal per-frame loop can
    /// route it straight to PLC concealment exactly like
    /// `QAudionEngine.processIncomingAudio` already does for the 1:1 path.
    public struct OpenResult {
        /// `nil` means "this wire slot carried no audio this frame — the
        /// sender's encoder overshot the block and sent silence-of-declared-
        /// length-zero instead of a differently-sized packet". Call
        /// `OpusCodec.decodePLC()`, never `OpusCodec.decode(_:)`, for this case.
        public let opus: Data?
    }

    private let cipher = AeadCipher()
    private let blockBytes: Int
    private var sequenceNumber: UInt32 = 0

    /// - Parameter blockBytes: the fixed plaintext block size both ends
    ///   negotiated for this call. `AudioConstants.blockBytesStandard` (120)
    ///   unless the long-audio profile was negotiated — see
    ///   `AudioConstants.blockBytesLong` (256). Group-call fallback audio has
    ///   no profile negotiation path of its own (there is no per-call
    ///   capability exchange for the pairwise QUAD leg beyond the bare OFFER/
    ///   ACCEPT), so this always seals/opens at the STANDARD block — matching
    ///   Desktop's `GroupFallbackAudioSession` constructor, which likewise
    ///   takes no explicit profile override at its own call site and so
    ///   defaults to the platform's standard block.
    public init(blockBytes: Int = AudioConstants.blockBytesStandard) {
        self.blockBytes = blockBytes
    }

    /// Seal one Opus frame for the wire. `sessionKey` is the RAW 32-byte
    /// pairwise secret (no HKDF) — see the class kdoc.
    public func sealAudio(opus: Data, sessionKey: Data) throws -> Data {
        guard sessionKey.count == CryptoConstants.keySizeBytes else {
            throw SealError.wrongKeyLength(sessionKey.count)
        }
        let headerBytes = AudioConstants.lengthHeaderBytes
        let budget = blockBytes - headerBytes
        // W-PADOVERFLOW parity — an oversized frame degrades to ONE frame of
        // declared-silence rather than changing the packet size or dropping
        // it; see `QAudionEngine.processOutgoingAudio`'s own kdoc for the
        // full anti-traffic-analysis rationale this mirrors.
        let overflow = opus.count > budget
        let bodyLen = overflow ? 0 : opus.count

        var padded = Data(capacity: blockBytes)
        padded.append(UInt8((bodyLen >> 8) & 0xFF))
        padded.append(UInt8(bodyLen & 0xFF))
        if bodyLen > 0 { padded.append(opus) }
        let tailLen = blockBytes - headerBytes - bodyLen
        if tailLen > 0 {
            var rng = SystemRandomNumberGenerator()
            padded.append(contentsOf: (0..<tailLen).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        }

        let encrypted = try cipher.encrypt(plaintext: padded, key: sessionKey, associatedData: nil)
        let seq = sequenceNumber
        sequenceNumber &+= 1
        let frame = EncryptedFrame(
            sequenceNumber: seq,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            nonce: encrypted.nonce,
            payload: encrypted.ciphertext,
            tag: encrypted.tag
        )
        return FrameEncoder.serialize(frame)
    }

    /// Open one sealed wire frame. Throws on a truncated/undecodable frame
    /// or an AEAD auth failure (wrong key, corrupted/forged ciphertext,
    /// mismatched session — all indistinguishable to the caller, matching
    /// `PqcRtpFrameSealer.open`'s posture); returns normally (never throws)
    /// for the W-PADOVERFLOW zero-length sentinel — see `OpenResult`.
    public func openAudio(wire: Data, sessionKey: Data) throws -> OpenResult {
        guard sessionKey.count == CryptoConstants.keySizeBytes else {
            throw SealError.wrongKeyLength(sessionKey.count)
        }
        let frame: EncryptedFrame
        if FrameEncoder.isValid(wire) {
            frame = try FrameEncoder.deserialize(wire)
        } else {
            frame = try WireRelayFrameCodec.decode(wire).frame
        }
        let cipherOutput = AeadCipher.CipherOutput(nonce: frame.nonce, ciphertext: frame.payload, tag: frame.tag)
        let padded: Data
        do {
            padded = try cipher.decrypt(cipherOutput: cipherOutput, key: sessionKey, associatedData: nil)
        } catch {
            throw SealError.openFailed
        }
        let headerBytes = AudioConstants.lengthHeaderBytes
        guard padded.count >= headerBytes else {
            throw SealError.malformedFrame("padded body shorter than length header: \(padded.count)")
        }
        let base = padded.startIndex
        let len = (Int(padded[base]) << 8) | Int(padded[base + 1])
        guard len >= 0, headerBytes + len <= padded.count else {
            throw SealError.malformedFrame("declared length \(len) exceeds padded capacity \(padded.count)")
        }
        guard len > 0 else {
            return OpenResult(opus: nil)
        }
        let opusBytes = padded.subdata(in: (base + headerBytes)..<(base + headerBytes + len))
        return OpenResult(opus: opusBytes)
    }
}

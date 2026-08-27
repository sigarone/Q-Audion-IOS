import Foundation

/// W-GRPFALLBACKAUDIO-IOS (2026-08-27, rewired to W-GRPAUDIOKEY) — AES-256-GCM
/// seal/open for the group-call SFU-outage fallback audio path (QUAD
/// `AUDIO_DATA`, opcode 0x06).
///
/// Originally sealed under a raw pairwise ML-KEM-1024 session key
/// (`GroupCallController.deriveFallbackSessionKey`, one handshake per peer).
/// That mesh is retired: keys now come from `GroupSenderKey`'s W-GRPAUDIOKEY
/// derivations (`deriveAudioSessionKey`/`deriveAudioFrameKey`), a pure local
/// HKDF over the SAME `SK_0`/`CK_0` this codebase already redistributes to
/// every group member for the pre-existing WS-relay-mesh path and the
/// LiveKit SFU media key — see that extension's own kdoc for the full
/// rationale and the cross-platform KAT vectors this matches byte-for-byte
/// (`group-audio-kat.json` / `GroupAudioSessionKeyKatTests`). Establishing a
/// session now costs zero handshake round-trips and zero new network
/// messages, and seals to ONE broadcast ciphertext per frame instead of one
/// independent ciphertext per peer.
///
/// **What stays the same as before**: the plaintext padded-block envelope
/// (`[0..1] uint16 BE true-Opus-length` + `[2..2+L] Opus frame` +
/// `[2+L..blockBytes] CSPRNG padding`, W-PADOVERFLOW zero-length sentinel on
/// overflow) — this is the EXACT byte scheme `QAudionEngine.processOutgoingAudio`/
/// `processIncomingAudio` already run under `useAdaptivePadding = true`, and
/// is reused here verbatim, unchanged by the key-derivation swap.
///
/// **What changed**: the AEAD call now goes through `GroupSenderKey
/// .aesGcmEncrypt`/`aesGcmDecrypt` (already-reused, already-cross-platform-
/// verified AES-256-GCM helpers) under a per-FRAME key (`frame_key_n`, cheap
/// forward-secrecy hardening — no ordering dependency, a good fit for lossy/
/// out-of-order real-time audio) with a deterministic nonce
/// (`random(4) || BE64(frame_counter)`, fixed random prefix per epoch) and an
/// explicit binary AAD binding `(sender_id, epoch_id)` — see
/// `GroupSenderKey`'s W-GRPAUDIOKEY section for the exact layouts. The wire
/// frame itself also changed shape (`GroupSenderKey.packAudioWire`/
/// `unpackAudioWire`, tag 0x04 + explicit `epoch_id` + nonce + length-prefixed
/// ciphertext) — no longer the generic `FrameEncoder`/`WireRelayFrameCodec`
/// 1:1-relay wire this class used before, since `epoch_id` and the
/// (sender_id-bound) frame counter now travel on the wire instead of being
/// implicit in a shared pairwise session.
///
/// **Sequencing**: `sealAudio` is TX-only and stateful (owns the monotonic
/// `frame_counter` for whichever epoch it is currently sealing under —
/// `GroupCallController` calls `resetFrameCounter()` whenever it (re)derives
/// a fresh `audio_key` for a new epoch, per the "never resets except on a
/// fresh audio_key" rule). `openAudio` is RX-side and stateless: the sender's
/// `frame_counter` for THIS frame travels on the wire (packed into the
/// nonce's own trailing 8 bytes), so opening never needs per-sender sealer
/// instance state — the caller resolves which `audio_key` to open under
/// (current epoch, or the previous epoch within its grace window) and this
/// class just runs the derivation + AEAD.
public final class GroupFallbackAudioSealer: @unchecked Sendable {

    public enum SealError: Error, Equatable {
        case wrongKeyLength(Int)
        case malformedFrame(String)
        case openFailed
        case keyUnavailable
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

    private let blockBytes: Int
    /// TX-only: this sealer's own per-epoch monotonic frame counter. Reset
    /// via `resetFrameCounter()` whenever the caller (re)derives a fresh
    /// `audio_key` — see this class's own kdoc.
    private var frameCounter: UInt64 = 0

    /// - Parameter blockBytes: the fixed plaintext block size both ends
    ///   negotiated for this call. `AudioConstants.blockBytesStandard` (120)
    ///   unless the long-audio profile was negotiated — see
    ///   `AudioConstants.blockBytesLong` (256). Group-call fallback audio has
    ///   no profile negotiation path of its own (there is no per-call
    ///   capability exchange for the QUAD leg beyond the bare AUDIO_DATA
    ///   opcode), so this always seals/opens at the STANDARD block.
    public init(blockBytes: Int = AudioConstants.blockBytesStandard) {
        self.blockBytes = blockBytes
    }

    /// Reset the TX frame counter to 0. Call whenever a fresh `audio_key` is
    /// derived for a new epoch — never otherwise (the counter must stay
    /// monotonic within one audio_key's lifetime, see `deriveAudioFrameKey`'s
    /// kdoc).
    public func resetFrameCounter() {
        frameCounter = 0
    }

    /// Seal one Opus frame for the wire under `audioKey` (this epoch's
    /// `GroupSenderKey.deriveAudioSessionKey` output), using and advancing
    /// this sealer's own TX frame counter. `noncePrefix` is the 4-byte
    /// random value fixed for `audioKey`'s epoch lifetime.
    public func sealAudio(opus: Data, audioKey: Data, noncePrefix: Data, epochId: UInt32, senderId: String) throws -> Data {
        guard audioKey.count == GroupSenderKey.audioKeyLen else {
            throw SealError.wrongKeyLength(audioKey.count)
        }
        guard noncePrefix.count == GroupSenderKey.audioNonceRandomLen else {
            throw SealError.malformedFrame("nonce random prefix must be \(GroupSenderKey.audioNonceRandomLen) bytes")
        }
        let counter = frameCounter
        frameCounter &+= 1
        let padded = try Self.pad(opus: opus, blockBytes: blockBytes)
        let frameKey = GroupSenderKey.deriveAudioFrameKey(audioKey: audioKey, frameCounter: counter)
        let nonce = GroupSenderKey.buildAudioNonce(randomPrefix: noncePrefix, frameCounter: counter)
        let aad = GroupSenderKey.buildAudioAd(senderId: senderId, epochId: epochId)
        let ctWithTag = try GroupSenderKey.aesGcmEncrypt(key: frameKey, nonce: nonce, plaintext: padded, aad: aad)
        return try GroupSenderKey.packAudioWire(epochId: epochId, nonce: nonce, ciphertextWithTag: ctWithTag)
    }

    /// Open one sealed wire frame from `senderId`. `resolveAudioKey` is
    /// invoked with the wire's OWN `epoch_id` (never trust a caller-supplied
    /// epoch — always the value actually on the wire, so the AAD the
    /// receiver reconstructs always matches what the sender authenticated)
    /// and must return the `audio_key` to open under for that epoch — the
    /// CURRENT local epoch, or the immediately-previous one while still
    /// within its grace window — or `nil` to reject outright (closes the
    /// replay/downgrade risk an external security review flagged: an older
    /// epoch, or one for which no key is cached, is never accepted). Throws
    /// on a malformed/truncated frame, a rejected epoch
    /// (`.keyUnavailable`), or an AEAD auth failure (wrong key, corrupted/
    /// forged ciphertext, mismatched `sender_id`/`epoch_id` AAD binding —
    /// all indistinguishable to the caller, matching `PqcRtpFrameSealer
    /// .open`'s posture); returns normally (never throws) for the
    /// W-PADOVERFLOW zero-length sentinel — see `OpenResult`.
    public static func openAudio(wire: Data, senderId: String, resolveAudioKey: (UInt32) -> Data?) throws -> OpenResult {
        let parsed = try GroupSenderKey.unpackAudioWire(wire)
        guard let audioKey = resolveAudioKey(parsed.epochId) else {
            throw SealError.keyUnavailable
        }
        guard audioKey.count == GroupSenderKey.audioKeyLen else {
            throw SealError.wrongKeyLength(audioKey.count)
        }
        let frameKey = GroupSenderKey.deriveAudioFrameKey(audioKey: audioKey, frameCounter: parsed.frameCounter)
        let aad = GroupSenderKey.buildAudioAd(senderId: senderId, epochId: parsed.epochId)
        let padded: Data
        do {
            padded = try GroupSenderKey.aesGcmDecrypt(
                key: frameKey, nonce: parsed.nonce, ciphertextWithTag: parsed.ciphertextWithTag, aad: aad)
        } catch {
            throw SealError.openFailed
        }
        return OpenResult(opus: try Self.unpad(padded: padded))
    }

    // MARK: - Padded-block plaintext envelope (unchanged primitive — see class kdoc)

    private static func pad(opus: Data, blockBytes: Int) throws -> Data {
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
        return padded
    }

    private static func unpad(padded: Data) throws -> Data? {
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
            return nil
        }
        return padded.subdata(in: (base + headerBytes)..<(base + headerBytes + len))
    }
}

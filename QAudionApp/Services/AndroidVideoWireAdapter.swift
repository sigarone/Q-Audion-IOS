import Foundation
import QAudionEngine

/// W397 — Android-compatible video wire adapter.
///
/// The W391+W392 path ships PQC-sealed iOS fragments RAW over the
/// WS `video_frame` envelope (mux byte = pure ciphertext). Android's
/// established video wire format is `WireRelayFrameCodec.encodeVideo`
/// which wraps an `EncryptedFrame` (nonce + payload + tag + sequence)
/// inside a mux=0x02 header that ALSO carries the per-fragment
/// metadata (fragIdx, totalFrags, isKey).
///
/// Two design observations:
///   - The iOS `VideoFrameFragmenter` already produces a 7-byte
///     sub-header per fragment carrying frameId, fragIdx, totalFrags,
///     bitrateHint, fragFlags. The existing fragmenter is by-design
///     byte-identical to Android's port (`VideoConstants.kt` says so
///     in its top docstring).
///   - Android's `WireRelayFrameCodec.encodeVideo` adds a SECOND
///     layer of fragmentation metadata at the transport boundary
///     (mux + fragIdx + totalFrags + isKey + EncryptedFrame).
///
/// To keep both ends literally byte-compatible, the iOS app must
/// either send fragments through `WireRelayFrameCodec` OR Android
/// must adopt the iOS-native shape. The pragmatic path (this file)
/// produces the WireRelayFrameCodec shape from an iOS fragment so
/// AppState's WS transport can opt-in via a single boolean.
///
/// Trade-off explicitly noted: the WireRelayFrameCodec format
/// duplicates fragment metadata that's also inside the iOS sub-
/// header. The duplication costs ~6 bytes per fragment but trades
/// for byte-level parity with Android's existing decoder.
///
/// **Verification status:** the format produced here matches the
/// iOS `WireRelayFrameCodec.encodeVideo` byte layout. Cross-platform
/// interop with Android requires a final byte-identical confirmation
/// of Android's `WireRelayFrameCodec.kt` (the iOS port is annotated
/// "MUST stay byte-identical" per the engine docstring, so this is
/// expected to work, but a paired test on real devices is the
/// only definitive check).
public enum AndroidVideoWireAdapter {

    /// The iOS VideoFrameFragmenter sub-header is fixed-size 7 bytes.
    /// Fragments produced by the W391 fragmenter follow this shape:
    /// ```
    ///   [fragFlags(1)][frameId(2)][fragIdx(1)][totalFrags(1)][bitrateHint(2)][nalChunk...]
    /// ```
    /// We re-extract these fields to feed `WireRelayFrameCodec.encodeVideo`.
    public struct ParsedFragment {
        public let fragFlags: UInt8
        public let frameId: UInt16
        public let fragIdx: UInt16
        public let totalFrags: UInt16
        public let bitrateHintKbps: UInt16
        public let nalChunk: Data
        public var isKeyFrame: Bool { (fragFlags & VideoConstants.fragFlagKeyFrame) != 0 }
    }

    /// Parse the iOS sub-header from a fragmenter output. Returns nil
    /// on truncation. The caller passes the raw fragment BEFORE PQC
    /// sealing; if the input is the post-seal envelope it won't parse.
    public static func parseIosFragment(_ fragment: Data) -> ParsedFragment? {
        guard fragment.count >= VideoConstants.videoFragmentHeaderSize else { return nil }
        let s = fragment.startIndex
        let fragFlags = fragment[s]
        let frameId = (UInt16(fragment[s + 1]) << 8) | UInt16(fragment[s + 2])
        let fragIdx = UInt16(fragment[s + 3])
        let totalFrags = UInt16(fragment[s + 4])
        let bitrateHint = (UInt16(fragment[s + 5]) << 8) | UInt16(fragment[s + 6])
        let nalChunk = fragment.subdata(in: (s + VideoConstants.videoFragmentHeaderSize)..<fragment.endIndex)
        return ParsedFragment(
            fragFlags: fragFlags,
            frameId: frameId,
            fragIdx: fragIdx,
            totalFrags: totalFrags,
            bitrateHintKbps: bitrateHint,
            nalChunk: nalChunk)
    }

    /// Sequence-number generator scoped to a single video call. Bumped
    /// per encoded fragment so the receiver can detect packet loss.
    public final class SequenceCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var seq: UInt64 = 0
        public init() {}
        public func next() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let v = seq
            seq &+= 1
            return v
        }
    }

    /// Produce an Android-compatible `video_frame` payload from a PQC-
    /// sealed iOS fragment.
    ///
    /// The PqcRtpFrameSealer output is `nonce(12) || ciphertext || tag(16)`.
    /// We split it into the EncryptedFrame's three slots and wrap via
    /// `WireRelayFrameCodec.encodeVideo`. The fragIdx / totalFrags /
    /// isKey come from the inner iOS sub-header so the receiver can
    /// reassemble identically on either side.
    public static func encodeForAndroid(
        sealedFragment: Data,
        innerFragment: ParsedFragment,
        sequence: UInt64
    ) -> Data? {
        guard sealedFragment.count > 12 + 16 else { return nil }
        let nonce = sealedFragment.subdata(in: sealedFragment.startIndex..<(sealedFragment.startIndex + 12))
        let tag = sealedFragment.suffix(16)
        let payloadStart = sealedFragment.startIndex + 12
        let payloadEnd = sealedFragment.endIndex - 16
        let payload = sealedFragment.subdata(in: payloadStart..<payloadEnd)
        // EncryptedFrame preconditions require payload <= 4096; iOS
        // fragments are <= 1200 + 28 sealing overhead so this is safe.
        let encrypted = EncryptedFrame(
            sequenceNumber: UInt32(truncatingIfNeeded: sequence),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            nonce: nonce,
            payload: payload,
            tag: tag,
            deepfakeScore: nil)
        return WireRelayFrameCodec.encodeVideo(
            encrypted,
            fragIdx: innerFragment.fragIdx,
            totalFrags: innerFragment.totalFrags,
            isKey: innerFragment.isKeyFrame)
    }

    /// Inverse: decode an Android-shape `video_frame` payload back to
    /// the post-seal envelope (`nonce || ciphertext || tag`) the iOS
    /// PqcRtpFrameSealer expects, plus the per-fragment metadata so
    /// the caller can reattach the iOS sub-header before feeding the
    /// existing `acceptInboundFragment` path.
    public static func decodeFromAndroid(_ wire: Data) -> (sealedFragment: Data, fragIdx: UInt16, totalFrags: UInt16, isKey: Bool)? {
        guard let decoded = try? WireRelayFrameCodec.decode(wire) else { return nil }
        guard case .video(let fragIdx, let totalFrags, let isKey) = decoded.kind else { return nil }
        // Recompose the post-seal envelope so the iOS PqcRtpFrameSealer
        // can `open(_:)` it.
        var sealed = Data(capacity: decoded.frame.nonce.count + decoded.frame.payload.count + decoded.frame.tag.count)
        sealed.append(decoded.frame.nonce)
        sealed.append(decoded.frame.payload)
        sealed.append(decoded.frame.tag)
        return (sealed, fragIdx, totalFrags, isKey)
    }
}

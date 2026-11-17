import Foundation
import QAudionEngine

/// W397 — Android-compatible video wire adapter.
///
/// Android never uses `WireRelayFrameCodec` for video. Its video relay
/// transport (`BcryptoWsVideoRelayTransport`) ships `frame` as exactly
/// `base64(PqcRtpFrameSealer.seal(rawFragment))` — no outer wrapper — with
/// `frag_idx`/`total_frags`/`is_key_frame` as TOP-LEVEL WS JSON fields.
/// `AppState.startVideoPipeline` / `registerInboundVideoHandler` send and
/// receive that shape directly (see `BCryptoWebSocketClient.sendVideoFrame`).
///
/// `parseIosFragment` below parses the iOS `VideoFrameFragmenter`
/// sub-header to read the `fragIdx`/`totalFrags`/`isKeyFrame` metadata for
/// the WS envelope's top-level fields — it does not wrap or alter the
/// sealed bytes.
public enum AndroidVideoWireAdapter {

    /// The iOS VideoFrameFragmenter sub-header is fixed-size 7 bytes.
    /// Fragments produced by the W391 fragmenter follow this shape:
    /// ```
    ///   [fragFlags(1)][frameId(2)][fragIdx(1)][totalFrags(1)][bitrateHint(2)][nalChunk...]
    /// ```
    /// We re-extract these fields to populate the WS envelope's top-level
    /// `frag_idx`/`total_frags`/`is_key_frame` JSON fields (see
    /// `BCryptoWebSocketClient.sendVideoFrame`).
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

}

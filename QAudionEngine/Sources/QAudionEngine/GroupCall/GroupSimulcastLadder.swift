import Foundation

/// The three simulcast encodings of the group publisher (spec §4.4): rid, downscale, bitrate
/// and frame rate of the l / m / h layers. Pure data (no WebRTC import) so the invariants the
/// encoder needs are unit-testable on their own; `GroupPublisherPeer` turns it into the
/// `RTCRtpEncodingParameters` of the video transceiver.
///
/// Why every layer has the SAME frame rate: on iOS the VP8 encoder is libvpx used directly
/// (`HevcPreferredVideoEncoderFactory` returns the native builder unwrapped, there is no
/// simulcast adapter in front of it as there is on Android). libvpx's `InitEncode` refuses a
/// simulcast configuration whose streams differ in `maxFramerate`
/// (`SimulcastUtility::ValidSimulcastParameters`, error -15
/// `WEBRTC_VIDEO_CODEC_ERR_SIMULCAST_PARAMETERS_NOT_SUPPORTED`), and without an encoder no frame
/// is ever sent. A ladder of 15 / 20 / 25 fps did exactly that (iPhone 1.0.1205, group call
/// 190cb052: camera on, `frames=0` on every heartbeat). The lower rates the l / m layers were
/// meant to have come, if wanted, from the temporal layers (L1T3), not from a per-layer rate.
public enum GroupSimulcastLadder {

    public struct Layer: Equatable, Sendable {
        public let rid: String
        /// `scaleResolutionDownBy`: 4 = a quarter of the width and height.
        public let scale: Double
        public let fps: Int
        public let maxBps: Int
        public let temporalLayers: Int

        public init(rid: String, scale: Double, fps: Int, maxBps: Int, temporalLayers: Int) {
            self.rid = rid
            self.scale = scale
            self.fps = fps
            self.maxBps = maxBps
            self.temporalLayers = temporalLayers
        }
    }

    /// The one frame rate of all three layers.
    public static let fps = 25
    /// Every layer carries the same number of temporal layers (libvpx requires it too).
    public static let temporalLayers = 3

    /// Ascending quality: l, m, h (the `rid_order` Janus is told is "lmh").
    public static let layers: [Layer] = [
        Layer(rid: "l", scale: 4, fps: fps, maxBps: 150_000, temporalLayers: temporalLayers),
        Layer(rid: "m", scale: 2, fps: fps, maxBps: 450_000, temporalLayers: temporalLayers),
        Layer(rid: "h", scale: 1, fps: fps, maxBps: 1_200_000, temporalLayers: temporalLayers),
    ]

    /// The part of libvpx's `ValidSimulcastParameters` that depends on the ladder and not on the
    /// capture size: the downscale never grows from a layer to the next (so the widths do not
    /// shrink), the frame rate is identical on every layer and so is the number of temporal
    /// layers. A ladder for which this is false makes `InitEncode` fail with -15.
    public static func isAcceptedByLibvpx(_ ladder: [Layer]) -> Bool {
        guard let first = ladder.first else { return false }
        for (previous, layer) in zip(ladder, ladder.dropFirst()) {
            if layer.scale > previous.scale { return false }
            if layer.fps != previous.fps { return false }
            if layer.temporalLayers != previous.temporalLayers { return false }
        }
        return first.fps > 0
    }
}

import Foundation

/// Constants for Q-AUDION encrypted video pipeline. Direct port of
/// Android's `qaudion-engine/.../video/VideoConstants.kt` — every value
/// MUST stay byte-identical to keep iOS↔Android video calls interoperable.
///
/// Video frames are fragmented into transport-sized chunks (~1200 bytes)
/// to stay under UDP MTU limits and allow per-fragment encryption.
public enum VideoConstants {

    // MARK: - Fragment Configuration

    /// Maximum payload per video fragment (stays under 1280-byte UDP MTU with overhead).
    public static let maxFragmentPayload: Int = 1200

    /// Size of the video sub-header prepended to each fragment's plaintext.
    public static let videoFragmentHeaderSize: Int = 7

    /// Timeout for incomplete frame reassembly (ms).
    public static let fragmentReassemblyTimeoutMs: Int64 = 150

    /// Maximum fragments per video frame (uint8 range).
    public static let maxFragmentsPerFrame: Int = 255

    // MARK: - EncryptedFrame Flag

    /// Flag bit 3 in EncryptedFrame.flags: indicates this frame is a video fragment.
    public static let flagIsVideoFrame: UInt8 = 0x08

    // MARK: - Video Fragment Sub-Header Flags (inside encrypted payload)

    /// Fragment flag bit 0: this fragment belongs to an I-frame (keyframe).
    public static let fragFlagKeyFrame: UInt8 = 0x01

    /// Fragment flag bit 1: this is the last fragment of the video frame.
    public static let fragFlagLastFragment: UInt8 = 0x02

    // MARK: - Video Codec Configuration

    public static let defaultVideoWidth: Int = 1280   // 720p
    public static let defaultVideoHeight: Int = 720
    public static let defaultVideoFps: Int = 24
    public static let defaultVideoBitrateBps: Int = 800_000
    public static let minVideoBitrateBps: Int = 200_000
    public static let maxVideoBitrateBps: Int = 2_500_000
    public static let keyframeIntervalSec: Int = 2
    /// H.264 Baseline profile string — kept for parity. iOS uses HEVC by
    /// default per the engine's `videoCodec` setting; this constant maps
    /// to the cross-codec "low complexity" preset.
    public static let h264Profile: String = "Baseline"

    // MARK: - Adaptive Bitrate

    public static let abrSampleIntervalMs: Int64 = 2000
    public static let abrLossIncreaseThreshold: Float = 0.02
    public static let abrLossDecreaseThreshold: Float = 0.05
    public static let abrIncreaseStepBps: Int = 50_000
    public static let abrDecreaseFactor: Float = 0.7
    public static let abrHighLatencyThresholdMs: Int = 200
    public static let abrHighJitterThresholdMs: Double = 100.0

    // MARK: - Resolution Stepping

    public static let resolutionStepDownThresholdBps: Int = 400_000
    public static let resolutionStepUpThresholdBps: Int = 600_000
    public static let resolutionChangeSustainMs: Int64 = 5000

    // MARK: - Transport

    public static let defaultVideoBandwidthKbps: Int = 1500

    /// WebSocket message type for video frames.
    public static let wsMsgTypeVideoFrame: String = "video_frame"
}

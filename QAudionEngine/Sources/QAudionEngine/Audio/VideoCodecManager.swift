import Foundation
#if canImport(VideoToolbox)
import VideoToolbox
#endif

/// Manages video codec selection: HEVC (H.265) primary, H.264 fallback.
///
/// HEVC provides ~50% better compression than H.264 at the same quality,
/// critical for encrypted video where every byte is padded + encrypted.
/// All iPhones since iPhone 7 (A10+) support hardware HEVC encode/decode.
public final class VideoCodecManager {

    public enum Codec: String {
        case hevc = "HEVC"     // Primary: H.265 / HEVC
        case h264 = "H.264"   // Fallback: H.264 / AVC

        public var profileLevel: String {
            switch self {
            case .hevc: return "HEVC Main 4.1"
            case .h264: return "H.264 High 4.1"
            }
        }

        public var mimeType: String {
            switch self {
            case .hevc: return "video/hevc"
            case .h264: return "video/avc"
            }
        }

        /// Target bitrate in kbps for 720p video
        public var targetBitrateKbps: Int {
            switch self {
            case .hevc: return 1500  // HEVC needs ~50% less bandwidth
            case .h264: return 2500  // H.264 needs more bandwidth
            }
        }
    }

    public private(set) var activeCodec: Codec = .hevc
    public private(set) var isHardwareAccelerated: Bool = false

    public init() {
        activeCodec = selectBestCodec()
    }

    /// Select the best available codec based on hardware support.
    /// HEVC is preferred; falls back to H.264 if HEVC hardware encoding unavailable.
    public func selectBestCodec() -> Codec {
        #if canImport(VideoToolbox)
        // Check HEVC hardware encoder support
        if isHEVCHardwareEncoderAvailable() {
            isHardwareAccelerated = true
            return .hevc
        }
        // H.264 hardware is available on all iOS devices
        isHardwareAccelerated = true
        return .h264
        #else
        // macOS CI / non-VideoToolbox: default HEVC (software)
        isHardwareAccelerated = false
        return .hevc
        #endif
    }

    /// Check if HEVC hardware encoder is available (iPhone 7+ / A10 Fusion+)
    private func isHEVCHardwareEncoderAvailable() -> Bool {
        #if canImport(VideoToolbox)
        // On iOS, VTIsHardwareDecodeSupported checks for hardware support
        if #available(iOS 11.0, *) {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        }
        return false
        #else
        return false
        #endif
    }

    /// Force a specific codec (e.g., for interop with devices that don't support HEVC)
    public func forceCodec(_ codec: Codec) {
        activeCodec = codec
        #if canImport(VideoToolbox)
        isHardwareAccelerated = true  // Both H.264 and HEVC have HW support on iOS
        #endif
    }

    /// Get codec info for security badge display
    public func getCodecInfo() -> (name: String, bitrate: Int, hardware: Bool) {
        return (activeCodec.rawValue, activeCodec.targetBitrateKbps, isHardwareAccelerated)
    }

    /// Negotiate codec with remote peer.
    /// Both sides advertise supported codecs; choose best mutual option.
    public func negotiateCodec(remoteSupported: [String]) -> Codec {
        // Prefer HEVC if both sides support it
        if remoteSupported.contains("HEVC") && activeCodec == .hevc {
            return .hevc
        }
        // Fallback to H.264 (universal support)
        if remoteSupported.contains("H.264") {
            forceCodec(.h264)
            return .h264
        }
        // Default: use our selected codec
        return activeCodec
    }
}

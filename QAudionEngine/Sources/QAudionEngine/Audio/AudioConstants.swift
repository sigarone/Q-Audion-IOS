import Foundation

public enum AudioConstants {
    public static let sampleRate = 48000
    public static let channels = 1
    public static let bitsPerSample = 16
    public static let frameDurationMs = 20
    public static let samplesPerFrame = (sampleRate * frameDurationMs) / 1000
    public static let bytesPerFrame = samplesPerFrame * (bitsPerSample / 8) * channels
    // W523: 32 kbps CBR — matches Android (`OpusConfig.bitrate=32000`)
    // and firmware (`QA_OPUS_BITRATE_DEFAULT=32000`). The whole
    // ecosystem ships frames of the same on-wire size for traffic-
    // analysis resistance — bumping iOS to 64 kbps would have broken
    // that property (different frame sizes ⇒ device fingerprintable).
    public static let opusBitrate = 32000
    public static let jitterBufferFramesP2P = 3
    public static let jitterBufferFramesWsRelay = 8
    public static let jitterBufferFramesSignalRelay = 150
    public static let playbackRingBufferFrames = 10
    public static let comfortNoiseAmplitude: Int16 = 100
}

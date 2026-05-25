import Foundation

public enum AudioConstants {
    public static let sampleRate = 48000
    public static let channels = 1
    public static let bitsPerSample = 16
    public static let frameDurationMs = 20
    public static let samplesPerFrame = (sampleRate * frameDurationMs) / 1000
    public static let bytesPerFrame = samplesPerFrame * (bitsPerSample / 8) * channels
    public static let opusBitrate = 64000
    public static let jitterBufferFramesP2P = 3
    public static let jitterBufferFramesWsRelay = 8
    public static let jitterBufferFramesSignalRelay = 150
    public static let playbackRingBufferFrames = 10
    public static let comfortNoiseAmplitude: Int16 = 100
}

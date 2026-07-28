import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class AudioPlayback {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var isRunning = false

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        // force-unwrap safe: only nil for an invalid sample-rate/channel
        // combo; AudioConstants.sampleRate/channels are fixed (48kHz mono).
        // swiftlint:disable:next force_unwrapping
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(AudioConstants.sampleRate),
            channels: AVAudioChannelCount(AudioConstants.channels), interleaved: true)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: fmt)
        try engine.start(); player.play()
        self.engine = engine; self.playerNode = player; self.format = fmt; isRunning = true
    }

    public func playFrame(_ pcmData: Data) {
        guard isRunning, let player = playerNode, let fmt = format else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(AudioConstants.samplesPerFrame)) else { return }
        buffer.frameLength = AVAudioFrameCount(AudioConstants.samplesPerFrame)
        pcmData.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, src, min(pcmData.count, AudioConstants.bytesPerFrame))
            }
        }
        player.scheduleBuffer(buffer)
    }

    public func stop() {
        playerNode?.stop(); engine?.stop(); engine = nil; playerNode = nil; format = nil; isRunning = false
    }
    public var isPlaying: Bool { isRunning }
}
#endif

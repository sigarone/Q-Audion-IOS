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
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(AudioConstants.sampleRate),
            // swiftlint:disable:next force_unwrapping
            channels: AVAudioChannelCount(AudioConstants.channels), interleaved: true)!
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: fmt)
        try engine.start(); player.play()
        self.engine = engine; self.playerNode = player; self.format = fmt; isRunning = true
    }

    /// W-LONGAUDIO (2026-08-10) — sized from THE FRAME, not from the encode
    /// constant.
    ///
    /// This class is not on the live 1:1 path any more (single-engine fix: the
    /// player node moved onto `AudioCapture`'s engine, and `CallService` only
    /// ever constructs and stops this one — grep for `audioPlayback?.playFrame`
    /// returns nothing). It is fixed anyway because the old shape is a trap
    /// waiting for whoever rewires it: `frameCapacity` was pinned to 960 samples
    /// and the `memcpy` was clamped to 1920 bytes, so a 60 ms frame would have
    /// been silently TRUNCATED to its first third — two thirds of every word
    /// dropped, at the right rate, with nothing logged.
    ///
    /// The length is arithmetic, not a guess: decoded PCM here is Int16 mono, so
    /// samples = bytes / 2.
    public func playFrame(_ pcmData: Data) {
        guard isRunning, let player = playerNode, let fmt = format else { return }
        let samples = pcmData.count / 2
        guard samples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                            frameCapacity: AVAudioFrameCount(samples)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples)
        pcmData.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, src, samples * 2)
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

import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class AudioCapture {
    public var onFrame: ((Data) -> Void)?
    private var engine: AVAudioEngine?
    private var isRunning = false

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(AudioConstants.sampleRate),
            channels: AVAudioChannelCount(AudioConstants.channels), interleaved: true)!
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(AudioConstants.samplesPerFrame), format: format) { [weak self] buffer, _ in
            guard let self, let int16Data = buffer.int16ChannelData else { return }
            let data = Data(bytes: int16Data[0], count: Int(buffer.frameLength) * 2)
            self.onFrame?(data)
        }
        try engine.start()
        self.engine = engine; isRunning = true
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil; isRunning = false
    }
    public var isCapturing: Bool { isRunning }
}
#endif

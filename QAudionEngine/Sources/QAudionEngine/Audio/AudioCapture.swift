import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class AudioCapture {
    public var onFrame: ((Data) -> Void)?
    private var engine: AVAudioEngine?
    private var isRunning = false
    private let audioPipeline: AudioProcessingPipeline

    /// Initialize with an optional audio processing pipeline.
    /// When provided, the pipeline configures AVAudioSession for VoIP and
    /// enables Apple's Voice Processing I/O (hardware AEC, NS, AGC) on the
    /// input node before capturing begins.
    public init(audioPipeline: AudioProcessingPipeline? = nil) {
        self.audioPipeline = audioPipeline ?? AudioProcessingPipeline()
    }

    public func start() throws {
        guard !isRunning else { return }

        // 1. Configure AVAudioSession for VoIP (hardware AEC, AGC, NS)
        try audioPipeline.configureForVoIP()

        // 2. Create the audio engine
        let engine = AVAudioEngine()

        // 3. Enable Voice Processing I/O on the input node BEFORE installing the tap.
        //    This activates Apple's full VoIP DSP chain:
        //    - Echo cancellation (AEC)
        //    - Noise suppression (NS)
        //    - Automatic gain control (AGC)
        try audioPipeline.enableVoiceProcessing(on: engine)

        // 4. Install the input tap to capture PCM frames
        let inputNode = engine.inputNode
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AudioConstants.sampleRate),
            channels: AVAudioChannelCount(AudioConstants.channels),
            interleaved: true
        )!

        let pipeline = self.audioPipeline
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(AudioConstants.samplesPerFrame), format: format) { [weak self] buffer, _ in
            guard let self, let int16Data = buffer.int16ChannelData else { return }
            var data = Data(bytes: int16Data[0], count: Int(buffer.frameLength) * 2)
            // Apply supplemental software noise reduction on top of hardware DSP
            data = pipeline.applyNoiseReduction(pcmFrame: data)
            self.onFrame?(data)
        }

        // 5. Start the engine
        try engine.start()
        self.engine = engine
        isRunning = true
    }

    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        if let engine = engine {
            audioPipeline.disableVoiceProcessing(on: engine)
        }
        engine?.stop()
        engine = nil
        audioPipeline.deactivateSession()
        isRunning = false
    }

    public var isCapturing: Bool { isRunning }

    /// Access the audio processing pipeline for stats or configuration changes.
    public var processingPipeline: AudioProcessingPipeline { audioPipeline }
}
#endif

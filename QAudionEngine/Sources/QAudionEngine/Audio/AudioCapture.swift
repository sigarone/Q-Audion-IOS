import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class AudioCapture {
    public var onFrame: ((Data) -> Void)?
    private var engine: AVAudioEngine?
    private var isRunning = false
    private let audioPipeline: AudioProcessingPipeline
    // W475 — re-chunking accumulator. `installTap` delivers buffers of
    // an arbitrary size; the Opus encoder needs EXACTLY bytesPerFrame.
    // Touched only on the single tap-callback thread, so no lock.
    private var pcmAccumulator = Data()
    // M-12 — AVAudioSession interruption (phone call, Siri, alarm)
    // handling. Without this the capture engine stays dead after an
    // interruption ends, silently killing call audio.
    private var interruptionObserver: NSObjectProtocol?
    private var wasInterrupted = false

    /// Initialize with an optional audio processing pipeline.
    /// When provided, the pipeline configures AVAudioSession for VoIP and
    /// enables Apple's Voice Processing I/O (hardware AEC, NS, AGC) on the
    /// input node before capturing begins.
    public init(audioPipeline: AudioProcessingPipeline? = nil) {
        self.audioPipeline = audioPipeline ?? AudioProcessingPipeline()
    }

    public func start() throws {
        guard !isRunning else { return }
        // W475 — start each capture session with an empty re-chunk
        // accumulator so a stale partial frame from a prior call or a
        // pre-interruption session can't desync the frame boundaries.
        pcmAccumulator = Data()

        // 1. Configure AVAudioSession for VoIP (hardware AEC, AGC, NS)
        if !audioPipeline.isActive {
            try audioPipeline.configureForVoIP()
        }

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
            let raw = Data(bytes: int16Data[0], count: Int(buffer.frameLength) * 2)
            // W475 — re-chunk into EXACT bytesPerFrame frames. `installTap`'s
            // bufferSize is only a hint, and VoiceProcessing I/O ties the tap
            // buffer to the hardware I/O duration — so `buffer.frameLength`
            // is an arbitrary size, frequently far larger than the 960
            // samples Opus requires. A mis-sized frame made OpusCodec.encode
            // return nil; QAudionEngine.processOutgoingAudio then fell back
            // to encrypting the RAW PCM, and once that raw buffer exceeded
            // maxPayloadSize (4096 B / >2048 samples — common) the
            // `payload.count <= maxPayloadSize` precondition in
            // EncryptedFrame.init trapped (SIGTRAP), crashing the call the
            // instant capture started on answer. It also killed TX outright:
            // Opus never once encoded a frame. Re-chunking guarantees every
            // onFrame delivery is exactly bytesPerFrame.
            self.pcmAccumulator.append(raw)
            let frameBytes = AudioConstants.bytesPerFrame
            var consumed = 0
            while self.pcmAccumulator.count - consumed >= frameBytes {
                let chunk = self.pcmAccumulator.subdata(in: consumed ..< consumed + frameBytes)
                consumed += frameBytes
                // Supplemental software noise reduction on top of HW DSP.
                let processed = pipeline.applyNoiseReduction(pcmFrame: chunk)
                self.onFrame?(processed)
            }
            if consumed > 0 {
                self.pcmAccumulator = consumed < self.pcmAccumulator.count
                    ? self.pcmAccumulator.subdata(in: consumed ..< self.pcmAccumulator.count)
                    : Data()
            }
        }

        // 5. Start the engine
        try engine.start()
        self.engine = engine
        isRunning = true

        // 6. M-12 — observe AVAudioSession interruptions so we can
        //    pause on .began and resume on .ended (.shouldResume).
        registerInterruptionObserver()
    }

    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // OS seized the audio session (phone call / Siri / alarm).
            // Tear down tap + engine and report not-running so the UI
            // reflects dead capture instead of a silent one-sided call.
            // Do NOT deactivate the session — the OS owns it for the
            // duration of the interruption.
            wasInterrupted = true
            engine?.inputNode.removeTap(onBus: 0)
            if let engine = engine {
                audioPipeline.disableVoiceProcessing(on: engine)
            }
            engine?.stop()
            engine = nil
            isRunning = false
        case .ended:
            guard wasInterrupted else { return }
            wasInterrupted = false
            var shouldResume = false
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                shouldResume = opts.contains(.shouldResume)
            }
            guard shouldResume else { return }
            // start() reconfigures + reactivates the session and rebuilds
            // the engine/tap. The observer is still registered (only
            // stop()/deinit remove it) so start()'s register call no-ops.
            do {
                try start()
            } catch {
                let edesc: String = error.localizedDescription
                let line: String = "[AudioCapture] resume after interruption failed: " + edesc
                print(line)
            }
        @unknown default:
            break
        }
    }

    public func stop() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        if let engine = engine {
            audioPipeline.disableVoiceProcessing(on: engine)
        }
        engine?.stop()
        engine = nil
        audioPipeline.deactivateSession()
        isRunning = false
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public var isCapturing: Bool { isRunning }

    /// Access the audio processing pipeline for stats or configuration changes.
    public var processingPipeline: AudioProcessingPipeline { audioPipeline }
}
#endif

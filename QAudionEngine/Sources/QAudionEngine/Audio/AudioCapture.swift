import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class AudioCapture {
    public var onFrame: ((Data) -> Void)?
    private var engine: AVAudioEngine?
    // SINGLE-ENGINE FIX — playback player node hosted on the SAME AVAudioEngine
    // as the capture tap. Two SEPARATE AVAudioEngine instances on one
    // AVAudioSession both instantiate the single hardware RemoteIO / Voice-
    // Processing I/O unit; starting the second one tears down the first's
    // OUTPUT route → the session reports "active" and engines report "started"
    // but NO PCM ever reaches the DAC → total silence in BOTH directions
    // (capture/input keeps working, which is why tx_enc grew while nobody heard
    // anything). Confirmed independently by OpenRouter (large) + Gemini + the
    // RemoteIO mechanism. One engine owning BOTH the input tap and the player
    // node fixes it — and lets VP-IO's AEC reference the playback for echo
    // cancellation, the canonical VoIP graph.
    private var playerNode: AVAudioPlayerNode?
    private var playFormat: AVAudioFormat?
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
    // W571 — route change observer (headset plug/unplug, Bluetooth connect/
    // disconnect). Without this, when a Bluetooth HFP device disconnects
    // the AVAudioEngine silently routes to the built-in speaker — correct
    // routing — but if the built-in microphone is at a different sample
    // rate or format the engine enters a degraded state: capture tap
    // continues on the old format → frame-size mismatches → Opus encode
    // errors or silence. Restarting the engine on route change ensures
    // the tap format matches the new hardware route.
    private var routeChangeObserver: NSObjectProtocol?

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

        // SINGLE-ENGINE FIX — attach + connect the PLAYBACK player node on the
        // SAME engine that owns the capture tap, BEFORE engine.start(), so the
        // one RemoteIO/VPIO unit drives both mic-in and speaker-out.
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

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

        // 5. Start the engine, then the player node (single engine drives both).
        engine.prepare()
        try engine.start()
        player.play()
        self.engine = engine
        self.playerNode = player
        self.playFormat = format
        isRunning = true

        // 6. M-12 — observe AVAudioSession interruptions so we can
        //    pause on .began and resume on .ended (.shouldResume).
        registerInterruptionObserver()
    }

    /// SINGLE-ENGINE FIX — schedule a decoded PCM frame for playback on the
    /// player node that lives on THIS capture engine. Replaces the old separate
    /// `AudioPlayback`, which ran a SECOND AVAudioEngine and was therefore mute.
    public func playFrame(_ pcmData: Data) {
        guard isRunning, let player = playerNode, let fmt = playFormat else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: fmt,
            frameCapacity: AVAudioFrameCount(AudioConstants.samplesPerFrame)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(AudioConstants.samplesPerFrame)
        pcmData.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, src, min(pcmData.count, AudioConstants.bytesPerFrame))
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
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
        // W571 — route change observer. Handles headset plug/unplug and
        // Bluetooth HFP connect/disconnect. On .oldDeviceUnavailable
        // (headset removed) the engine may keep running on the now-removed
        // device route and go silent. Restarting on device unavailability
        // ensures the engine re-opens on the current hardware (earpiece
        // or built-in speaker) with the correct format.
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let rawReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // A device that was in use (Bluetooth HFP, wired headset) was removed.
            // AVAudioEngine may go silent if it was using the now-missing device.
            // Restart to pick up the new route (built-in mic/speaker).
            print("[AudioCapture] route change: old device unavailable — restarting engine")
            guard isRunning else { return }
            engine?.inputNode.removeTap(onBus: 0)
            playerNode?.stop()
            if let engine = engine { audioPipeline.disableVoiceProcessing(on: engine) }
            engine?.stop()
            engine = nil; playerNode = nil; playFormat = nil; isRunning = false
            do { try start() }
            catch { print("[AudioCapture] restart after route change failed: \(error.localizedDescription)") }
        case .newDeviceAvailable:
            // New device connected (e.g. Bluetooth HFP). The engine may be
            // using a lower-quality route; restart to prefer the new device.
            // This is best-effort — if the user just plugged in headphones
            // mid-call a single engine restart is fast enough to be imperceptible.
            guard isRunning else { return }
            print("[AudioCapture] route change: new device available — restarting engine")
            engine?.inputNode.removeTap(onBus: 0)
            playerNode?.stop()
            if let engine = engine { audioPipeline.disableVoiceProcessing(on: engine) }
            engine?.stop()
            engine = nil; playerNode = nil; playFormat = nil; isRunning = false
            do { try start() }
            catch { print("[AudioCapture] restart after new device failed: \(error.localizedDescription)") }
        default:
            break
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
            playerNode?.stop()
            if let engine = engine {
                audioPipeline.disableVoiceProcessing(on: engine)
            }
            engine?.stop()
            engine = nil
            playerNode = nil
            playFormat = nil
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
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeChangeObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        if let engine = engine {
            audioPipeline.disableVoiceProcessing(on: engine)
        }
        engine?.stop()
        engine = nil
        playerNode = nil
        playFormat = nil
        audioPipeline.deactivateSession()
        isRunning = false
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = routeChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public var isCapturing: Bool { isRunning }

    /// Access the audio processing pipeline for stats or configuration changes.
    public var processingPipeline: AudioProcessingPipeline { audioPipeline }
}
#endif

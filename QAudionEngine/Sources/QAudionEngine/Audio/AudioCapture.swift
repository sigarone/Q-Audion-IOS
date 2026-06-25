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
    // W-AEC-FIX — VP-IO input-pull sink: when Voice-Processing I/O is active the
    // inputNode tap starves on iPad + builtInSpeaker unless the mic is actively
    // pulled through the graph; this muted mixer is that pull (see start()).
    private var inputSink: AVAudioMixerNode?
    // W-AEC-FIX — set true by the tap callback on its first delivered buffer.
    // The starve watchdog checks it to detect the VP-IO "tap never fires" case.
    private var firstFrameReceived = false
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

    // W574o — route-change anti-thrash. A flapping Bluetooth HFP link (and the
    // engine restart itself re-running AVAudioSession route selection) fired
    // new/oldDeviceAvailable several times per second; restarting on each one
    // thrashed the audio path so decrypted voice never played steadily (device
    // telemetry 1.0.658: route flapped BT↔built-in every ~1-2s while frames were
    // decrypting fine). Two purely time-based guards, no timers / no thread change:
    //   * throttle  — at most one route-driven restart per second;
    //   * suppress  — ignore the route change our OWN restart provokes (~0.6s),
    //                 which breaks the self-induced restart loop.
    private var lastEngineRestart: Date = .distantPast
    private var restartSuppressUntil: Date = .distantPast
    private let routeRestartThrottle: TimeInterval = 1.0

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
        firstFrameReceived = false  // W-AEC-FIX — re-arm the VP-IO starve watchdog

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

        // W574k — the tap format MUST match the input node's REAL output bus
        // format. Voice Processing I/O runs the input node as Float32 (and on
        // a warm engine / 2nd call it's already negotiated), so passing our
        // hardcoded Int16 `format` made installTap throw
        //   "Failed to create tap due to format mismatch, <…1 ch, 48000 Hz, Int16>"
        // → NSException → SIGABRT. That hit BOTH startCall and
        // activateIncomingCallAudio (both call start()), so the iPad crashed
        // whether it dialled OR answered. The tap callback below already
        // converts Float32→Int16, so feeding it the node's native format is
        // safe; fall back to our canonical format only if the node reports an
        // invalid (0-channel / 0-Hz) format before the engine is prepared.
        let nodeFormat = inputNode.outputFormat(forBus: 0)
        let tapFormat: AVAudioFormat = (nodeFormat.channelCount > 0 && nodeFormat.sampleRate > 0)
            ? nodeFormat
            : format

        // W-AEC-FIX — VP-IO input-pull. When Voice-Processing I/O is active the
        // inputNode tap STARVES on iPad + builtInSpeaker (the duplex VP-IO unit
        // doesn't pull the mic when the inputNode has no downstream consumer —
        // only a tap; "callback never fires", W574f). Route inputNode → a MUTED
        // sink mixer → mainMixer so the engine actively pulls the mic (keeping
        // the tap alive) with NO local loopback (sink outputVolume = 0; the only
        // thing reaching the speaker is the remote audio via the player node,
        // which is exactly the VP-IO AEC reference). Gated on VP-IO active — the
        // no-VP-IO path already taps fine and is left byte-for-byte unchanged.
        if audioPipeline.voiceProcessingIsActive {
            let sink = AVAudioMixerNode()
            engine.attach(sink)
            engine.connect(inputNode, to: sink, format: tapFormat)
            sink.outputVolume = 0
            engine.connect(sink, to: engine.mainMixerNode, format: tapFormat)
            self.inputSink = sink
        }

        let pipeline = self.audioPipeline
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(AudioConstants.samplesPerFrame), format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.firstFrameReceived = true  // W-AEC-FIX — VP-IO tap is delivering
            // W574: VP-IO may deliver Float32 frames even though we requested Int16.
            // The tap bufferSize hint is also overridden by VP-IO (tied to hardware I/O
            // duration per W475). Guard on int16ChannelData first; if VP-IO delivered
            // Float32 natively, convert to Int16 so the accumulator/re-chunker always
            // receives 16-bit samples regardless of the engine's VP-IO state.
            let raw: Data
            if let int16Data = buffer.int16ChannelData {
                raw = Data(bytes: int16Data[0], count: Int(buffer.frameLength) * 2)
            } else if let floatData = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                var int16Buf = [Int16](repeating: 0, count: count)
                let src = floatData[0]
                for i in 0..<count {
                    let clamped = max(-1.0 as Float, min(1.0 as Float, src[i]))
                    int16Buf[i] = Int16(clamped * Float(Int16.max))
                }
                raw = int16Buf.withUnsafeBytes { Data($0) }
            } else {
                return
            }
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

        // 7. W-AEC-FIX — if VP-IO is active, arm the starve watchdog. If the
        //    input tap never delivers a buffer within the window (the iPad
        //    VP-IO + builtInSpeaker starve, W574f), restart WITHOUT VP-IO so the
        //    mic transmits. Worst case = the pre-fix behaviour (echo, working
        //    TX); never a dead mic. iPhone / no-VP-IO never arms it.
        if audioPipeline.voiceProcessingIsActive {
            scheduleVpioStarveWatchdog()
        }
    }

    /// W-AEC-FIX — VP-IO input-tap starve detector. The iPad's VP-IO + built-in
    /// speaker route can leave the inputNode tap callback completely silent
    /// (W574f). If no buffer has arrived 1.2 s after start, fall back to a
    /// no-VP-IO restart so the call still has a live mic (echo returns, but a
    /// working call beats a dead one). One-shot per start(); a delivering tap
    /// (firstFrameReceived) cancels it.
    private func scheduleVpioStarveWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.isRunning else { return }
            if self.firstFrameReceived { return }  // VP-IO tap is delivering — keep AEC
            print("[AudioCapture] W-AEC-FIX: VP-IO input tap starved (no frame in 1.2s) — restarting without VP-IO so the mic transmits")
            self.audioPipeline.forceDisableVoiceProcessing = true
            self.restartEngineForRoute()
        }
    }

    /// SINGLE-ENGINE FIX — schedule a decoded PCM frame for playback on the
    /// player node that lives on THIS capture engine. Replaces the old separate
    /// `AudioPlayback`, which ran a SECOND AVAudioEngine and was therefore mute.
    public func playFrame(_ pcmData: Data) {
        // W574j — build the playback buffer in the player node's LIVE output
        // format, not the cached `playFormat`. On iPad, enabling Voice
        // Processing I/O reconfigures the player→mixer bus to the hardware
        // format (typically Float32) AFTER our Int16 `connect(...)`. Scheduling
        // an Int16 buffer onto a Float32 bus fails AVAudioPlayerNode's format
        // precondition → AVAudioEngine throws an Obj-C NSException → SIGABRT.
        // This was invisible until W574i fixed the seal: once relay audio
        // actually decrypts, the receiver finally calls playFrame with real
        // PCM and the latent format mismatch crashed the iPad on answer.
        // Reading the bus format here (and converting the decoded Int16 mono
        // PCM into it) keeps scheduleBuffer valid on every device/route.
        guard isRunning,
              let player = playerNode,
              let engine = engine, engine.isRunning else { return }
        let outFmt = player.outputFormat(forBus: 0)
        let frames = pcmData.count / 2  // decoded PCM is Int16 mono
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: outFmt,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let ch = Int(outFmt.channelCount)
        let scale: Float = 1.0 / 32768.0
        let filled: Bool = pcmData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return false }
            if outFmt.commonFormat == .pcmFormatInt16, let dst = buffer.int16ChannelData {
                if outFmt.isInterleaved {
                    let d = dst[0]
                    for i in 0..<frames { let v = src[i]; for c in 0..<ch { d[i * ch + c] = v } }
                } else {
                    for c in 0..<ch { let d = dst[c]; for i in 0..<frames { d[i] = src[i] } }
                }
                return true
            } else if outFmt.commonFormat == .pcmFormatFloat32, let dst = buffer.floatChannelData {
                if outFmt.isInterleaved {
                    let d = dst[0]
                    for i in 0..<frames { let v = Float(src[i]) * scale; for c in 0..<ch { d[i * ch + c] = v } }
                } else {
                    for c in 0..<ch { let d = dst[c]; for i in 0..<frames { d[i] = Float(src[i]) * scale } }
                }
                return true
            }
            return false  // unsupported bus format → skip frame (never crash)
        }
        guard filled else { return }
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
            // Restart to pick up the new route (built-in mic/speaker) — but throttle
            // so a flapping route doesn't thrash the engine (W574o).
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: old device unavailable — restarting engine")
            restartEngineForRoute()
        case .newDeviceAvailable:
            // New device connected (e.g. Bluetooth HFP). The engine may be using a
            // lower-quality route; restart to prefer the new device. Throttled (W574o).
            if shouldSkipRouteRestart() { return }
            print("[AudioCapture] route change: new device available — restarting engine")
            restartEngineForRoute()
        case .override:
            // W574c — the output route was overridden: this is the in-call speaker
            // button (`overrideOutputAudioPort(.speaker)` / `.none`). VP-IO is
            // route-dependent and can only be (un)set BEFORE engine start, so restart
            // to re-evaluate `enableVoiceProcessing`. User-initiated + one-shot → honor
            // immediately (no throttle), but still arm the suppress window so the
            // override's own route echo doesn't trigger a second restart.
            print("[AudioCapture] route change: output override (speaker toggle) — restarting engine to re-evaluate VP-IO")
            restartEngineForRoute()
        default:
            break
        }
    }

    /// W574o — skip a route-driven engine restart if we just restarted (the route
    /// change is the echo of our own `setActive`) or if we restarted < 1s ago (a
    /// flapping Bluetooth link). Keeps the genuine isolated headset plug/unplug case
    /// (W571) working — those are not rapid repeats.
    private func shouldSkipRouteRestart() -> Bool {
        let now = Date()
        if now < restartSuppressUntil { return true }
        if now.timeIntervalSince(lastEngineRestart) < routeRestartThrottle { return true }
        return false
    }

    /// Tear down and rebuild the engine on the current hardware route. Records the
    /// restart time and arms a short suppress window so the route change this restart
    /// itself provokes is ignored (breaks the self-induced thrash loop).
    private func restartEngineForRoute() {
        guard isRunning else { return }
        lastEngineRestart = Date()
        restartSuppressUntil = Date().addingTimeInterval(0.6)
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        if let engine = engine { audioPipeline.disableVoiceProcessing(on: engine) }
        engine?.stop()
        engine = nil; playerNode = nil; playFormat = nil; inputSink = nil; isRunning = false
        do { try start() }
        catch { print("[AudioCapture] restart after route change failed: \(error.localizedDescription)") }
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
            inputSink = nil
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
        inputSink = nil
        // W-AEC-FIX — clear the watchdog fallback so the NEXT call retries VP-IO
        // AEC fresh (a starve will just re-trigger the fallback if it recurs).
        audioPipeline.forceDisableVoiceProcessing = false
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

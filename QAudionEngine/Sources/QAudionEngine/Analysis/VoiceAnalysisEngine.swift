import Foundation

/// Analyses the REMOTE party's received voice for the in-call voice panel.
///
/// Decoded audio arrives in buffers of any length (10 ms from the native playback
/// tap, 20 ms or 60 ms from the other paths, in tests anything down to one
/// sample). The engine keeps the most recent 60 ms of it in a ring (`VoiceWindow`)
/// and runs ONE analysis per 100 ms of AUDIO time on that window: the first one
/// 100 ms after the audio started, every later one exactly 4800 samples after the
/// previous. A step that falls inside a buffer is run at that exact sample, so the
/// results are identical for every buffer size.
///
/// Each analysis measures pitch, formants, harmonics-to-noise ratio and speech
/// rate; every one of those numbers is a real measurement with a validity flag
/// (see `VoiceAnalysisResult`). The numbers and the rules behind them are those of
/// the specification in docs/voice-analysis-spec.md, which the Android engine
/// implements too.
///
/// Two callbacks are delivered for every step, in order:
///   * `onResult`   the raw result of the step. Consumers that count or detect
///                  (the call diagnostics) use this one.
///   * `onDisplay`  the value to SHOW: the mean over the last 10 results by the
///                  display rule of `VoiceAnalysisSmoothing`, with the word of the
///                  tone row (`VoiceWordHold`) in `voiceWord`. The engine keeps
///                  that window and that word itself, in audio time, and clears
///                  them together with the rest of its state.
///
/// A gap in the audio is reported with `markDiscontinuity(missingSamples:)`: a gap
/// shorter than 2 s restarts the analysis grid (the window and the 100 ms phase)
/// but keeps every history, and a gap of 2 s or more, like `reset()`, clears
/// everything.
///
/// Threading: `processFrame` is called from the single RX analysis queue, never
/// from the audio thread. The analysis runs under the engine lock so that
/// `reset()`, `markDiscontinuity` and `setEnabled` are safe from any thread, and
/// the two callbacks are read and replaced under the same lock; the lock is never
/// held while a callback runs, so a callback may replace either callback. Once
/// constructed the engine allocates nothing per frame or per analysis.
public final class VoiceAnalysisEngine: @unchecked Sendable {
    /// Replaceable from any thread (the instance is reused from call to call, while the analysis queue may
    /// still be draining); the callbacks a step calls are the ones in place when the step is taken.
    public var onResult: ((VoiceAnalysisResult) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return resultHandler }
        // The old closure is released after the lock, so its captures never deinit under it.
        set { lock.lock(); let old = resultHandler; resultHandler = newValue; lock.unlock(); _ = old }
    }
    public var onDisplay: ((VoiceAnalysisResult) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return displayHandler }
        // The old closure is released after the lock, so its captures never deinit under it.
        set { lock.lock(); let old = displayHandler; displayHandler = newValue; lock.unlock(); _ = old }
    }
    // The storage behind the two callbacks; only touched with the lock held.
    private var resultHandler: ((VoiceAnalysisResult) -> Void)?
    private var displayHandler: ((VoiceAnalysisResult) -> Void)?

    private let window = VoiceWindow()
    private let pitchExtractor = PitchExtractor()
    private let stressDetector = StressDetector()
    private let formantTracker = FormantTracker()
    private let healthMonitor = VoiceHealthMonitor()
    private let speechRateAnalyzer = SpeechRateAnalyzer()
    private let confidenceIndicator = ConfidenceIndicator()

    private let lock = NSLock()
    private var enabled = true

    // Framing. All counters are in samples of the current segment, which starts at
    // creation, at `reset()` and at every discontinuity.
    private var segmentSamples = 0
    private var frameAccumulator = 0.0
    private var frameFill = 0
    /// Mean square of the complete 10 ms frames of the step in progress.
    private let frameEnergies: UnsafeMutablePointer<Double>
    private var framesInStep = 0

    /// The last 10 raw results (the display window).
    private var displayHistory: [VoiceAnalysisResult] = []
    /// The word of the tone row, counted over every result since the last clearing.
    private var wordHold = VoiceWordHold()

    private struct Step {
        let result: VoiceAnalysisResult
        let display: VoiceAnalysisResult
    }

    public init() {
        frameEnergies = UnsafeMutablePointer<Double>.allocate(capacity: VoiceDsp.framesPerStep)
        frameEnergies.initialize(repeating: 0, count: VoiceDsp.framesPerStep)
        displayHistory.reserveCapacity(VoiceDsp.displaySteps + 1)
    }

    deinit {
        frameEnergies.deallocate()
    }

    /// Feed one buffer of 16-bit little-endian mono PCM at 48 kHz, of any length.
    /// An odd trailing byte is ignored.
    public func processFrame(_ pcmFrame: Data) {
        let sampleCount = pcmFrame.count / 2
        guard sampleCount > 0 else { return }
        pcmFrame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < sampleCount {
                lock.lock()
                guard enabled else { lock.unlock(); return }
                let step = consume(raw, offset: &offset, sampleCount: sampleCount)
                let resultCallback = resultHandler
                let displayCallback = displayHandler
                lock.unlock()
                if let step = step {
                    resultCallback?(step.result)
                    displayCallback?(step.display)
                }
            }
        }
    }

    /// Audio of `missingSamples` samples (48 kHz) is missing between the last
    /// sample received and the next one. Estimate it from timestamps or the wall
    /// clock when it is not known exactly; 0 means "a splice of unknown length" and
    /// counts as short. Before any audio it has no effect.
    ///
    /// Shorter than 2 s: the analysis grid restarts (the next analysis comes 100 ms
    /// after the audio resumes, on a window of audio from after the gap only), the
    /// partial 10 ms frame and the frames of the unfinished step are dropped, and
    /// every history is kept: missing audio is not time. 2 s or more: everything is
    /// cleared, as by `reset()`.
    public func markDiscontinuity(missingSamples: Int) {
        lock.lock()
        if missingSamples >= VoiceDsp.longGapSamples {
            clearLocked()
        } else {
            restartSegmentLocked()
        }
        lock.unlock()
    }

    /// Forget everything measured so far: the audio ring, the cadence, every
    /// tracker and the display window. Call at the end of a call (the engine
    /// instance is reused).
    public func reset() {
        lock.lock()
        clearLocked()
        lock.unlock()
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        // Audio was not consumed while disabled: resuming is a splice of unknown length.
        if enabled && !self.enabled { restartSegmentLocked() }
        self.enabled = enabled
        lock.unlock()
    }

    public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    // MARK: - Internals (the lock is held)

    private func restartSegmentLocked() {
        segmentSamples = 0
        frameAccumulator = 0
        frameFill = 0
        framesInStep = 0
    }

    private func clearLocked() {
        window.reset()
        stressDetector.reset()
        formantTracker.reset()
        healthMonitor.reset()
        speechRateAnalyzer.reset()
        displayHistory.removeAll(keepingCapacity: true)
        wordHold.reset()
        restartSegmentLocked()
    }

    /// Feeds samples from `offset` on until an analysis step falls due (returning
    /// it) or the buffer is used up. `offset` is advanced past what was consumed.
    private func consume(_ raw: UnsafeRawBufferPointer, offset: inout Int, sampleCount: Int) -> Step? {
        while offset < sampleCount {
            let lo = UInt16(raw[2 * offset])
            let hi = UInt16(raw[2 * offset + 1])
            let v = Double(Int16(bitPattern: lo | (hi << 8))) / 32768.0
            offset += 1

            window.push(v)
            frameAccumulator += v * v
            frameFill += 1
            if frameFill == VoiceDsp.frameSamples {
                // A step holds exactly `framesPerStep` frames and `frameEnergies` has room for that many.
                // The counters are kept in step with the segment, so the bound is never hit; it only keeps a
                // counter that went out of step from writing past the buffer.
                if framesInStep < VoiceDsp.framesPerStep {
                    frameEnergies[framesInStep] = frameAccumulator / Double(VoiceDsp.frameSamples)
                    framesInStep += 1
                }
                frameAccumulator = 0
                frameFill = 0
            }
            segmentSamples += 1
            if segmentSamples % VoiceDsp.hopSamples == 0 {
                return analyzeStep()
            }
        }
        return nil
    }

    private func analyzeStep() -> Step {
        let result = analyzeWindow()
        framesInStep = 0
        displayHistory.append(result)
        if displayHistory.count > VoiceDsp.displaySteps { displayHistory.removeFirst() }
        var display = VoiceAnalysisSmoothing.average(of: displayHistory) ?? result
        display.voiceWord = wordHold.update(voiced: result.pitch.voiced)
        return Step(result: result, display: display)
    }

    /// One analysis of the current 60 ms window.
    private func analyzeWindow() -> VoiceAnalysisResult {
        window.snapshot()
        let estimate = pitchExtractor.extract(window: window)
        let pitch = VoiceAnalysisResult.Pitch(f0Hz: Float(estimate.f0Hz),
                                              voiced: estimate.voiced,
                                              rms: Float(estimate.rms),
                                              f0Valid: estimate.voiced,
                                              periodicity: Float(estimate.periodicity))
        let stress = stressDetector.analyze(pitch: pitch)
        let formants = formantTracker.extract(window: window, voiced: estimate.voiced, f0Hz: estimate.f0Hz)
        let health = healthMonitor.analyze(window: window, voiced: estimate.voiced, f0Hz: estimate.f0Hz)
        let reading = speechRateAnalyzer.analyze(frameEnergies: frameEnergies, count: framesInStep,
                                                 voiced: estimate.voiced)
        let speechRate = VoiceAnalysisResult.SpeechRate(
            syllablesPerSec: Float(reading.syllablesPerSec),
            pauseRatio: Float(reading.pauseRatio),
            isSpeaking: reading.isSpeaking,
            valid: reading.valid)
        let confidence = confidenceIndicator.analyze(pitch: pitch, stress: stress, health: health, speechRate: speechRate)
        return VoiceAnalysisResult(pitch: pitch, stress: stress, voiceHealth: health,
                                   speechRate: speechRate, formants: formants, confidence: confidence)
    }
}

import Foundation

/// Speech rate (syllables per second) of the received voice, from the intensity
/// envelope (docs/voice-analysis-spec.md, section 7).
///
/// ## What was wrong before
///
/// The old counter assumed every call covered 20 ms while being called on
/// whatever cadence the audio arrived, counted voiced-to-unvoiced transitions as
/// syllables, and never windowed the count, so it grew without bound over a call.
///
/// ## Method (identical on both platforms)
///
/// The envelope is the mean square of each 10 ms frame of audio (aligned to the
/// start of the segment), in dB, with a floor of -100 dB. The engine hands this
/// analyser the 10 frames of every analysis step together with that step's voicing
/// flag, in order; frames are numbered in the order they are committed.
///
///   * A syllable nucleus is a peak of the envelope found by a zig-zag detector
///     with 3 dB of hysteresis: a peak is confirmed once the level has fallen 3 dB
///     below it, provided it rose at least 3 dB above the valley before it, it
///     lies in a frame committed with the voiced flag, and it is at least 100 ms
///     after the previous nucleus.
///   * The span is the last 6 s of audio (the audio received so far, during the
///     first 6 s). The level of the span is its loudest VOICED frame; a frame is
///     active when it is within 25 dB of that level. With no voiced frame in the
///     span, no frame is active.
///   * A run of inactive frames longer than 300 ms is a pause. It keeps its true
///     length when it began before the span (30 frames of look-back).
///   * speaking = span - pauses. The rate is valid from 2 s of speaking time:
///     nuclei in the span / (speaking time), clamped to 0...12, and pauseRatio =
///     pause / span. Until then both are 0 with the flag false.
///   * `isSpeaking` is true when at least one of the 10 frames just committed is
///     active, valid rate or not.
public final class SpeechRateAnalyzer {

    struct Reading {
        var syllablesPerSec: Double
        var pauseRatio: Double
        var valid: Bool
        var isSpeaking: Bool
    }

    private let ringSize = VoiceDsp.ringFrames

    // Envelope history, indexed by frame number modulo the ring size.
    private var db: [Double]
    private var voicedFlag: [Bool]
    /// Frames committed since the last reset.
    private var frameCount = 0

    // Nucleus detector.
    private var nuclei: [Int] = []
    private var lastNucleus: Int?
    private var started = false
    private var seekingPeak = true
    private var peak = 0.0
    private var peakIndex = 0
    private var valley = 0.0
    private var precedingValley = 0.0

    public init() {
        db = [Double](repeating: 0, count: VoiceDsp.ringFrames)
        voicedFlag = [Bool](repeating: false, count: VoiceDsp.ringFrames)
        nuclei.reserveCapacity(128)
    }

    public func reset() {
        for i in 0..<ringSize {
            db[i] = 0
            voicedFlag[i] = false
        }
        frameCount = 0
        nuclei.removeAll(keepingCapacity: true)
        lastNucleus = nil
        started = false
        seekingPeak = true
        peak = 0
        peakIndex = 0
        valley = 0
        precedingValley = 0
    }

    /// Commit the `count` frame energies (mean square of the raw normalised
    /// samples) of one analysis step, tagged with that step's voicing, and return
    /// the reading.
    func analyze(frameEnergies: UnsafePointer<Double>, count: Int, voiced: Bool) -> Reading {
        for k in 0..<count {
            let e = frameEnergies[k]
            let slot = frameCount % ringSize
            db[slot] = 10.0 * log10(e > VoiceDsp.energyFloor ? e : VoiceDsp.energyFloor)
            voicedFlag[slot] = voiced
            frameCount += 1
        }
        for i in (frameCount - count)..<frameCount { zigzag(i) }

        let n = min(frameCount, VoiceDsp.historyFrames)
        let start = frameCount - n
        while let oldest = nuclei.first, oldest < start { nuclei.removeFirst() }

        // Level of the span: the loudest voiced frame.
        var level = 0.0
        var hasLevel = false
        for i in start..<frameCount where voicedFlag[i % ringSize] {
            let v = db[i % ringSize]
            if !hasLevel || v > level {
                level = v
                hasLevel = true
            }
        }
        let floorDb = level - VoiceDsp.activeRangeDb
        func active(_ i: Int) -> Bool { hasLevel && db[i % ringSize] >= floorDb }

        // Pauses: maximal runs of inactive frames longer than 300 ms, counted from
        // the start of the span but found from 30 frames earlier.
        var pause = 0
        var runStart = -1
        var i = max(0, start - VoiceDsp.lookBackFrames)
        while i < frameCount {
            if active(i) {
                if runStart >= 0 && i - runStart > VoiceDsp.pauseMinFrames && i > start {
                    pause += i - max(runStart, start)
                }
                runStart = -1
            } else if runStart < 0 {
                runStart = i
            }
            i += 1
        }
        if runStart >= 0 && frameCount - runStart > VoiceDsp.pauseMinFrames {
            pause += frameCount - max(runStart, start)
        }
        let speaking = n - pause

        var speakingNow = false
        for j in (frameCount - count)..<frameCount where active(j) {
            speakingNow = true
            break
        }

        guard speaking >= VoiceDsp.minSpeakingFrames else {
            return Reading(syllablesPerSec: 0, pauseRatio: 0, valid: false, isSpeaking: speakingNow)
        }
        let rate = Double(nuclei.count) / (Double(speaking) * 0.01)
        return Reading(syllablesPerSec: max(0.0, min(VoiceDsp.maxSyllablesPerSec, rate)),
                       pauseRatio: Double(pause) / Double(n),
                       valid: true,
                       isSpeaking: speakingNow)
    }

    /// One frame of the zig-zag detector with 3 dB of hysteresis.
    private func zigzag(_ index: Int) {
        let x = db[index % ringSize]
        if !started {
            started = true
            seekingPeak = true
            peak = x
            peakIndex = index
            precedingValley = x
            return
        }
        if seekingPeak {
            if x > peak {
                peak = x
                peakIndex = index
            } else if peak - x >= VoiceDsp.nucleusDipDb {
                confirmPeak()
                seekingPeak = false
                valley = x
            }
        } else {
            if x < valley {
                valley = x
            } else if x - valley >= VoiceDsp.nucleusDipDb {
                precedingValley = valley
                seekingPeak = true
                peak = x
                peakIndex = index
            }
        }
    }

    private func confirmPeak() {
        let p = peakIndex
        if peak - precedingValley < VoiceDsp.nucleusDipDb { return }
        if !voicedFlag[p % ringSize] { return }
        if let last = lastNucleus, p - last < VoiceDsp.refractoryFrames { return }
        lastNucleus = p
        nuclei.append(p)
    }
}

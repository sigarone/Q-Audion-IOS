import Foundation

/// How much speech a window of audio holds, for the gate of `OwnerContinuityMonitor`: a window with no speech in it is
/// not a sample of anybody's voice, so it is neither scored against the owner's template nor counted.
public protocol WindowSpeechDetector: AnyObject, Sendable {
    /// Milliseconds of speech in `pcm16k` (mono, 16 kHz, floats in [-1, 1]). 0 when the detector cannot tell (model
    /// missing or failing): a window the detector cannot judge is skipped, never scored.
    func speechMs(pcm16k: [Float]) -> Int
}

/// `WindowSpeechDetector` on the Silero VAD of the voice bundle (SHA-256 pinned by `VoiceBundle`): one speech
/// probability per 512-sample (32 ms) chunk, a chunk counts as speech at or above the bundle's `vad.on` (0.5), no
/// hysteresis. The model state is reset for every window, so a window is judged on its own.
///
/// A VAD and not the energy of the window: an energy rule cannot tell a noisy room from a person.
///
/// One instance for the app (`shared`): the ONNX session is created on the first window, on the thread of the monitor
/// that asks (never at construction), and used by the calls one after the other. `speechMs` holds a lock for the
/// window, so callers on different threads take turns.
public final class SileroWindowSpeechDetector: WindowSpeechDetector, @unchecked Sendable {
    public static let shared = SileroWindowSpeechDetector()

    private static let chunkMs = 32

    private let lock = NSLock()
    private var runner: SileroVadRunner?
    private var threshold: Float = 0.5
    private var unavailable = false

    public init() {}

    public func speechMs(pcm16k: [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let model = openLocked() else { return 0 }
        model.reset()
        let chunkLength = VoiceChunker.chunkLength
        var speech = 0
        for index in 0..<(pcm16k.count / chunkLength) {
            let chunk = Array(pcm16k[(index * chunkLength)..<((index + 1) * chunkLength)])
            do {
                if try model.step(chunk) >= threshold { speech += 1 }
            } catch {
                print("[SileroWindowSpeechDetector] inference failed, the window is skipped")
                return 0
            }
        }
        return speech * Self.chunkMs
    }

    /// The model, or `nil` (and no further attempt) when the bundle or the session cannot be opened. MUST be called
    /// with `lock` held.
    private func openLocked() -> SileroVadRunner? {
        if let runner { return runner }
        if unavailable { return nil }
        do {
            let bundle = try VoiceBundle.loadFromModule()
            let created = try SileroVadRunner(modelURL: bundle.vadModelURL)
            threshold = Float(bundle.constants.vad.on)
            runner = created
            return created
        } catch {
            unavailable = true
            print("[SileroWindowSpeechDetector] voice bundle unavailable, the owner voice monitor skips its windows")
            return nil
        }
    }
}

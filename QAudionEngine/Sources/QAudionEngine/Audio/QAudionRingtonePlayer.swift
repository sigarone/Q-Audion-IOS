import Foundation

/// Why a cue did not start (`QAudionRingtonePlayer.lastFailure`).
public enum CueStartFailure: String, Equatable, Sendable {
    /// Switched off in the call-sound settings.
    case disabled
    case missingFile = "missing_file"
    /// The player could not be built from the file.
    case initFailed = "init"
    /// `play()` returned false, typically right after the audio session became active.
    case playFalse = "play_false"
}

/// When a cue that failed to start is tried again: once, shortly after, and only for a failure that can pass by
/// itself (the audio session was not ready to play yet).
public enum CueRetryPolicy {
    public static let delaySeconds: TimeInterval = 0.3
    public static let maxRetries = 1

    public static func shouldRetry(failure: CueStartFailure?, attempt: Int) -> Bool {
        guard let failure, attempt < maxRetries else { return false }
        return failure == .playFalse
    }
}

#if canImport(AVFoundation)
import AVFoundation

/// Plays the call cues (start tick, connecting, ringback, key exchange, connected, ended, busy) from the bundled
/// files named by `CallCueKind`. Mirrors the other platforms: `loop(cue)` for a looping cue, `play(cue)` for a
/// one-shot, `stop()` to silence everything; both are idempotent and never throw.
///
/// Each cue goes through the settings gate (`CallCueGate`): a switched-off cue is not started, and the in-line volume
/// is the player's gain. Every start, stop, skip and failure is reported through `log` (cue name and gain only).
///
/// Uses `AVAudioPlayer`, which plays on whatever session is active. The player does not activate one: with CallKit,
/// the session may only be used once CallKit has activated it, and the caller (`AppState`) keeps that gate.
/// Loops use CAF files (IMA4) so they stay seamless; a compressed container with encoder padding would leave a gap.
public final class QAudionRingtonePlayer {

    public enum Cue: Hashable {
        /// Call being set up.
        case outgoingRing
        /// The far end is ringing.
        case confirmedRingback
        case keyExchange
        case callConnected
        case callEnded
        /// Busy signal, played once.
        case busy
        /// Very short click when a call starts.
        case dialingTick

        public var kind: CallCueKind {
            switch self {
            case .outgoingRing: return .connecting
            case .confirmedRingback: return .ringback
            case .keyExchange: return .keyExchange
            case .callConnected: return .connected
            case .callEnded: return .ended
            case .busy: return .busy
            case .dialingTick: return .dialingTick
            }
        }
    }

    /// Settings read each time a cue starts, so a change applies to the next cue.
    public var settingsProvider: () -> CallSoundSettings = { SettingsStore().loadCallSounds() }
    /// Where a bundled cue file is; `nil` when it is missing.
    public var resourceURL: (String) -> URL? = { Bundle.main.url(forResource: $0, withExtension: "caf") }
    /// Diagnostics sink: the line and whether it reports a problem.
    public var log: ((String, Bool) -> Void)?

    /// Why the last `loop` / `play` did not start; nil when it started.
    public private(set) var lastFailure: CueStartFailure?

    private var loopPlayer: AVAudioPlayer?
    private var shotPlayer: AVAudioPlayer?
    private var dataCache: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    /// Replaces the looping cue with `cue`, or starts it. Returns whether it is playing.
    @discardableResult
    public func loop(_ cue: Cue) -> Bool {
        start(cue, looping: true)
    }

    /// Fires a one-shot cue. A one-shot other than the start tick replaces the looping cue. Returns whether it started.
    @discardableResult
    public func play(_ cue: Cue) -> Bool {
        start(cue, looping: false)
    }

    /// Stops every cue. Idempotent.
    public func stop() {
        lock.lock()
        let loopRunning = loopPlayer?.isPlaying ?? false
        let shotRunning = shotPlayer?.isPlaying ?? false
        loopPlayer?.stop()
        shotPlayer?.stop()
        loopPlayer = nil
        shotPlayer = nil
        lock.unlock()
        if loopRunning || shotRunning { log?("cue stop all", false) }
    }

    private func start(_ cue: Cue, looping: Bool) -> Bool {
        lastFailure = nil
        let kind = cue.kind
        let settings = settingsProvider()
        guard CallCueGate.shouldPlay(kind, settings: settings) else {
            lastFailure = .disabled
            log?("cue skip name=\(kind.rawValue) disabled=1", false)
            // A switched-off cue must still replace the cue it follows.
            if looping || kind != .dialingTick { stopLoop() }
            return false
        }
        let gain = CallCueGate.gain(kind, settings: settings)
        guard let data = cueData(kind) else {
            lastFailure = .missingFile
            log?("cue fail name=\(kind.rawValue) reason=missing_file", true)
            return false
        }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            let code: Int = (error as NSError).code
            lastFailure = .initFailed
            let line: String = "cue fail name=\(kind.rawValue) reason=init err=\(code)"
            log?(line, true)
            return false
        }
        player.volume = gain
        player.numberOfLoops = looping ? -1 : 0
        player.prepareToPlay()
        // The loop slot holds loops; every one-shot except the tick replaces the loop, as it did before.
        if looping || kind != .dialingTick { stopLoop() }
        guard player.play() else {
            lastFailure = .playFalse
            log?("cue fail name=\(kind.rawValue) reason=play_false \(Self.sessionState())", true)
            return false
        }
        lock.lock()
        if looping {
            loopPlayer = player
        } else if kind == .dialingTick {
            shotPlayer?.stop()
            shotPlayer = player
        } else {
            loopPlayer = player
        }
        lock.unlock()
        log?(String(format: "cue start name=%@ gain=%.2f loop=%d", kind.rawValue, gain, looping ? 1 : 0), false)
        return true
    }

    /// Session facts that explain a refused `play()`: category, whether another app's audio runs, the output route
    /// types. Nothing that names the user or the device.
    private static func sessionState() -> String {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "cat=\(session.category.rawValue) mode=\(session.mode.rawValue) other_audio=\(session.isOtherAudioPlaying ? 1 : 0) out=\(outputs.isEmpty ? "none" : outputs)"
        #else
        return "session=n/a"
        #endif
    }

    private func stopLoop() {
        lock.lock()
        let running = loopPlayer?.isPlaying ?? false
        loopPlayer?.stop()
        loopPlayer = nil
        lock.unlock()
        if running { log?("cue stop loop", false) }
    }

    private func cueData(_ kind: CallCueKind) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = dataCache[kind.resourceName] { return cached }
        guard let url = resourceURL(kind.resourceName), let data = try? Data(contentsOf: url) else { return nil }
        dataCache[kind.resourceName] = data
        return data
    }
}
#endif

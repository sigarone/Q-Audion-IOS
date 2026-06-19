import Foundation
import AVFoundation

/// Voice-note recorder for the chat composer. Captures M4A/AAC into a
/// temporary file the caller can ship via the existing message wire.
///
/// **Rationale for AAC over Opus**: the engine ships an Opus codec
/// (`COpus` C lib) which is great for VoIP frames but requires hand-
/// rolled file containers (Ogg) that other clients (Android / Desktop)
/// don't yet decode. AAC inside an .m4a container is universally
/// playable — the wire-format spec for chat voice-notes (cross-platform)
/// is `audio/mp4` per the Android `VoiceNoteSender`. Same encoder, same
/// bitrate, same container.
///
/// Lifecycle:
///   1. `start()` — requests mic permission if needed, configures the
///      audio session, opens an `AVAudioRecorder` writing to a tmp file
///      named with the message UUID.
///   2. `stop()` → returns `Recording(fileURL, durationMs)` ready to be
///      handed to the upload + send pipeline.
///   3. `cancel()` — stops the recorder and deletes the tmp file.
///
/// The composer holds one instance per chat session; recreating after
/// `stop()` is safe (the recorder is reset between calls).
@MainActor
final class VoiceNoteRecorder: ObservableObject {

    /// Hand-off shape for `stop()` → caller uploads + sends.
    struct Recording {
        let fileURL: URL
        let durationMs: Int
        let mimeType: String  // "audio/mp4" for AAC-in-M4A
    }

    enum RecorderError: Error {
        case permissionDenied
        case sessionFailure(String)
        case recorderFailure(String)
    }

    private var recorder: AVAudioRecorder?
    private var startedAt: Date?
    /// W108: live elapsed-seconds counter, ticked by a 0.25s timer.
    /// SwiftUI binds to this so the composer can render "0:34" /
    /// "1:12" instead of a static "Recording…" label. Reset to 0 on
    /// cancel / stop.
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    private var elapsedTimer: Timer?

    /// Starts a new recording. Caller is expected to await; throws on
    /// permission denial or session/recorder failure.
    func start() async throws {
        let session = AVAudioSession.sharedInstance()
        // Voice-note recording needs `.playAndRecord` so the user can
        // immediately preview before send. `.allowBluetoothHFP` lets the
        // user record via a Bluetooth headset.
        do {
            #if !targetEnvironment(simulator)
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            #else
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker]
            )
            #endif
            try session.setActive(true, options: [])
        } catch {
            throw RecorderError.sessionFailure(error.localizedDescription)
        }

        // iOS 17+ uses AVAudioApplication.requestRecordPermission, but
        // AVAudioSession.requestRecordPermission is still functional and
        // covers the iOS 16 deployment target.
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            session.requestRecordPermission { ok in cont.resume(returning: ok) }
        }
        guard granted else {
            throw RecorderError.permissionDenied
        }

        let url = Self.makeTempURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000.0,        // matches Android voice-note
            AVNumberOfChannelsKey: 1,         // mono
            AVEncoderBitRateKey: 32_000,      // 32 kbps — speech grade
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.prepareToRecord()
            // W107: hard cap at 5 minutes. AVAudioRecorder.record(forDuration:)
            // auto-stops + fires audioRecorderDidFinishRecording. Without
            // this guard the user could accidentally record for hours
            // (e.g. forgot to release the press-to-talk).
            guard r.record(forDuration: Self.maxRecordingSeconds) else {
                throw RecorderError.recorderFailure("AVAudioRecorder.record() returned false")
            }
            self.recorder = r
            self.startedAt = Date()
            // W108: kick off the 0.25s timer that publishes elapsed.
            self.elapsedSeconds = 0
            self.elapsedTimer?.invalidate()
            let t = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, let started = self.startedAt else { return }
                    self.elapsedSeconds = Date().timeIntervalSince(started)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            self.elapsedTimer = t
        } catch let e as RecorderError {
            throw e
        } catch {
            throw RecorderError.recorderFailure(error.localizedDescription)
        }
    }

    /// W107: 5-minute hard cap per voice note. Most chat platforms cap
    /// at this duration; longer recordings are rare and accidental.
    /// AVAudioRecorder.record(forDuration:) auto-stops at the limit.
    static let maxRecordingSeconds: TimeInterval = 5 * 60

    /// Stops the active recording and returns the captured file. Returns
    /// nil when there's no active recording (idempotent on accidental
    /// double-stop). Resets the audio session category back to default.
    func stop() -> Recording? {
        guard let r = recorder else { return nil }
        let url = r.url
        r.stop()
        let dur = startedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        recorder = nil
        startedAt = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedSeconds = 0
        Self.deactivateSession()
        // Sanity check — recorder.stop() is async-flushing; tiny files
        // may not exist yet, so we trust the URL and leave the upload
        // path to error if the bytes never landed.
        return Recording(fileURL: url, durationMs: dur, mimeType: "audio/mp4")
    }

    /// Stops + deletes the in-flight recording without surfacing it.
    func cancel() {
        guard let r = recorder else { return }
        let url = r.url
        r.stop()
        recorder = nil
        startedAt = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedSeconds = 0
        try? FileManager.default.removeItem(at: url)
        Self.deactivateSession()
    }

    /// Whether a recording is currently running. UI binds the composer's
    /// "stop" pulse to this.
    var isRecording: Bool {
        return recorder?.isRecording == true
    }

    // MARK: - Internals

    private static func makeTempURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
        let name = "voicenote-\(UUID().uuidString).m4a"
        return dir.appendingPathComponent(name)
    }

    private static func deactivateSession() {
        // Best-effort — don't surface session-deactivate errors to the UI.
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

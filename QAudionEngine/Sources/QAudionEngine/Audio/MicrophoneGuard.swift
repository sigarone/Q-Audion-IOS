import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class MicrophoneGuard {
    public var onForeignRecorder: ((String) -> Void)?
    public init() {}

    public func requestExclusiveAccess() throws {
        let session = AVAudioSession.sharedInstance()
        let audioOpts: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: audioOpts)
        try session.setPreferredIOBufferDuration(Double(AudioConstants.frameDurationMs) / 1000.0)
        try session.setPreferredSampleRate(Double(AudioConstants.sampleRate))
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    public func releaseAccess() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

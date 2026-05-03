import Foundation
#if canImport(AVFoundation)
import AVFoundation

public final class MicrophoneGuard {
    public var onForeignRecorder: ((String) -> Void)?
    public init() {}

    public func requestExclusiveAccess() throws {
        let session = AVAudioSession.sharedInstance()
        // .allowBluetoothHFP requires iOS 26 SDK (Xcode 26+); for Xcode 16 (GH Actions)
        // fall back to deprecated .allowBluetooth — same runtime behaviour, deprecation
        // warning only on iOS 26 SDK builds. Switch to a clean .allowBluetoothHFP once
        // Xcode 16 is no longer supported.
        #if compiler(>=6.2)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        #else
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        #endif
        try session.setPreferredIOBufferDuration(Double(AudioConstants.frameDurationMs) / 1000.0)
        try session.setPreferredSampleRate(Double(AudioConstants.sampleRate))
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    public func releaseAccess() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif

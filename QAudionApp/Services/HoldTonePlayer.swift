import AVFoundation
import Foundation
import QAudionEngine

/// The hold tone of WIRE_SPEC 16.4 item 2: one beep of 350 ms at 425 Hz, about 24 dB below full scale, played through the
/// call output while the peer holds the call. Local only: it is never sent over the network and never fed into the capture
/// or the transmitted audio. It is an `AVAudioPlayer` on the already active call session: it changes no category, mode or
/// option of the session and touches neither the Voice-Processing unit nor the capture engine, so echo cancellation is
/// left as it is. Best effort: a failure is silent.
final class HoldTonePlayer {
    private var player: AVAudioPlayer?

    /// The beep as a WAV file in memory, built once. 16 kHz is plenty for 425 Hz.
    private static let wav: Data = HoldToneSynth.wavData(sampleRate: 16_000)

    func beep() {
        stop()
        guard let p = try? AVAudioPlayer(data: Self.wav) else { return }
        p.volume = 1.0
        p.prepareToPlay()
        if p.play() { player = p }
    }

    /// Stops a beep in progress (RESUMED, hang-up, expiry, the local user holding).
    func stop() {
        player?.stop()
        player = nil
    }
}

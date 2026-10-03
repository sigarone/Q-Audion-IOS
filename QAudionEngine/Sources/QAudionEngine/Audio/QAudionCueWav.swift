import Foundation

/// W-CALLERBUSY (2026-10-03) — a procedural cue as a self-contained WAV file, for the one cue that has to be
/// audible AFTER CallKit ended the call.
///
/// `QAudionRingtonePlayer` plays through its own `AVAudioEngine` on the shared `AVAudioSession`, which is why it
/// only works while CallKit has that session active (the W464 gate). The busy tone starts at the very moment the
/// caller reports the outgoing call ended to CallKit, and `reportCallEnded` is what makes iOS deactivate the
/// session: an engine started on it would be cut, or fail to start. The app already solves the same problem for
/// the in-app ringtone with a system sound ("it seizes no audio session, which CallKit and WebRTC configure"), so
/// the busy tone takes that route: the app registers this WAV as a system sound and plays it, with no session
/// involved and nothing to hand back to the next call.
///
/// 16-bit PCM, mono, 16 kHz: a 425 Hz tone does not need more, and the file is ~96 KB.
public enum QAudionCueWav {

    /// Sample rate of `busyTone()`.
    public static let busySampleRate = 16_000

    /// The busy tone (`QAudionSynth.renderBusyTone`) as a WAV file's bytes.
    public static func busyTone() -> Data {
        encode(QAudionSynth.renderBusyTone(sampleRate: Double(busySampleRate)), sampleRate: busySampleRate)
    }

    /// RIFF/WAVE, PCM, 16 bit, mono. Samples are clamped to [-1, 1].
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var out = Data()
        out.reserveCapacity(44 + dataSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataSize))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        u32(16)                                      // fmt chunk size
        u16(1)                                       // PCM
        u16(1)                                       // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * bytesPerSample))     // byte rate
        u16(UInt16(bytesPerSample))                  // block align
        u16(16)                                      // bits per sample
        out.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataSize))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let v = Int16((clamped * Float(Int16.max)).rounded())
            u16(UInt16(bitPattern: v))
        }
        return out
    }
}

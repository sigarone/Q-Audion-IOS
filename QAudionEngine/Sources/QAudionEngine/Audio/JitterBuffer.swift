import Foundation

public final class JitterBuffer: @unchecked Sendable {
    public let capacity: Int
    /// W-LONGAUDIO (2026-08-10) — the frame duration this buffer's comfort
    /// noise must match, in ms. Defaults to 20, so every existing construction
    /// site produces exactly today's 1920-byte frame.
    public let frameDurationMs: Int
    private let lock = NSLock()
    private var buffer: [Data] = []
    private var _underrunCount: Int64 = 0
    private var _overrunCount: Int64 = 0

    public init(capacity: Int, frameDurationMs: Int = AudioConstants.frameDurationMs) {
        precondition(capacity > 0)
        precondition(frameDurationMs > 0)
        self.capacity = capacity
        self.frameDurationMs = frameDurationMs
    }

    public func push(_ frame: Data) {
        lock.lock(); defer { lock.unlock() }
        if buffer.count >= capacity { buffer.removeFirst(); _overrunCount += 1 }
        buffer.append(frame)
    }

    public func pop() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if buffer.isEmpty { _underrunCount += 1; return nil }
        return buffer.removeFirst()
    }

    public var size: Int { lock.lock(); defer { lock.unlock() }; return buffer.count }
    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return buffer.isEmpty }
    public var isFull: Bool { lock.lock(); defer { lock.unlock() }; return buffer.count >= capacity }
    public var underrunCount: Int64 { lock.lock(); defer { lock.unlock() }; return _underrunCount }
    public var overrunCount: Int64 { lock.lock(); defer { lock.unlock() }; return _overrunCount }

    public func clear() { lock.lock(); buffer.removeAll(); lock.unlock() }

    /// W-LONGAUDIO (2026-08-10) — sized from THIS buffer's frame duration, not
    /// from the module constant.
    ///
    /// This feeds the encoder on the muted path, and libopus takes the frame
    /// size it was configured for and nothing else. Handing a 1920-byte buffer
    /// to a 60 ms encoder makes `encode` reject it on every single frame while
    /// muted — which then falls through to the silent-frame path and looks,
    /// from every counter, exactly like mute working correctly.
    public func generateComfortNoise() -> Data {
        let samples = AudioConstants.sampleRate / 1000 * frameDurationMs
        var pcm = Data(count: samples * (AudioConstants.bitsPerSample / 8) * AudioConstants.channels)
        pcm.withUnsafeMutableBytes { buf in
            let ptr = buf.bindMemory(to: Int16.self)
            for idx in 0..<samples {
                ptr[idx] = Int16.random(in: -AudioConstants.comfortNoiseAmplitude...AudioConstants.comfortNoiseAmplitude)
            }
        }
        return pcm
    }
}
